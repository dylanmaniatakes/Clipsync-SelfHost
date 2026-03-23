package com.bunty.clipsync

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

class PollingRegistration(private val scope: CoroutineScope, private val job: Job) {
    fun remove() {
        job.cancel()
        scope.cancel()
    }
}

private data class ApiResponse(
    val statusCode: Int,
    val body: JSONObject?
)

private class ApiException(message: String, val statusCode: Int) : Exception(message)

object FirestoreManager {
    private const val TAG = "ClipSyncServer"
    private const val POLL_INTERVAL_MS = 1000L
    private const val CONNECT_TIMEOUT_MS = 5000
    private const val READ_TIMEOUT_MS = 5000

    fun parseQRData(qrData: String): Map<String, Any>? {
        return try {
            if (!qrData.trim().startsWith("{")) {
                return null
            }

            val json = JSONObject(qrData)
            val macId = json.optString("macId").trim()
            if (macId.isBlank()) {
                return null
            }

            mapOf(
                "macDeviceId" to macId,
                "macDeviceName" to json.optString("deviceName")
                    .ifBlank { json.optString("macDeviceName", "Mac") }
                    .trim(),
                "secret" to json.optString("secret").trim(),
                "sessionId" to json.optString("sessionId").trim()
            )
        } catch (_: Exception) {
            null
        }
    }

    fun validateServerConfiguration(
        baseUrl: String,
        apiKey: String,
        onSuccess: () -> Unit,
        onFailure: (Exception) -> Unit
    ) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        scope.launch {
            try {
                request(
                    baseUrl = normalizeBaseUrl(baseUrl),
                    apiKey = apiKey.trim(),
                    method = "GET",
                    path = "/api/v1/server"
                )
                withContext(Dispatchers.Main) { onSuccess() }
            } catch (error: Exception) {
                withContext(Dispatchers.Main) {
                    onFailure(error)
                }
            } finally {
                scope.cancel()
            }
        }
    }

    fun createPairing(
        context: Context,
        qrData: Map<String, Any>,
        onSuccess: (String) -> Unit,
        onFailure: (Exception) -> Unit
    ) {
        val appContext = context.applicationContext
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

        scope.launch {
            try {
                val macDeviceId = qrData["macDeviceId"] as? String ?: throw IllegalArgumentException("Missing Mac device ID")
                val macDeviceName = qrData["macDeviceName"] as? String ?: "Mac"
                val secret = qrData["secret"] as? String
                val sessionId = qrData["sessionId"] as? String

                if (!secret.isNullOrBlank()) {
                    DeviceManager.saveEncryptionKey(appContext, secret)
                }

                val payload = JSONObject().apply {
                    put("macDeviceId", macDeviceId)
                    put("macDeviceName", macDeviceName)
                    put("androidDeviceId", DeviceManager.getDeviceId(appContext))
                    put("androidDeviceName", DeviceManager.getAndroidDeviceName())
                    if (!sessionId.isNullOrBlank()) {
                        put("sessionId", sessionId)
                    }
                }

                val response = request(
                    context = appContext,
                    method = "POST",
                    path = "/api/v1/pairings",
                    body = payload
                )

                val pairing = response.body?.optJSONObject("pairing")
                    ?: throw ApiException("Pairing response missing payload", response.statusCode)
                val pairingId = pairing.optString("pairingId").trim()
                if (pairingId.isBlank()) {
                    throw ApiException("Pairing response missing ID", response.statusCode)
                }

                DeviceManager.savePairing(
                    context = appContext,
                    pairingId = pairingId,
                    macDeviceId = macDeviceId,
                    macDeviceName = macDeviceName
                )

                ClipboardAccessibilityService.refreshClipboardListener()

                withContext(Dispatchers.Main) { onSuccess(pairingId) }
            } catch (error: Exception) {
                Log.e(TAG, "Failed to create pairing", error)
                withContext(Dispatchers.Main) { onFailure(error) }
            } finally {
                scope.cancel()
            }
        }
    }

    fun listenToClipboard(
        context: Context,
        onClipboardUpdate: (String) -> Unit
    ): PollingRegistration? {
        val appContext = context.applicationContext
        val pairingId = DeviceManager.getPairingId(appContext) ?: return null
        val deviceId = DeviceManager.getDeviceId(appContext)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val job = scope.launch {
            var cursor = DeviceManager.getLastClipboardCursor(appContext)

            while (isActive) {
                try {
                    val response = request(
                        context = appContext,
                        method = "GET",
                        path = "/api/v1/pairings/$pairingId/events",
                        query = mapOf(
                            "after" to cursor.toString(),
                            "type" to "clipboard",
                            "excludeDeviceId" to deviceId
                        )
                    )

                    val nextCursor = response.body?.optInt("cursor", cursor) ?: cursor
                    if (nextCursor != cursor) {
                        cursor = nextCursor
                        DeviceManager.saveLastClipboardCursor(appContext, cursor)
                    }
                    val events = response.body?.optJSONArray("events")
                    if (events != null) {
                        for (index in 0 until events.length()) {
                            val event = events.optJSONObject(index) ?: continue
                            val encryptedContent = event.optString("content").trim()
                            if (encryptedContent.isBlank()) continue

                            try {
                                val decrypted = decryptData(appContext, encryptedContent)
                                if (decrypted.isNotBlank()) {
                                    withContext(Dispatchers.Main) {
                                        onClipboardUpdate(decrypted)
                                    }
                                }
                            } catch (error: Exception) {
                                Log.e(TAG, "Failed to decrypt clipboard payload", error)
                            }
                        }
                    }
                } catch (error: ApiException) {
                    if (error.statusCode == 404 || error.statusCode == 410) {
                        DeviceManager.clearPairing(appContext)
                        break
                    }
                    Log.e(TAG, "Clipboard poll failed", error)
                } catch (error: Exception) {
                    Log.e(TAG, "Clipboard poll failed", error)
                }

                delay(POLL_INTERVAL_MS)
            }
        }

        return PollingRegistration(scope, job)
    }

    fun sendClipboard(
        context: Context,
        text: String,
        onSuccess: () -> Unit = {},
        onFailure: (Exception) -> Unit = {}
    ) {
        val appContext = context.applicationContext
        val pairingId = DeviceManager.getPairingId(appContext)
        if (pairingId.isNullOrBlank()) {
            onFailure(Exception("No pairing ID found"))
            return
        }

        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        scope.launch {
            try {
                val payload = JSONObject().apply {
                    put("sourceDeviceId", DeviceManager.getDeviceId(appContext))
                    put("sourceDeviceName", DeviceManager.getAndroidDeviceName())
                    put("content", encryptData(appContext, text))
                }

                request(
                    context = appContext,
                    method = "POST",
                    path = "/api/v1/pairings/$pairingId/clipboard",
                    body = payload
                )

                withContext(Dispatchers.Main) { onSuccess() }
            } catch (error: Exception) {
                Log.e(TAG, "Failed to send clipboard", error)
                withContext(Dispatchers.Main) { onFailure(error) }
            } finally {
                scope.cancel()
            }
        }
    }

    fun sendOtpNotification(
        context: Context,
        encryptedOtp: String,
        onSuccess: () -> Unit = {},
        onFailure: (Exception) -> Unit = {}
    ) {
        val appContext = context.applicationContext
        val pairingId = DeviceManager.getPairingId(appContext)
        if (pairingId.isNullOrBlank()) {
            onFailure(Exception("No pairing ID found"))
            return
        }

        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        scope.launch {
            try {
                val payload = JSONObject().apply {
                    put("sourceDeviceId", DeviceManager.getDeviceId(appContext))
                    put("sourceDeviceName", DeviceManager.getAndroidDeviceName())
                    put("encryptedOTP", encryptedOtp)
                }

                request(
                    context = appContext,
                    method = "POST",
                    path = "/api/v1/pairings/$pairingId/otp",
                    body = payload
                )

                withContext(Dispatchers.Main) { onSuccess() }
            } catch (error: Exception) {
                Log.e(TAG, "Failed to send OTP", error)
                withContext(Dispatchers.Main) { onFailure(error) }
            } finally {
                scope.cancel()
            }
        }
    }

    fun clearPairing(
        context: Context,
        onSuccess: () -> Unit = {},
        onFailure: (Exception) -> Unit = {}
    ) {
        val appContext = context.applicationContext
        val pairingId = DeviceManager.getPairingId(appContext) ?: return
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

        scope.launch {
            try {
                request(
                    context = appContext,
                    method = "DELETE",
                    path = "/api/v1/pairings/$pairingId"
                )
            } catch (error: ApiException) {
                if (error.statusCode != 404 && error.statusCode != 410) {
                    withContext(Dispatchers.Main) { onFailure(error) }
                    scope.cancel()
                    return@launch
                }
            } catch (error: Exception) {
                withContext(Dispatchers.Main) { onFailure(error) }
                scope.cancel()
                return@launch
            }

            DeviceManager.clearPairing(appContext)
            withContext(Dispatchers.Main) { onSuccess() }
            scope.cancel()
        }
    }

    fun clearClipboard(
        context: Context,
        onSuccess: () -> Unit = {},
        onFailure: (Exception) -> Unit = {}
    ) {
        val appContext = context.applicationContext
        val pairingId = DeviceManager.getPairingId(appContext)
        if (pairingId.isNullOrBlank()) {
            onFailure(Exception("No pairing ID found"))
            return
        }

        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        scope.launch {
            try {
                request(
                    context = appContext,
                    method = "DELETE",
                    path = "/api/v1/pairings/$pairingId/clipboard"
                )
                withContext(Dispatchers.Main) { onSuccess() }
            } catch (error: Exception) {
                Log.e(TAG, "Failed to clear clipboard", error)
                withContext(Dispatchers.Main) { onFailure(error) }
            } finally {
                scope.cancel()
            }
        }
    }

    private fun decryptData(context: Context, encryptedBase64: String): String {
        val encryptedBytes = android.util.Base64.decode(encryptedBase64, android.util.Base64.NO_WRAP)
        if (encryptedBytes.size < 28) return ""

        val keySpec = javax.crypto.spec.SecretKeySpec(hexStringToByteArray(DeviceManager.getEncryptionKey(context)), "AES")
        val iv = encryptedBytes.copyOfRange(0, 12)
        val ciphertext = encryptedBytes.copyOfRange(12, encryptedBytes.size)

        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(javax.crypto.Cipher.DECRYPT_MODE, keySpec, javax.crypto.spec.GCMParameterSpec(128, iv))

        return String(cipher.doFinal(ciphertext), Charsets.UTF_8)
    }

    private fun encryptData(context: Context, plainText: String): String {
        val keySpec = javax.crypto.spec.SecretKeySpec(hexStringToByteArray(DeviceManager.getEncryptionKey(context)), "AES")
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        val iv = ByteArray(12).also { java.security.SecureRandom().nextBytes(it) }
        cipher.init(javax.crypto.Cipher.ENCRYPT_MODE, keySpec, javax.crypto.spec.GCMParameterSpec(128, iv))

        val ciphertext = cipher.doFinal(plainText.toByteArray(Charsets.UTF_8))
        val combined = ByteArray(iv.size + ciphertext.size)
        System.arraycopy(iv, 0, combined, 0, iv.size)
        System.arraycopy(ciphertext, 0, combined, iv.size, ciphertext.size)

        return android.util.Base64.encodeToString(combined, android.util.Base64.NO_WRAP)
    }

    private fun hexStringToByteArray(value: String): ByteArray {
        val data = ByteArray(value.length / 2)
        var index = 0
        while (index < value.length) {
            data[index / 2] =
                ((Character.digit(value[index], 16) shl 4) + Character.digit(value[index + 1], 16)).toByte()
            index += 2
        }
        return data
    }

    private fun request(
        context: Context,
        method: String,
        path: String,
        query: Map<String, String> = emptyMap(),
        body: JSONObject? = null
    ): ApiResponse {
        return request(
            baseUrl = DeviceManager.getServerBaseUrl(context),
            apiKey = DeviceManager.getServerApiKey(context),
            method = method,
            path = path,
            query = query,
            body = body
        )
    }

    private fun request(
        baseUrl: String,
        apiKey: String,
        method: String,
        path: String,
        query: Map<String, String> = emptyMap(),
        body: JSONObject? = null
    ): ApiResponse {
        val normalizedBaseUrl = normalizeBaseUrl(baseUrl)
        if (normalizedBaseUrl.isBlank()) {
            throw IllegalStateException("Server URL is not configured")
        }

        if (apiKey.isBlank()) {
            throw IllegalStateException("Server API key is not configured")
        }

        val url = buildUrl(normalizedBaseUrl, path, query)
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = READ_TIMEOUT_MS
            setRequestProperty("Accept", "application/json")
            setRequestProperty("X-ClipSync-Key", apiKey)
            doInput = true
        }

        try {
            if (body != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                connection.outputStream.use { stream ->
                    stream.write(body.toString().toByteArray(Charsets.UTF_8))
                }
            }

            val statusCode = connection.responseCode
            val inputStream = if (statusCode >= 400) connection.errorStream else connection.inputStream
            val rawBody = inputStream?.use { stream ->
                BufferedReader(InputStreamReader(stream)).readText()
            }.orEmpty()

            val jsonBody = rawBody.takeIf { it.isNotBlank() }?.let { JSONObject(it) }
            if (statusCode >= 400) {
                val message = jsonBody?.optString("error").orEmpty().ifBlank {
                    "Request failed with HTTP $statusCode"
                }
                throw ApiException(message, statusCode)
            }

            return ApiResponse(statusCode = statusCode, body = jsonBody)
        } finally {
            connection.disconnect()
        }
    }

    private fun buildUrl(baseUrl: String, path: String, query: Map<String, String>): String {
        val queryString = query.entries
            .filter { it.value.isNotBlank() }
            .joinToString("&") { entry ->
                "${java.net.URLEncoder.encode(entry.key, "UTF-8")}=" +
                    java.net.URLEncoder.encode(entry.value, "UTF-8")
            }

        return if (queryString.isBlank()) {
            "$baseUrl$path"
        } else {
            "$baseUrl$path?$queryString"
        }
    }

    private fun normalizeBaseUrl(raw: String): String =
        raw.trim().trimEnd('/')
}
