package app.portside.android

import android.Manifest
import android.content.Context
import android.os.Build
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.portside.core.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class RuntimeTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val app get() = instrumentation.targetContext.applicationContext as PortsideApplication
    private fun freePort() = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
    private fun waitFor(test: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
        while (!test()) {
            if (System.nanoTime() > deadline) fail("Timed out waiting for Android forwarding state: ${app.state.value.snapshots}; error=${app.state.value.error}")
            Thread.sleep(25)
        }
    }

    @Test fun profilesPersistWithoutCredentials() {
        val server = ServerProfile(name = "Profile test", host = "127.0.0.1", icon = ServerIcon.HOME)
        try {
            instrumentation.runOnMainSync { app.saveServer(server) }
            val secondStore = ConfigurationStore(app)
            assertEquals(server, secondStore.read().servers.first { it.id == server.id })
            assertEquals(setOf("configuration"), app.getSharedPreferences("portside", Context.MODE_PRIVATE).all.keys)
        } finally { instrumentation.runOnMainSync { app.removeServer(server.id) } }
    }

    @Test fun foregroundServiceForwardsInBackgroundAndStopsIndependently() {
        val args = InstrumentationRegistry.getArguments()
        val serverPort = args.getString("serverPort")?.toIntOrNull()
        val targetPort = args.getString("targetPort")?.toIntOrNull()
        assumeTrue("Run scripts/test-emulator.sh for Rust-server integration", serverPort != null && targetPort != null)
        val server = ServerProfile(name = "Runtime test", host = "127.0.0.1", port = serverPort!!)
        val otherServer = ServerProfile(name = "Other runtime server", host = "127.0.0.1", port = serverPort)
        val first = ForwardRule(serverId = server.id, name = "one", localPort = freePort(), remotePort = targetPort!!)
        val second = ForwardRule(serverId = otherServer.id, name = "two", localPort = freePort(), remotePort = targetPort)
        if (Build.VERSION.SDK_INT >= 37) {
            instrumentation.uiAutomation.grantRuntimePermission(app.packageName, Manifest.permission.ACCESS_LOCAL_NETWORK)
        }
        instrumentation.uiAutomation.grantRuntimePermission(app.packageName, Manifest.permission.POST_NOTIFICATIONS)
        try {
            instrumentation.runOnMainSync { app.saveServer(server); app.saveServer(otherServer); app.saveForward(first); app.saveForward(second) }
            ActivityScenario.launch(MainActivity::class.java).use { activity ->
                activity.onActivity { ForwardService.start(it, first.id); ForwardService.start(it, second.id) }
                waitFor { listOf(first, second).all { app.state.value.snapshots[it.id]?.phase == Phase.LISTENING } }
                instrumentation.runOnMainSync { app.saveServer(server.copy(icon = ServerIcon.CLOUD)) }
                assertEquals(2, app.engine.activeCount)
                assertEquals(Phase.LISTENING, app.state.value.snapshots[first.id]?.phase)
                activity.moveToState(Lifecycle.State.CREATED)
                fun request(rule: ForwardRule): String = Socket("127.0.0.1", rule.localPort).use { local ->
                    local.soTimeout = 10000
                    local.getOutputStream().write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".toByteArray())
                    String(local.getInputStream().readBytes())
                }
                assertTrue(request(first).contains("portside-android-runtime-ok"))
                instrumentation.runOnMainSync { ForwardService.stop(app, first.id) }
                waitFor { app.state.value.snapshots[first.id]?.phase == Phase.STOPPED }
                assertEquals(Phase.LISTENING, app.state.value.snapshots[second.id]?.phase)
                assertTrue(request(second).contains("portside-android-runtime-ok"))
                instrumentation.runOnMainSync { ForwardService.stop(app, second.id) }
                waitFor { app.engine.activeCount == 0 }
            }
        } finally { instrumentation.runOnMainSync { app.removeServer(server.id); app.removeServer(otherServer.id) } }
    }

    @Test fun sharedPortSwitchesServersAndFailedCheckKeepsCurrentForward() {
        val args = InstrumentationRegistry.getArguments()
        val serverPort = args.getString("serverPort")?.toIntOrNull()
        val targetPort = args.getString("targetPort")?.toIntOrNull()
        assumeTrue("Run scripts/test-emulator.sh for Rust-server integration", serverPort != null && targetPort != null)
        val firstServer = ServerProfile(name = "Work", host = "127.0.0.1", port = serverPort!!)
        val secondServer = ServerProfile(name = "Home", host = "127.0.0.1", port = serverPort)
        val offlineServer = ServerProfile(name = "Offline", host = "127.0.0.1", port = freePort())
        val port = freePort()
        val rules = listOf(firstServer, secondServer, offlineServer).map {
            ForwardRule(serverId = it.id, name = it.name, localPort = port, remotePort = targetPort!!)
        }
        if (Build.VERSION.SDK_INT >= 37) {
            instrumentation.uiAutomation.grantRuntimePermission(app.packageName, Manifest.permission.ACCESS_LOCAL_NETWORK)
        }
        instrumentation.uiAutomation.grantRuntimePermission(app.packageName, Manifest.permission.POST_NOTIFICATIONS)
        try {
            instrumentation.runOnMainSync {
                listOf(firstServer, secondServer, offlineServer).forEach(app::saveServer)
                rules.forEach(app::saveForward)
                val duplicate = rules.first().copy(id = java.util.UUID.randomUUID().toString())
                assertThrows(IllegalArgumentException::class.java) { app.saveForward(duplicate) }
            }
            assertEquals(3, ConfigurationStore(app).read().forwards.count { it.localPort == port })
            ActivityScenario.launch(MainActivity::class.java).use { activity ->
                for ((index, rule) in listOf(rules[0], rules[1], rules[0], rules[1]).withIndex()) {
                    activity.onActivity { ForwardService.start(it, rule.id) }
                    waitFor {
                        val snapshot = app.state.value.snapshots[rule.id]
                        assertNotEquals("Switch $index to ${rule.name}: ${snapshot?.error}", Phase.FAILED, snapshot?.phase)
                        snapshot?.phase == Phase.LISTENING
                    }
                    assertEquals(1, app.engine.activeCount)
                    rules.filter { it.id != rule.id }.forEach {
                        assertNotEquals(Phase.LISTENING, app.state.value.snapshots[it.id]?.phase)
                    }
                }
                activity.onActivity { ForwardService.start(it, rules[2].id) }
                waitFor { app.state.value.snapshots[rules[2].id]?.phase == Phase.FAILED }
                assertEquals(Phase.LISTENING, app.state.value.snapshots[rules[1].id]?.phase)
                assertEquals(1, app.engine.activeCount)
                Socket("127.0.0.1", port).use { local ->
                    local.soTimeout = 10000
                    local.getOutputStream().write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".toByteArray())
                    assertTrue(String(local.getInputStream().readBytes()).contains("portside-android-runtime-ok"))
                }
            }
        } finally {
            instrumentation.runOnMainSync {
                rules.forEach { ForwardService.stop(app, it.id) }
                listOf(firstServer, secondServer, offlineServer).forEach { app.removeServer(it.id) }
            }
            waitFor { app.engine.activeCount == 0 }
        }
    }
}
