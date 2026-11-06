package app.portside.core

import okhttp3.*
import okio.ByteString.Companion.toByteString
import java.io.Closeable
import java.io.IOException
import java.net.*
import java.util.UUID
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** One loopback listener per rule, one WebSocket per accepted TCP connection. */
class ForwardEngine(private val changed: (String, ForwardSnapshot) -> Unit) : Closeable {
    val http = OkHttpClient.Builder()
        .dns(AddressPolicy.dns).proxy(Proxy.NO_PROXY)
        .followRedirects(false).followSslRedirects(false)
        .connectTimeout(8, TimeUnit.SECONDS).readTimeout(10, TimeUnit.SECONDS)
        .pingInterval(25, TimeUnit.SECONDS).build()
    private val listeners = ConcurrentHashMap<String, Listener>()
    private val listenerThreads = Executors.newFixedThreadPool(16)
    private val tunnelThreads = Executors.newFixedThreadPool(32)
    private val slots = Semaphore(32)

    val activeCount get() = listeners.size

    @Synchronized
    fun start(rule: ForwardRule, server: ServerProfile, replacingConflicts: Boolean = false) {
        rule.validate(); server.validate()
        require(rule.serverId == server.id) { "This forward belongs to a different server." }
        listeners[rule.id]?.let { it.emit(); return }
        val conflicts = listeners.values.filter { it.rule.localPort == rule.localPort }
        require(replacingConflicts || conflicts.isEmpty()) { "That local port is already forwarded." }
        require(listeners.size - conflicts.size < 16) { "At most 16 forwards can run at once." }
        conflicts.forEach { stop(it.rule.id) }
        val socket = ServerSocket()
        try {
            socket.reuseAddress = true
            socket.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), rule.localPort), 32)
        } catch (e: Exception) { socket.close(); throw e }
        val listener = Listener(rule, server, socket)
        listeners[rule.id] = listener
        listener.emit()
        listenerThreads.execute { listener.accept() }
    }

    @Synchronized
    fun stop(id: String) {
        listeners.remove(id)?.stop()
        changed(id, ForwardSnapshot())
    }
    @Synchronized
    fun stopAll() { listeners.keys.toList().forEach(::stop) }

    @Synchronized
    fun clearErrors(ruleIds: Set<String>) {
        listeners.filterKeys { it in ruleIds }.values.forEach { it.clearError() }
    }
    override fun close() {
        stopAll(); listenerThreads.shutdownNow(); tunnelThreads.shutdownNow()
        http.dispatcher.executorService.shutdown(); http.connectionPool.evictAll()
    }

    private inner class Listener(
        val rule: ForwardRule, val server: ServerProfile, val socket: ServerSocket,
    ) {
        val running = AtomicBoolean(true)
        private val acceptClosed = CountDownLatch(1)
        val tunnels = ConcurrentHashMap<String, Tunnel>()
        val sent = AtomicLong(); val received = AtomicLong()
        @Volatile var error: String? = null

        @Synchronized fun emit() {
            if (running.get()) changed(rule.id, ForwardSnapshot(Phase.LISTENING, tunnels.size, sent.get(), received.get(), error))
        }
        @Synchronized fun clearError() { error = null; emit() }
        fun accept() {
            try {
                while (running.get()) {
                    val local = socket.accept()
                    local.tcpNoDelay = true
                    if (!running.get() || !slots.tryAcquire()) { local.close(); continue }
                    val tunnel = Tunnel(local)
                    tunnels[tunnel.id] = tunnel
                    if (!running.get()) { tunnel.finish(); continue }
                    emit()
                    tunnelThreads.execute { tunnel.run() }
                }
            } catch (e: IOException) {
                // Android can retain the listening descriptor until accept()
                // unwinds, even after ServerSocket.close() has returned.
                acceptClosed.countDown()
                if (running.get()) {
                    stop(rule.id)
                    changed(rule.id, ForwardSnapshot(Phase.FAILED, error = e.message ?: "Local listener stopped."))
                }
            } finally { acceptClosed.countDown() }
        }
        fun stop() {
            synchronized(this) {
                running.set(false); socket.close()
                tunnels.values.toList().forEach { it.finish() }
            }
            acceptClosed.await(1, TimeUnit.SECONDS)
        }

        private inner class Tunnel(val local: Socket) : WebSocketListener() {
            val id = UUID.randomUUID().toString()
            val done = AtomicBoolean(false)
            val opened = CountDownLatch(1)
            val localEOF = AtomicBoolean(false); val remoteEOF = AtomicBoolean(false)
            @Volatile var ws: WebSocket? = null

            fun run() {
                try {
                    if (done.get()) return
                    val url = server.url("/v1/tunnels/${rule.remotePort}").newBuilder()
                        .addQueryParameter("family", rule.family).build()
                    val request = Request.Builder().url(url)
                        .header("Sec-WebSocket-Protocol", TunnelFrame.PROTOCOL).build()
                    val connection = http.newWebSocket(request, this)
                    ws = connection
                    if (done.get()) { connection.cancel(); return }
                    if (!opened.await(10, TimeUnit.SECONDS)) throw IOException("The server connection timed out.")
                    if (done.get()) return
                    val buffer = ByteArray(16384)
                    val input = local.getInputStream()
                    while (!done.get()) {
                        val count = input.read(buffer)
                        // Bound the asynchronous WebSocket writer queue before reading another TCP chunk.
                        while (!done.get() && connection.queueSize() > 131072) Thread.sleep(5)
                        if (done.get()) break
                        if (count < 0) {
                            if (!connection.send(byteArrayOf(1).toByteString())) throw IOException("The tunnel closed.")
                            localEOF.set(true)
                            completeIfFinished()
                            break
                        }
                        if (!connection.send(TunnelFrame.data(buffer, count).toByteString())) throw IOException("The tunnel closed.")
                        sent.addAndGet(count.toLong())
                        emit()
                    }
                } catch (e: Exception) { finish(e.message ?: "The connection closed.") }
            }

            override fun onOpen(webSocket: WebSocket, response: Response) {
                ws = webSocket
                if (done.get()) { webSocket.cancel(); return }
                if (response.header("Sec-WebSocket-Protocol") != TunnelFrame.PROTOCOL) {
                    finish("The server negotiated an incompatible protocol.")
                    return
                }
                error = null; opened.countDown(); emit()
            }
            override fun onMessage(webSocket: WebSocket, bytes: okio.ByteString) {
                if (done.get()) return
                try {
                    val frame = bytes.toByteArray()
                    TunnelFrame.validate(frame)
                    require(!remoteEOF.get()) { "The server sent data after EOF." }
                    if (frame[0] == 1.toByte()) {
                        remoteEOF.set(true)
                        local.shutdownOutput()
                        completeIfFinished()
                    } else {
                        // Write directly on this WebSocket's reader: slow TCP readers apply backpressure.
                        local.getOutputStream().write(frame, 1, frame.size - 1)
                        received.addAndGet((frame.size - 1).toLong()); emit()
                    }
                } catch (e: Exception) { finish(e.message ?: "Invalid tunnel data.") }
            }
            override fun onMessage(webSocket: WebSocket, text: String) { finish("The server sent a text frame.") }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(code, null)
                finish(if (localEOF.get() && remoteEOF.get()) null else "The server closed this connection ($code).")
            }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { finish() }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                val message = when (response?.code) {
                    401 -> "Update this server to the Tailscale-authenticated Portside version."
                    403 -> "This device or app port is not allowed. Check Tailscale and the server port policy."
                    502 -> "The remote app is not listening on this port."
                    503 -> "The server is busy or shutting down."
                    504 -> "The remote app connection timed out."
                    else -> "The tunnel disconnected. Check Tailscale and the server."
                }
                finish(message)
            }
            private fun completeIfFinished() {
                if (localEOF.get() && remoteEOF.get()) {
                    ws?.close(1000, null)
                    finish(cancelWebSocket = false)
                }
            }
            fun finish(message: String? = null, cancelWebSocket: Boolean = true) {
                if (!done.compareAndSet(false, true)) return
                opened.countDown()
                runCatching { local.close() }
                if (cancelWebSocket) ws?.cancel()
                tunnels.remove(id); slots.release()
                if (message != null && running.get()) error = message
                emit()
            }
        }
    }
}
