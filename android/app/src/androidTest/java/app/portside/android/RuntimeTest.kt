package app.portside.android

import android.Manifest
import android.content.Context
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
    private val testToken = "0123456789abcdef".repeat(4)
    private fun freePort() = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
    private fun waitFor(test: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
        while (!test()) {
            if (System.nanoTime() > deadline) fail("Timed out waiting for Android forwarding state")
            Thread.sleep(25)
        }
    }

    @Test fun tokensAreEncryptedAndProfilesSurviveStoreRecreation() {
        val server = ServerProfile(name = "Keystore test", host = "127.0.0.1")
        try {
            instrumentation.runOnMainSync { app.saveServer(server, testToken) }
            val secondStore = ConfigurationStore(app)
            assertEquals(server, secondStore.read().servers.first { it.id == server.id })
            assertEquals(testToken, secondStore.token(server.id))
            val persisted = app.getSharedPreferences("portside", Context.MODE_PRIVATE).all.values.joinToString()
            assertFalse(persisted.contains(testToken))
        } finally { instrumentation.runOnMainSync { app.removeServer(server.id) } }
    }

    @Test fun foregroundServiceForwardsInBackgroundAndStopsIndependently() {
        val args = InstrumentationRegistry.getArguments()
        val serverPort = args.getString("serverPort")?.toIntOrNull()
        val targetPort = args.getString("targetPort")?.toIntOrNull()
        assumeTrue("Run scripts/test-emulator.sh for Rust-server integration", serverPort != null && targetPort != null)
        val server = ServerProfile(name = "Runtime test", host = "127.0.0.1", port = serverPort!!)
        val first = ForwardRule(serverId = server.id, name = "one", localPort = freePort(), remotePort = targetPort!!)
        val second = ForwardRule(serverId = server.id, name = "two", localPort = freePort(), remotePort = targetPort)
        instrumentation.uiAutomation.grantRuntimePermission(app.packageName, Manifest.permission.ACCESS_LOCAL_NETWORK)
        instrumentation.uiAutomation.grantRuntimePermission(app.packageName, Manifest.permission.POST_NOTIFICATIONS)
        try {
            instrumentation.runOnMainSync { app.saveServer(server, testToken); app.saveForward(first); app.saveForward(second) }
            ActivityScenario.launch(MainActivity::class.java).use { activity ->
                activity.onActivity { ForwardService.start(it, first.id); ForwardService.start(it, second.id) }
                waitFor { listOf(first, second).all { app.state.value.snapshots[it.id]?.phase == Phase.LISTENING } }
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
        } finally { instrumentation.runOnMainSync { app.removeServer(server.id) } }
    }
}
