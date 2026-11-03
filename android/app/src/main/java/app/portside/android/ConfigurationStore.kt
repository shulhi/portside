package app.portside.android

import android.content.Context
import app.portside.core.*
import org.json.JSONArray
import org.json.JSONObject

data class Configuration(val servers: List<ServerProfile> = emptyList(), val forwards: List<ForwardRule> = emptyList())

/** Private profiles and rules; authentication comes from the existing Tailscale connection. */
class ConfigurationStore(context: Context) {
    private val preferences = context.getSharedPreferences("portside", Context.MODE_PRIVATE)

    fun read(): Configuration {
        val json = JSONObject(preferences.getString("configuration", "{}")!!)
        val servers = json.optJSONArray("servers") ?: JSONArray()
        val forwards = json.optJSONArray("forwards") ?: JSONArray()
        return Configuration(
            (0 until servers.length()).map { index ->
                val s = servers.getJSONObject(index)
                ServerProfile(s.getString("id"), s.getString("name"), s.getString("host"), s.getInt("port")).also { it.validate() }
            },
            (0 until forwards.length()).map { index ->
                val f = forwards.getJSONObject(index)
                ForwardRule(f.getString("id"), f.getString("serverId"), f.getString("name"),
                    f.getInt("localPort"), f.getInt("remotePort"), f.getString("family")).also { it.validate() }
            },
        )
    }

    @Synchronized
    fun write(configuration: Configuration) {
        val json = JSONObject().put("servers", JSONArray(configuration.servers.map { s ->
            JSONObject().put("id", s.id).put("name", s.name).put("host", s.host).put("port", s.port)
        })).put("forwards", JSONArray(configuration.forwards.map { f ->
            JSONObject().put("id", f.id).put("serverId", f.serverId).put("name", f.name)
                .put("localPort", f.localPort).put("remotePort", f.remotePort).put("family", f.family)
        }))
        // Replacing the app's settings also retires any no-longer-used credential values.
        check(preferences.edit().clear().putString("configuration", json.toString()).commit()) {
            "Could not save settings. Try again."
        }
    }
}
