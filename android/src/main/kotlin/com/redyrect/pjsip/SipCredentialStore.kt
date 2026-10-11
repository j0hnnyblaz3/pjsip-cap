package com.redyrect.pjsip

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The SIP login a push needs to re-register when the app isn't running — the
 * web layer that normally provides it never starts for a push. Encrypted with
 * an AES key that never leaves the Android Keystore; saved when registration
 * is requested, removed on unregister.
 */
internal class SipCredentialStore(context: Context) {
    private val prefs = context.getSharedPreferences("pjsip_sip_login", Context.MODE_PRIVATE)

    fun save(config: SipConfig) {
        val json = JSONObject()
            .put("server", config.server)
            .put("port", config.port)
            .put("username", config.username)
            .put("password", config.password)
            .put("domain", config.domain)
            .put("transport", config.transport)
            .put("proxy", config.proxy ?: JSONObject.NULL)
            .put("srtpPolicy", config.srtpPolicy ?: JSONObject.NULL)
            .put("registerExpiresSec", config.registerExpiresSec)
            .put("keepAliveSec", config.keepAliveSec)
            .put("codecs", org.json.JSONArray(config.codecs))
            .toString()
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(json.toByteArray(Charsets.UTF_8))
        prefs.edit().putString(KEY_LOGIN, Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
    }

    /** The saved login, or null when none is saved or it can't be read. */
    fun load(): SipConfig? {
        val stored = prefs.getString(KEY_LOGIN, null) ?: return null
        return try {
            val sealed = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed, 0, IV_BYTES))
            val json = JSONObject(String(cipher.doFinal(sealed, IV_BYTES, sealed.size - IV_BYTES), Charsets.UTF_8))
            SipConfig(
                server = json.getString("server"),
                port = json.getInt("port"),
                username = json.getString("username"),
                password = json.getString("password"),
                domain = json.getString("domain"),
                transport = json.getString("transport"),
                proxy = json.optString("proxy").takeUnless { json.isNull("proxy") },
                srtpPolicy = json.optString("srtpPolicy").takeUnless { json.isNull("srtpPolicy") },
                registerExpiresSec = json.getInt("registerExpiresSec"),
                keepAliveSec = json.getInt("keepAliveSec"),
                codecs = json.getJSONArray("codecs").let { a -> List(a.length()) { a.getString(it) } },
            )
        } catch (e: Exception) {
            pjsipLog("[SipCredentialStore] saved login unreadable, discarding: ${e.message}")
            clear()
            null
        }
    }

    fun clear() {
        prefs.edit().remove(KEY_LOGIN).apply()
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).run {
            init(
                KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
            generateKey()
        }
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "pjsip_sip_login"
        const val KEY_LOGIN = "login"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
    }
}
