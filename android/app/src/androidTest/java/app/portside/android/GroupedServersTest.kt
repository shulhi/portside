package app.portside.android

import android.content.ContentValues
import android.graphics.Bitmap
import android.provider.MediaStore
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import app.portside.core.*
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class GroupedServersTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun showsEveryServerAndAddsForwardToTheChosenGroup() {
        val app = compose.activity.application as PortsideApplication
        val work = ServerProfile(name = "Work laptop", host = "work.tailnet.ts.net")
        val home = ServerProfile(name = "Home Mac", host = "home.tailnet.ts.net")
        try {
            compose.runOnUiThread {
                app.saveServer(work); app.saveServer(home)
                app.saveForward(ForwardRule(serverId = work.id, name = "Web app", localPort = 3000, remotePort = 3000))
                app.saveForward(ForwardRule(serverId = home.id, name = "Dashboard", localPort = 4000, remotePort = 4000))
                app.saveForward(ForwardRule(serverId = home.id, name = "Frontend", localPort = 3000, remotePort = 5173))
            }
            compose.onNodeWithText("Work laptop").assertIsDisplayed()
            compose.onNodeWithText("Home Mac").assertIsDisplayed()
            compose.onNodeWithText("Web app").assertIsDisplayed()
            compose.onNodeWithText("Dashboard").assertIsDisplayed()
            compose.onNodeWithText("Frontend").assertIsDisplayed()
            compose.onAllNodesWithText("Start").assertCountEquals(3)
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
        } finally {
            compose.runOnUiThread { app.removeServer(work.id); app.removeServer(home.id) }
        }
    }
}
