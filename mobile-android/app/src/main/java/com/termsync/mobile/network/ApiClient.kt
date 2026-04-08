package com.termsync.mobile.network

import com.termsync.mobile.TermSyncApplication
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import javax.net.ssl.SSLException
import java.util.concurrent.TimeUnit

data class RegisteredDevice(
    val id: String,
    val name: String,
    val token: String,
    val deviceType: String
)

data class PairingResult(
    val desktopId: String,
    val desktopName: String
)

class ApiClient {
    private val httpClient = OkHttpClient.Builder()
        .sslSocketFactory(TermSyncApplication.sslContext.socketFactory, TermSyncApplication.trustManager)
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    fun registerDevice(serverUrl: String, name: String, deviceType: String): RegisteredDevice {
        val response = postJson(
            normalizeBaseUrl(serverUrl) + "/api/register",
            JSONObject().apply {
                put("name", name)
                put("type", deviceType)
            }
        )

        val json = JSONObject(response)
        val device = json.getJSONObject("device")
        return RegisteredDevice(
            id = device.getString("id"),
            name = device.getString("name"),
            token = device.getString("token"),
            deviceType = device.getString("type")
        )
    }

    fun completePairing(serverUrl: String, token: String, code: String): PairingResult {
        val response = postJson(
            normalizeBaseUrl(serverUrl) + "/api/pairing/complete",
            JSONObject().apply {
                put("token", token)
                put("code", code)
            }
        )

        val json = JSONObject(response)
        val pairing = json.getJSONObject("pairing")
        return PairingResult(
            desktopId = pairing.getString("desktop_id"),
            desktopName = pairing.getString("desktop_name")
        )
    }

    private fun postJson(url: String, body: JSONObject): String {
        val request = Request.Builder()
            .url(url)
            .post(body.toString().toRequestBody("application/json".toMediaType()))
            .build()

        try {
            httpClient.newCall(request).execute().use { response ->
                val payload = response.body?.string().orEmpty()
                if (!response.isSuccessful) {
                    throw IllegalStateException(
                        payload.ifBlank { "HTTP ${response.code}" }
                    )
                }
                return payload
            }
        } catch (e: Exception) {
            throw IllegalStateException(
                "请求失败: ${describeException(e)}",
                e
            )
        }
    }

    private fun normalizeBaseUrl(serverUrl: String): String {
        val trimmed = serverUrl.trim()
        require(trimmed.isNotBlank()) { "Server URL is required" }

        var base = trimmed
            .replaceFirst("wss://", "https://")
            .replaceFirst("ws://", "http://")
        val wsIndex = base.indexOf("/ws")
        if (wsIndex >= 0) {
            base = base.substring(0, wsIndex)
        }
        return base.trimEnd('/')
    }

    private fun describeException(error: Exception): String {
        val message = error.message?.trim().orEmpty()
        return when (error) {
            is SSLException -> if (message.isNotEmpty()) "TLS 证书校验失败: $message" else "TLS 证书校验失败"
            is IOException -> if (message.isNotEmpty()) "网络请求失败: $message" else "网络请求失败"
            else -> if (message.isNotEmpty()) "${error.javaClass.simpleName}: $message" else error.javaClass.simpleName
        }
    }
}
