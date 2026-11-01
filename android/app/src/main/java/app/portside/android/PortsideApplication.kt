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
    val selectedServerId: String? = null,
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
            state.value = AppState(configuration = config, selectedServerId = config.servers.firstOrNull()?.id)
            canSave = true
        } catch (_: Exception) { report("Saved settings could not be read. They have been preserved; clear app storage to reset them.") }
    }

    fun selectServer(id: String) { state.update { it.copy(selectedServerId = id) } }
    fun report(message: String?) { state.update { it.copy(error = message) } }
    fun snapshot(id: String, value: ForwardSnapshot) { state.update { it.copy(snapshots = it.snapshots + (id to value)) } }
    fun serverStatus(id: String, value: ServerStatus) { state.update { it.copy(serverStatuses = it.serverStatuses + (id to value)) } }

    @Synchronized fun saveServer(server: ServerProfile, replacement: String) {
        server.validate()
        val token = validateToken(replacement.ifBlank { store.token(server.id) })
        val config = state.value.configuration
        val next = config.copy(servers = config.servers.filterNot { it.id == server.id } + server)
        persist(next, server.id to token)
        config.forwards.filter { it.serverId == server.id }.forEach { engine.stop(it.id) }
        state.update { it.copy(selectedServerId = server.id, serverStatuses = it.serverStatuses - server.id) }
    }
    @Synchronized fun saveForward(rule: ForwardRule) {
        rule.validate()
        val config = state.value.configuration
        require(config.servers.any { it.id == rule.serverId }) { "Choose a saved server." }
        require(config.forwards.none { it.id != rule.id && it.localPort == rule.localPort }) { "A saved forward already uses that local port." }
        persist(config.copy(forwards = config.forwards.filterNot { it.id == rule.id } + rule))
        engine.stop(rule.id)
    }
    @Synchronized fun removeServer(id: String) {
        val config = state.value.configuration
        persist(Configuration(config.servers.filterNot { it.id == id }, config.forwards.filterNot { it.serverId == id }), removeToken = id)
        config.forwards.filter { it.serverId == id }.forEach { engine.stop(it.id) }
        state.update { it.copy(selectedServerId = it.configuration.servers.firstOrNull()?.id, serverStatuses = it.serverStatuses - id) }
    }
    @Synchronized fun removeForward(id: String) {
        persist(state.value.configuration.let { it.copy(forwards = it.forwards.filterNot { rule -> rule.id == id }) })
        engine.stop(id)
    }
    private fun persist(config: Configuration, token: Pair<String, String>? = null, removeToken: String? = null) {
        check(canSave) { "Settings could not be loaded; the existing data has been preserved." }
        store.write(config, token, removeToken)
        revision++
        state.update { it.copy(configuration = config) }
    }

    fun info(server: ServerProfile, token: String): ServerInfo {
        val request = Request.Builder().url(server.url("/v1/info"))
            .header("Authorization", "Bearer ${validateToken(token)}").build()
        engine.http.newCall(request).execute().use { response ->
            check(response.isSuccessful) {
                when (response.code) {
                    401 -> "The server rejected this token. Update server settings."
                    403 -> "The server denied access. Check its configuration."
                    else -> "The server returned HTTP ${response.code}."
                }
            }
            val json = JSONObject(response.body?.string() ?: error("Empty server response."))
            check(json.getString("protocol") == TunnelFrame.PROTOCOL) { "This server uses an incompatible protocol." }
            val allowed = json.getJSONArray("allowed_ports")
            val excluded = json.getJSONArray("excluded_ports")
            return ServerInfo(json.getString("version"), (0 until allowed.length()).map(allowed::getString),
                (0 until excluded.length()).map(excluded::getInt))
        }
    }
}
