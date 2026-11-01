package app.portside.core

import org.junit.Assert.*
import org.junit.Test
import java.net.InetAddress

class ProtocolTest {
    @Test fun onlyTailnetAndLoopbackAddressesAreAllowed() {
        listOf("127.0.0.1", "100.64.0.1", "100.127.255.254", "::1", "fd7a:115c:a1e0::1", "localhost", "work-server", "machine.tailnet.ts.net").forEach {
            assertTrue(it, AddressPolicy.validHost(it))
        }
        listOf("8.8.8.8", "192.168.1.2", "10.0.0.1", "100.63.255.255", "100.128.0.1", "0.0.0.0", "::", "fe80::1", "example.com", "https://work-server", "work-server:9417", "127.1", "127.00.0.1", "-bad", "", "foo..ts.net").forEach {
            assertFalse(it, AddressPolicy.validHost(it))
        }
        assertFalse(AddressPolicy.allowed(InetAddress.getByName("203.0.113.1")))
    }

    @Test fun binaryFramesPreserveBytesAndRejectInvalidTagsAndSizes() {
        val bytes = ByteArray(65536) { (it % 251).toByte() }
        val frame = TunnelFrame.data(bytes)
        TunnelFrame.validate(frame)
        assertArrayEquals(bytes, frame.copyOfRange(1, frame.size))
        TunnelFrame.validate(byteArrayOf(0))
        TunnelFrame.validate(byteArrayOf(1))
        listOf(byteArrayOf(), byteArrayOf(2), byteArrayOf(1, 0), ByteArray(65538)).forEach {
            assertThrows(IllegalArgumentException::class.java) { TunnelFrame.validate(it) }
        }
    }

    @Test fun portsTokensAndFamiliesAreValidated() {
        assertThrows(IllegalArgumentException::class.java) { ForwardRule(serverId = "a", name = "test", localPort = 80, remotePort = 3000).validate() }
        assertThrows(IllegalArgumentException::class.java) { ForwardRule(serverId = "a", name = "test", localPort = 3000, remotePort = 65536).validate() }
        assertThrows(IllegalArgumentException::class.java) { validateToken("x".repeat(40) + "\nInjected: header") }
        assertEquals("http://[fd7a:115c:a1e0::1]:9417/v1/info", ServerProfile(name = "test", host = "fd7a:115c:a1e0::1").url("/v1/info").toString())
        assertEquals("http://127.0.0.1:3000", ForwardRule(serverId = "a", name = "test", localPort = 3000, remotePort = 5173).browserUrl)
    }
}
