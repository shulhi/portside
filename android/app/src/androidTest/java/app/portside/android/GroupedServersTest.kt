package app.portside.android

import android.content.ContentValues
import android.Manifest
import android.os.Build
import android.graphics.Bitmap
import android.provider.MediaStore
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import app.portside.core.*
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket

class GroupedServersTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun refreshClearsOldErrorsRechecksAllServersAndPreservesConnections() {
        val args = InstrumentationRegistry.getArguments()
        val serverPort = args.getString("serverPort")?.toIntOrNull()
        val targetPort = args.getString("targetPort")?.toIntOrNull()
        assumeTrue("Run scripts/test-emulator.sh for refresh integration", serverPort != null && targetPort != null)
        val app = compose.activity.application as PortsideApplication
        fun freePort() = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
        val healthy = ServerProfile(name = "Online", host = "127.0.0.1", port = serverPort!!)
        val offline = ServerProfile(name = "Offline", host = "127.0.0.1", port = freePort())
        val active = ForwardRule(serverId = healthy.id, name = "Running", localPort = freePort(), remotePort = targetPort!!)
        val failed = ForwardRule(serverId = offline.id, name = "Failed earlier", localPort = freePort(), remotePort = targetPort)
        if (Build.VERSION.SDK_INT >= 37) {
            InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(app.packageName, Manifest.permission.ACCESS_LOCAL_NETWORK)
        }
        try {
            compose.runOnUiThread {
                app.saveServer(healthy); app.saveServer(offline)
                app.saveForward(active); app.saveForward(failed)
                app.engine.start(active, healthy)
                app.snapshot(failed.id, ForwardSnapshot(Phase.FAILED, error = "Old failed start"))
                app.serverStatus(healthy.id, ServerStatus(error = "Old server failure"))
                app.serverStatus(offline.id, ServerStatus(error = "Old server failure"))
            }
            Socket("127.0.0.1", active.localPort).use { connection ->
                connection.soTimeout = 10000
                compose.onNodeWithContentDescription("Refresh all servers").performClick()
                compose.waitUntil(timeoutMillis = 15000) {
                    val statuses = app.state.value.serverStatuses
                    statuses[healthy.id]?.version != null && statuses[offline.id]?.error != null && statuses.values.none { it.checking }
                }
                assertNull(app.state.value.snapshots[failed.id]?.error)
                assertEquals(Phase.STOPPED, app.state.value.snapshots[failed.id]?.phase)
                assertEquals(Phase.LISTENING, app.state.value.snapshots[active.id]?.phase)
                assertEquals(1, app.engine.activeCount)
                assertTrue(app.state.value.serverStatuses[offline.id]?.error != "Old server failure")
                connection.getOutputStream().write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".toByteArray())
                assertTrue(String(connection.getInputStream().readBytes()).contains("portside-android-runtime-ok"))
            }
            compose.runOnUiThread { app.report("Old general error") }
            compose.onNodeWithText("Refresh", useUnmergedTree = true).performClick()
            compose.waitUntil(timeoutMillis = 15000) {
                app.state.value.error == null && app.state.value.serverStatuses[offline.id]?.error != null &&
                    app.state.value.serverStatuses.values.none { it.checking }
            }
            assertEquals(Phase.LISTENING, app.state.value.snapshots[active.id]?.phase)
            compose.runOnUiThread { app.serverStatus(offline.id, ServerStatus(error = "Old error before pull")) }
            compose.onNode(hasScrollAction()).performTouchInput { swipeDown() }
            compose.waitUntil(timeoutMillis = 15000) {
                val status = app.state.value.serverStatuses[offline.id]
                status?.error != null && status.error != "Old error before pull" && !status.checking
            }
        } finally {
            compose.runOnUiThread { app.removeServer(healthy.id); app.removeServer(offline.id); app.report(null) }
        }
    }

    @Test fun showsEveryServerAndAddsForwardToTheChosenGroup() {
        val app = compose.activity.application as PortsideApplication
        val work = ServerProfile(name = "Work laptop", host = "work.tailnet.ts.net", icon = ServerIcon.LAPTOP)
        val home = ServerProfile(name = "Home Mac", host = "home.tailnet.ts.net", icon = ServerIcon.HOME)
        val web = ForwardRule(serverId = work.id, name = "Web app", localPort = 3000, remotePort = 3000)
        try {
            compose.runOnUiThread {
                app.saveServer(work); app.saveServer(home)
                app.saveForward(web)
                app.saveForward(ForwardRule(serverId = home.id, name = "Dashboard", localPort = 4000, remotePort = 4000))
                app.saveForward(ForwardRule(serverId = home.id, name = "Frontend", localPort = 3000, remotePort = 5173))
                app.snapshot(web.id, ForwardSnapshot(Phase.LISTENING, connections = 2))
            }
            compose.onNodeWithText("Work laptop").assertIsDisplayed()
            compose.onNodeWithText("Home Mac").assertIsDisplayed()
            compose.onNodeWithText("Web app", substring = true).assertIsDisplayed()
            compose.onNodeWithText("Dashboard", substring = true).assertIsDisplayed()
            compose.onNodeWithText("Frontend", substring = true).assertIsDisplayed()
            compose.onNodeWithText("3000:3000").assertIsDisplayed()
            compose.onNodeWithText("4000:4000").assertIsDisplayed()
            compose.onNodeWithContentDescription("Stop Web app").assertIsDisplayed()
            compose.onNodeWithContentDescription("Start Dashboard").assertIsDisplayed()
            compose.onNodeWithContentDescription("Switch to Frontend").assertIsDisplayed()
            compose.onNodeWithContentDescription("Port 3000, Listening · 2 connections").assertIsDisplayed()
            compose.onNodeWithContentDescription("Add forward to Work laptop").assertIsDisplayed()
            compose.onNodeWithContentDescription("Add forward to Home Mac").assertIsDisplayed()

            // Retain a rendered fixture on the disposable emulator for visual review.
            val image = compose.onRoot().captureToImage().asAndroidBitmap()
            val resolver = compose.activity.contentResolver
            val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, "portside-groups-${System.currentTimeMillis()}.png")
                put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/PortsideTests")
            })!!
            resolver.openOutputStream(uri)!!.use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }

            compose.onNodeWithContentDescription("Stop Web app").performClick()
            compose.waitUntil(timeoutMillis = 5000) { app.state.value.snapshots[web.id]?.phase == Phase.STOPPED }
            compose.onNodeWithContentDescription("Start Web app").assertIsDisplayed()

            compose.onNodeWithContentDescription("Add forward to Home Mac").performClick()
            compose.onNodeWithText("New forward").assertIsDisplayed()
            compose.onNode(hasText("Home Mac") and hasAnyAncestor(isDialog())).assertIsDisplayed()
            compose.onNodeWithText("Name").performTextInput("Home API")
            compose.onNodeWithText("Local port on this phone").performTextReplacement("4100")
            compose.onNodeWithText("Save forward").performClick()
            compose.waitForIdle()
            val added = app.state.value.configuration.forwards.single { it.name == "Home API" }
            assertEquals(home.id, added.serverId)
            assertEquals(4100, added.localPort)

            compose.onNodeWithContentDescription("Edit Work laptop icon").performClick()
            compose.onNodeWithContentDescription("Cloud icon").performClick().assertIsOn()
            compose.onNodeWithText("Save server").performClick()
            compose.waitForIdle()
            assertEquals(ServerIcon.CLOUD, ConfigurationStore(app).read().servers.first { it.id == work.id }.icon)
            assertEquals(work.id, app.state.value.configuration.servers.first().id)
        } finally {
            compose.runOnUiThread { app.removeServer(work.id); app.removeServer(home.id) }
        }
    }
}
