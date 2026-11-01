package app.portside.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import app.portside.core.*
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class Configuration(val servers: List<ServerProfile> = emptyList(), val forwards: List<ForwardRule> = emptyList())

/** Tokens are AES-GCM encrypted with a non-exportable Android Keystore key. */
class ConfigurationStore(context: Context) {
    private val preferences = context.getSharedPreferences("portside", Context.MODE_PRIVATE)
    private val alias = "app.portside.server-tokens"

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
    fun write(configuration: Configuration, token: Pair<String, String>? = null, removeToken: String? = null) {
        val json = JSONObject().put("servers", JSONArray(configuration.servers.map { s ->
            JSONObject().put("id", s.id).put("name", s.name).put("host", s.host).put("port", s.port)
        })).put("forwards", JSONArray(configuration.forwards.map { f ->
            JSONObject().put("id", f.id).put("serverId", f.serverId).put("name", f.name)
                .put("localPort", f.localPort).put("remotePort", f.remotePort).put("family", f.family)
        }))
        val edit = preferences.edit().putString("configuration", json.toString())
        if (token != null) {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key())
            cipher.updateAAD(token.first.toByteArray(Charsets.UTF_8))
            val ciphertext = cipher.doFinal(validateToken(token.second).toByteArray(Charsets.UTF_8))
            edit.putString("token:${token.first}", encode(cipher.iv) + ":" + encode(ciphertext))
        }
        if (removeToken != null) edit.remove("token:$removeToken")
        check(edit.commit()) { "Could not save settings. Try again." }
    }

    fun token(id: String): String {
        val parts = preferences.getString("token:$id", null)?.split(':')
            ?: error("Enter this server's token in server settings.")
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, decode(parts[0])))
            cipher.updateAAD(id.toByteArray(Charsets.UTF_8))
            String(cipher.doFinal(decode(parts[1])), Charsets.UTF_8)
        } catch (_: Exception) { error("Android Keystore could not unlock this token. Enter it again in server settings.") }
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    private fun encode(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.NO_WRAP)
    private fun decode(value: String) = Base64.decode(value, Base64.NO_WRAP)
}
