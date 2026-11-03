package app.portside.core

import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.Closeable
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import java.util.concurrent.*

class ForwardIntegrationTest {
    private fun freePort() = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
    private fun waitFor(predicate: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(8)
        while (!predicate()) {
            if (System.nanoTime() > deadline) fail("Timed out waiting for tunnel state")
            Thread.sleep(10)
        }
    }
    private inner class Rust : Closeable {
        private val binary = System.getProperty("portside.test.server", "").also {
            assumeTrue("Set PORTSIDE_TEST_SERVER to run real Rust-server integration tests", it.isNotBlank())
        }
        val directory = Files.createTempDirectory("portside-android-test")
        val port = freePort()
        val profile = ServerProfile(name = "test", host = "127.0.0.1", port = port)
        val process: Process
        init {
            val path = directory.resolve("tailscale.py")
            Files.copy(java.nio.file.Path.of(System.getProperty("portside.test.tailscale")), path)
            Files.setPosixFilePermissions(path, PosixFilePermissions.fromString("rwx------"))
            process = ProcessBuilder(binary, "serve", "--listen", "127.0.0.1:$port", "--tailscale-bin", path.toString())
                .redirectError(directory.resolve("server.log").toFile()).start()
            waitFor { runCatching { Socket("127.0.0.1", port).close() }.isSuccess }
        }
        override fun close() {
            process.destroy(); if (!process.waitFor(5, TimeUnit.SECONDS)) process.destroyForcibly()
            directory.toFile().deleteRecursively()
        }
    }

    @Test fun largeBinaryTransferAndClientHalfClosePreserveResponse() {
        Rust().use { rust ->
            ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { target ->
                val payload = ByteArray(3 * 1024 * 1024) { (it % 251).toByte() }
                val pool = Executors.newSingleThreadExecutor()
                try {
                    val response = pool.submit<ByteArray> {
                        target.accept().use { socket ->
                            socket.soTimeout = 10000
                            val received = socket.getInputStream().readBytes()
                            socket.getOutputStream().write(received.reversedArray())
                            socket.shutdownOutput()
                            received
                        }
                    }
                    val states = ConcurrentHashMap<String, ForwardSnapshot>()
                    ForwardEngine { id, snapshot -> states[id] = snapshot }.use { engine ->
                        val rule = ForwardRule(serverId = rust.profile.id, name = "binary", localPort = freePort(), remotePort = target.localPort)
                        engine.start(rule, rust.profile)
                        Socket("127.0.0.1", rule.localPort).use { local ->
                            local.soTimeout = 15000
                            local.getOutputStream().write(payload)
                            local.shutdownOutput()
                            assertArrayEquals(payload.reversedArray(), local.getInputStream().readBytes())
                        }
                        assertArrayEquals(payload, response.get(10, TimeUnit.SECONDS))
                        waitFor { states[rule.id]?.connections == 0 }
                        assertEquals(Phase.LISTENING, states[rule.id]?.phase)
                        assertEquals(payload.size.toLong(), states[rule.id]?.sentBytes)
                        assertEquals(payload.size.toLong(), states[rule.id]?.receivedBytes)
                    }
                } finally { pool.shutdownNow() }
            }
        }
    }

    @Test fun targetHalfClosePreservesLocalWriteDirection() {
        Rust().use { rust ->
            ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { target ->
                val pool = Executors.newSingleThreadExecutor()
                try {
                    val result = pool.submit<String> {
                        target.accept().use { socket ->
                            socket.soTimeout = 10000
                            socket.getOutputStream().write("hello".toByteArray()); socket.shutdownOutput()
                            String(socket.getInputStream().readBytes())
                        }
                    }
                    ForwardEngine { _, _ -> }.use { engine ->
                        val rule = ForwardRule(serverId = rust.profile.id, name = "half-close", localPort = freePort(), remotePort = target.localPort)
                        engine.start(rule, rust.profile)
                        Socket("127.0.0.1", rule.localPort).use { local ->
                            local.soTimeout = 10000
                            assertEquals("hello", String(local.getInputStream().readBytes()))
                            local.getOutputStream().write("still writing".toByteArray()); local.shutdownOutput()
                            assertEquals("still writing", result.get(10, TimeUnit.SECONDS))
                        }
                    }
                } finally { pool.shutdownNow() }
            }
        }
    }

    @Test fun authenticationAndTargetErrorsLeaveListenerAvailable() {
        Rust().use { rust ->
            val states = ConcurrentHashMap<String, ForwardSnapshot>()
            ForwardEngine { id, value -> states[id] = value }.use { engine ->
                val rule = ForwardRule(serverId = rust.profile.id, name = "auth", localPort = freePort(), remotePort = freePort())
                Files.writeString(rust.directory.resolve("tailscale.peer"), "8")
                engine.start(rule, rust.profile)
                Socket("127.0.0.1", rule.localPort).use { local ->
                    local.soTimeout = 10000
                    runCatching { local.getInputStream().read() }
                }
                waitFor { states[rule.id]?.error != null }
                assertTrue(states[rule.id]!!.error!!.contains("not allowed"))
                assertEquals(Phase.LISTENING, states[rule.id]?.phase)
                engine.stop(rule.id)
                Files.writeString(rust.directory.resolve("tailscale.peer"), "7")
                engine.start(rule, rust.profile)
                Socket("127.0.0.1", rule.localPort).use { local ->
                    local.soTimeout = 10000
                    runCatching { local.getInputStream().read() }
                }
                waitFor { states[rule.id]?.error != null }
                assertTrue(states[rule.id]!!.error!!.contains("not listening"))
                assertEquals(Phase.LISTENING, states[rule.id]?.phase)
            }
        }
    }

    @Test fun listenersAreLoopbackOnlyAndStopIndependently() {
        val server = ServerProfile(name = "test", host = "127.0.0.1")
        val first = ForwardRule(serverId = server.id, name = "one", localPort = freePort(), remotePort = 3000)
        val second = ForwardRule(serverId = server.id, name = "two", localPort = freePort(), remotePort = 3001)
        ForwardEngine { _, _ -> }.use { engine ->
            engine.start(first, server); engine.start(second, server)
            assertEquals(2, engine.activeCount)
            assertThrows(IllegalArgumentException::class.java) { engine.start(first.copy(id = "duplicate"), server) }
            engine.stop(first.id)
            assertEquals(1, engine.activeCount)
            assertThrows(java.io.IOException::class.java) { Socket("127.0.0.1", first.localPort).close() }
            // The listener must reject connections through a non-loopback interface.
            val address = NetworkInterface.getNetworkInterfaces().toList().flatMap { it.inetAddresses.toList() }
                .firstOrNull { it is Inet4Address && !it.isLoopbackAddress && !it.isLinkLocalAddress }
            if (address != null) assertThrows(java.io.IOException::class.java) {
                Socket().use { it.connect(InetSocketAddress(address, second.localPort), 500) }
            }
            engine.stop(second.id)
            assertEquals(0, engine.activeCount)
        }
    }
}
