package com.bunty.clipsync

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONArray
import java.util.UUID

object DeviceManager {
    private const val PREFS_NAME = "clipsync_prefs"
    private const val SECURE_PREFS_NAME = "clipsync_secure_prefs"
    private const val TAG = "ClipSyncDeviceManager"

    private const val KEY_PAIRED = "is_paired"
    private const val KEY_PAIRED_DEVICE_ID = "paired_device_id"
    private const val KEY_PAIRED_DEVICE_NAME = "paired_device_name"
    private const val KEY_PAIRING_ID = "pairing_id"
    private const val KEY_ENCRYPTION_KEY = "encryption_key"
    private const val KEY_ANDROID_DEVICE_ID = "android_device_id"
    private const val KEY_ANDROID_DEVICE_NAME = "android_device_name"
    private const val KEY_SYNC_TO_MAC = "sync_to_mac"
    private const val KEY_SYNC_FROM_MAC = "sync_from_mac"
    private const val KEY_SERVER_URL = "server_url"
    private const val KEY_SERVER_API_KEY = "server_api_key"
    private const val KEY_LAST_CLIPBOARD_CURSOR = "last_clipboard_cursor"
    private const val KEY_DIRECT_LINK_URLS = "direct_link_urls"
    private const val KEY_DIRECT_LINK_HOSTS = "direct_link_hosts"
    private const val KEY_DIRECT_LINK_PORT = "direct_link_port"

    // Regular prefs for non-sensitive data (device identity, sync toggles)
    private fun getPrefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    // Encrypted prefs for sensitive data (encryption key, API key, server URL, pairing ID)
    private fun getSecurePrefs(context: Context): SharedPreferences {
        return runCatching {
            createEncryptedPrefs(context)
        }.getOrElse { firstError ->
            Log.e(TAG, "Encrypted preferences failed to open, resetting secure storage", firstError)

            context.deleteSharedPreferences(SECURE_PREFS_NAME)
            context.applicationContext
                .getDatabasePath("$SECURE_PREFS_NAME.preferences_pb")
                .delete()

            runCatching {
                createEncryptedPrefs(context)
            }.getOrElse { retryError ->
                Log.e(TAG, "Encrypted preferences still unavailable, falling back to regular prefs", retryError)
                getPrefs(context)
            }
        }
    }

    private fun createEncryptedPrefs(context: Context): SharedPreferences {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        return EncryptedSharedPreferences.create(
            context,
            SECURE_PREFS_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    fun getDeviceId(context: Context): String {
        val prefs = getPrefs(context)
        val existing = prefs.getString(KEY_ANDROID_DEVICE_ID, null)
        if (!existing.isNullOrBlank()) {
            return existing
        }

        val generated = "${Build.MODEL}_${UUID.randomUUID()}"
        prefs.edit().putString(KEY_ANDROID_DEVICE_ID, generated).apply()
        return generated
    }

    fun getAndroidDeviceName(): String {
        val manufacturer = Build.MANUFACTURER ?: ""
        val model = Build.MODEL ?: "Android"

        return when {
            model.contains("sdk", ignoreCase = true) -> "Android Emulator"
            manufacturer.isNotBlank() -> {
                val brand = manufacturer.replaceFirstChar {
                    if (it.isLowerCase()) it.titlecase() else it.toString()
                }
                "$brand $model"
            }
            else -> model
        }.take(20)
    }

    fun isPaired(context: Context): Boolean =
        getPrefs(context).getBoolean(KEY_PAIRED, false)

    fun savePairing(
        context: Context,
        pairingId: String,
        macDeviceId: String,
        macDeviceName: String
    ) {
        getPrefs(context).edit().apply {
            putBoolean(KEY_PAIRED, true)
            putString(KEY_PAIRED_DEVICE_ID, macDeviceId)
            putString(KEY_PAIRED_DEVICE_NAME, macDeviceName)
            putString(KEY_ANDROID_DEVICE_NAME, getAndroidDeviceName())
            apply()
        }
        getSecurePrefs(context).edit().apply {
            putString(KEY_PAIRING_ID, pairingId)
            apply()
        }
        getPrefs(context).edit().putInt(KEY_LAST_CLIPBOARD_CURSOR, 0).apply()
    }

    fun getPairingId(context: Context): String? =
        getSecurePrefs(context).getString(KEY_PAIRING_ID, null)

    fun getPairedMacDeviceId(context: Context): String? =
        getPrefs(context).getString(KEY_PAIRED_DEVICE_ID, null)

    fun getPairedMacDeviceName(context: Context): String =
        getPrefs(context).getString(KEY_PAIRED_DEVICE_NAME, "Unknown Device") ?: "Unknown Device"

    fun clearPairing(context: Context) {
        getPrefs(context).edit().apply {
            putBoolean(KEY_PAIRED, false)
            remove(KEY_PAIRED_DEVICE_ID)
            remove(KEY_PAIRED_DEVICE_NAME)
            apply()
        }
        getSecurePrefs(context).edit().apply {
            remove(KEY_PAIRING_ID)
            remove(KEY_ENCRYPTION_KEY)
            apply()
        }
        getPrefs(context).edit().remove(KEY_LAST_CLIPBOARD_CURSOR).apply()
        clearDirectLinkRouting(context)
    }

    fun getEncryptionKey(context: Context): String {
        val key = getSecurePrefs(context).getString(KEY_ENCRYPTION_KEY, null)
        require(!key.isNullOrBlank()) { "Encryption key not set — device must be paired first" }
        return key
    }

    fun saveEncryptionKey(context: Context, key: String) {
        getSecurePrefs(context).edit().putString(KEY_ENCRYPTION_KEY, key).apply()
    }

    fun isSyncToMacEnabled(context: Context): Boolean =
        getPrefs(context).getBoolean(KEY_SYNC_TO_MAC, true)

    fun setSyncToMacEnabled(context: Context, enabled: Boolean) {
        getPrefs(context).edit().putBoolean(KEY_SYNC_TO_MAC, enabled).apply()
    }

    fun isSyncFromMacEnabled(context: Context): Boolean =
        getPrefs(context).getBoolean(KEY_SYNC_FROM_MAC, true)

    fun setSyncFromMacEnabled(context: Context, enabled: Boolean) {
        getPrefs(context).edit().putBoolean(KEY_SYNC_FROM_MAC, enabled).apply()
    }

    fun getLastClipboardCursor(context: Context): Int =
        getPrefs(context).getInt(KEY_LAST_CLIPBOARD_CURSOR, 0)

    fun saveLastClipboardCursor(context: Context, cursor: Int) {
        getPrefs(context).edit().putInt(KEY_LAST_CLIPBOARD_CURSOR, cursor).apply()
    }

    fun getServerBaseUrl(context: Context): String =
        getSecurePrefs(context).getString(KEY_SERVER_URL, "") ?: ""

    fun getServerApiKey(context: Context): String =
        getSecurePrefs(context).getString(KEY_SERVER_API_KEY, "") ?: ""

    fun hasServerConfiguration(context: Context): Boolean =
        getServerBaseUrl(context).isNotBlank() && getServerApiKey(context).isNotBlank()

    fun saveServerConfiguration(context: Context, baseUrl: String, apiKey: String) {
        val normalizedUrl = normalizeBaseUrl(baseUrl)
        val normalizedKey = apiKey.trim()

        getSecurePrefs(context).edit().apply {
            putString(KEY_SERVER_URL, normalizedUrl)
            putString(KEY_SERVER_API_KEY, normalizedKey)
            apply()
        }
    }

    fun clearServerConfiguration(context: Context) {
        getSecurePrefs(context).edit().apply {
            remove(KEY_SERVER_URL)
            remove(KEY_SERVER_API_KEY)
            apply()
        }
    }

    fun saveDirectLinkRouting(
        context: Context,
        urls: List<String>,
        hostCandidates: List<String>,
        port: Int?
    ) {
        getPrefs(context).edit().apply {
            putString(KEY_DIRECT_LINK_URLS, JSONArray(urls.distinct()).toString())
            putString(KEY_DIRECT_LINK_HOSTS, JSONArray(hostCandidates.distinct()).toString())
            if (port != null && port in 1..65535) {
                putInt(KEY_DIRECT_LINK_PORT, port)
            } else {
                remove(KEY_DIRECT_LINK_PORT)
            }
            apply()
        }
    }

    fun getDirectLinkUrls(context: Context): List<String> =
        getStringList(getPrefs(context).getString(KEY_DIRECT_LINK_URLS, null))

    fun getDirectLinkHostCandidates(context: Context): List<String> =
        getStringList(getPrefs(context).getString(KEY_DIRECT_LINK_HOSTS, null))

    fun getDirectLinkPort(context: Context): Int? {
        val port = getPrefs(context).getInt(KEY_DIRECT_LINK_PORT, 0)
        return port.takeIf { it in 1..65535 }
    }

    fun hasDirectLinkRouting(context: Context): Boolean =
        getPairedMacDeviceId(context)?.isNotBlank() == true &&
            (getDirectLinkUrls(context).isNotEmpty() ||
                getDirectLinkHostCandidates(context).isNotEmpty() ||
                getDirectLinkPort(context) != null)

    fun clearDirectLinkRouting(context: Context) {
        getPrefs(context).edit().apply {
            remove(KEY_DIRECT_LINK_URLS)
            remove(KEY_DIRECT_LINK_HOSTS)
            remove(KEY_DIRECT_LINK_PORT)
            apply()
        }
    }

    private fun normalizeBaseUrl(raw: String): String =
        raw.trim().trimEnd('/')

    private fun getStringList(raw: String?): List<String> {
        if (raw.isNullOrBlank()) return emptyList()

        return runCatching {
            val array = JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) {
                    val value = array.optString(index).trim()
                    if (value.isNotBlank()) {
                        add(value)
                    }
                }
            }
        }.getOrDefault(emptyList())
    }
}
