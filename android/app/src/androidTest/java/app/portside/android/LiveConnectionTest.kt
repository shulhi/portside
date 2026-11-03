package app.portside.android

import android.os.Bundle
import androidx.test.platform.app.InstrumentationRegistry
import app.portside.core.ServerProfile
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Opt-in, read-only probe; never changes saved profiles or starts a forward. */
class LiveConnectionTest {
    @Test fun connectsToLiveServer() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val arguments = InstrumentationRegistry.getArguments()
        val host = arguments.getString("portsideHost").orEmpty()
        assumeTrue("Pass portsideHost to run against a real Tailscale device", host.isNotBlank())
        val app = instrumentation.targetContext.applicationContext as PortsideApplication
        val hosts = listOf(host, arguments.getString("portsideIp").orEmpty()).filter(String::isNotBlank).distinct()
        var connected = false
        for (address in hosts) {
            val result = runCatching { app.info(ServerProfile(name = "Read-only connection probe", host = address)) }
            val message = result.fold(
                onSuccess = { connected = true; "$address: OK, server ${it.version}" },
                onFailure = { "$address: ${it.javaClass.simpleName}: ${it.message}" })
            instrumentation.sendStatus(0, Bundle().apply { putString("stream", "\n$message\n") })
        }
        assertTrue("Neither the hostname nor the numeric address connected", connected)
    }
}
