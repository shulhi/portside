package app.portside.android

import android.app.Application
import app.portside.core.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import okhttp3.Request
import org.json.JSONObject

data class ServerStatus(val checking: Boolean = false, val version: String? = null, val error: String? = null, val requestId: String? = null)
data class AppState(
    val configuration: Configuration = Configuration(),
    val snapshots: Map<String, ForwardSnapshot> = emptyMap(),
    val serverStatuses: Map<String, ServerStatus> = emptyMap(),
    val error: String? = null,
)
data class ServerInfo(val version: String, val allowed: List<String>, val excluded: List<Int>) {
    fun allows(port: Int) = port !in excluded && allowed.any {
        val range = it.split('-').mapNotNull(String::toIntOrNull)
        (range.size == 1 && range[0] == port) || (range.size == 2 && port in range[0]..range[1])
    }
}

class PortsideApplication : Application() {
    val state = MutableStateFlow(AppState())
    lateinit var store: ConfigurationStore
        private set
    private var canSave = false
    var revision = 0L
        private set
    val engine = ForwardEngine { id, snapshot ->
        state.update { it.copy(snapshots = it.snapshots + (id to snapshot)) }
    }

    override fun onCreate() {
        super.onCreate()
        store = ConfigurationStore(this)
        try {
            val config = store.read()
            store.write(config)
            state.value = AppState(configuration = config)
            canSave = true
        } catch (_: Exception) { report("Saved settings could not be read. They have been preserved; clear app storage to reset them.") }
    }

    fun report(message: String?) { state.update { it.copy(error = message) } }
    fun snapshot(id: String, value: ForwardSnapshot) { state.update { it.copy(snapshots = it.snapshots + (id to value)) } }
    fun serverStatus(id: String, value: ServerStatus) { state.update { it.copy(serverStatuses = it.serverStatuses + (id to value)) } }

    @Synchronized fun saveServer(server: ServerProfile) {
        server.validate()
        val config = state.value.configuration
        val previous = config.servers.firstOrNull { it.id == server.id }
        val connectionChanged = previous == null || previous.host != server.host || previous.port != server.port
        val next = config.copy(servers = if (previous == null) config.servers + server
            else config.servers.map { if (it.id == server.id) server else it })
        persist(next, invalidateStarts = connectionChanged)
        if (connectionChanged) {
            config.forwards.filter { it.serverId == server.id }.forEach { engine.stop(it.id) }
            state.update { it.copy(serverStatuses = it.serverStatuses - server.id) }
        }
    }
    @Synchronized fun saveForward(rule: ForwardRule) {
        rule.validate()
        val config = state.value.configuration
        require(config.servers.any { it.id == rule.serverId }) { "Choose a saved server." }
        require(config.forwards.none { it.id != rule.id && it.serverId == rule.serverId && it.localPort == rule.localPort }) { "This server already has a forward on that local port. Edit it or choose another port." }
        persist(config.copy(forwards = config.forwards.filterNot { it.id == rule.id } + rule))
        engine.stop(rule.id)
    }
    @Synchronized fun removeServer(id: String) {
        val config = state.value.configuration
        persist(Configuration(config.servers.filterNot { it.id == id }, config.forwards.filterNot { it.serverId == id }))
        config.forwards.filter { it.serverId == id }.forEach { engine.stop(it.id) }
        state.update { it.copy(serverStatuses = it.serverStatuses - id) }
    }
    @Synchronized fun removeForward(id: String) {
        persist(state.value.configuration.let { it.copy(forwards = it.forwards.filterNot { rule -> rule.id == id }) })
        engine.stop(id)
    }
    private fun persist(config: Configuration, invalidateStarts: Boolean = true) {
        check(canSave) { "Settings could not be loaded; the existing data has been preserved." }
        store.write(config)
        if (invalidateStarts) revision++
        state.update { it.copy(configuration = config) }
    }

    fun info(server: ServerProfile): ServerInfo {
        val request = Request.Builder().url(server.url("/v1/info")).build()
        engine.http.newCall(request).execute().use { response ->
            check(response.isSuccessful) {
                when (response.code) {
                    401 -> "Update this server to the Tailscale-authenticated Portside version."
                    403 -> "This device is not owned by the server’s Tailscale user."
                    else -> "The server returned HTTP ${response.code}."
                }
            }
            val json = JSONObject(response.body?.string() ?: error("Empty server response."))
            check(json.getString("authentication") == "tailscale-owner" && json.getString("protocol") == TunnelFrame.PROTOCOL) { "This server uses an incompatible protocol." }
            val allowed = json.getJSONArray("allowed_ports")
            val excluded = json.getJSONArray("excluded_ports")
            return ServerInfo(json.getString("version"), (0 until allowed.length()).map(allowed::getString),
                (0 until excluded.length()).map(excluded::getInt))
        }
    }
}
