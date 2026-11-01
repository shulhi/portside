package app.portside.core

import okhttp3.Dns
import okhttp3.HttpUrl
import java.net.InetAddress
import java.net.UnknownHostException
import java.util.UUID

data class ServerProfile(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val host: String,
    val port: Int = 9417,
) {
    fun validate() {
        require(name.isNotBlank()) { "Give this server a name." }
        require(port in 1..65535) { "Server port must be between 1 and 65535." }
        require(AddressPolicy.validHost(host)) { "Use a Tailscale IP, MagicDNS name, or localhost, without a URL or port." }
    }

    fun url(path: String): HttpUrl {
        validate()
        return HttpUrl.Builder().scheme("http").host(host).port(port).encodedPath(path).build()
    }
}

data class ForwardRule(
    val id: String = UUID.randomUUID().toString(),
    val serverId: String,
    val name: String,
    val localPort: Int,
    val remotePort: Int,
    val family: String = "ipv4",
) {
    fun validate() {
        require(name.isNotBlank()) { "Give this forward a name." }
        require(localPort in 1024..65535) { "Local port must be between 1024 and 65535." }
        require(remotePort in 1..65535) { "Remote port must be between 1 and 65535." }
        require(family == "ipv4" || family == "ipv6") { "Choose IPv4 or IPv6 loopback." }
    }

    val browserUrl get() = "http://127.0.0.1:$localPort"
}

enum class Phase { STOPPED, STARTING, LISTENING, FAILED }
data class ForwardSnapshot(
    val phase: Phase = Phase.STOPPED,
    val connections: Int = 0,
    val sentBytes: Long = 0,
    val receivedBytes: Long = 0,
    val error: String? = null,
)

object AddressPolicy {
    fun allowed(address: InetAddress): Boolean {
        val b = address.address.map { it.toInt() and 255 }
        return if (b.size == 4) b[0] == 127 || (b[0] == 100 && b[1] in 64..127)
        else address.isLoopbackAddress || b.take(6) == listOf(0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0)
    }

    fun validHost(host: String): Boolean {
        if (host == "localhost") return true
        if (host.contains(':') || host.all { it.isDigit() || it == '.' }) {
            if (host.contains(':')) {
                if (!host.matches(Regex("[0-9a-fA-F:]+"))) return false
            } else {
                val parts = host.split('.')
                if (parts.size != 4 || parts.any { it.isEmpty() || (it.length > 1 && it.startsWith('0')) || it.toIntOrNull() !in 0..255 }) return false
            }
            return runCatching { HttpUrl.Builder().scheme("http").host(host).build() }
                .map { allowed(InetAddress.getByName(it.host)) }.getOrDefault(false)
        }
        if (host.length !in 1..253) return false
        val labels = host.split('.')
        return labels.all { it.matches(Regex("[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?")) } &&
            (labels.size == 1 || host.endsWith(".ts.net", ignoreCase = true))
    }

    val dns = object : Dns {
        override fun lookup(hostname: String): List<InetAddress> = Dns.SYSTEM.lookup(hostname).also { addresses ->
            if (addresses.isEmpty() || addresses.any { !allowed(it) }) {
                throw UnknownHostException("This host does not resolve to a Tailscale or loopback address.")
            }
        }
    }
}

object TunnelFrame {
    const val PROTOCOL = "portside.tcp.v1"
    const val MAX_DATA = 65536
    fun data(bytes: ByteArray, count: Int = bytes.size): ByteArray {
        require(count in 0..minOf(bytes.size, MAX_DATA)) { "TCP data chunk is too large." }
        return ByteArray(count + 1).also { bytes.copyInto(it, 1, 0, count) }
    }
    fun validate(frame: ByteArray) {
        require(frame.isNotEmpty() && frame.size <= MAX_DATA + 1 &&
            (frame[0] == 0.toByte() || (frame[0] == 1.toByte() && frame.size == 1))) {
            "The server sent an invalid tunnel frame."
        }
    }
}

fun validateToken(value: String): String = value.trim().also {
    require(it.matches(Regex("[0-9a-fA-F]{64}"))) { "Enter the server's 64-character hexadecimal token." }
}
