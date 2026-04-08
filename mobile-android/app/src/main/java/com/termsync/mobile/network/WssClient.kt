package com.termsync.mobile.network

import android.util.Log
import com.termsync.mobile.TermSyncApplication
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import java.util.UUID

/**
 * Data models for WebSocket messages
 */
data class WssMessage(
    val type: String,
    val sessionId: String?,
    val timestamp: Long?,
    val payload: JSONObject?
)

/**
 * Session snapshot for syncing
 */
data class SessionSnapshot(
    val sessionId: String,
    val ownerId: String,
    val title: String,
    val cols: Int,
    val rows: Int,
    val status: String,
    val taskState: String = "",
    val preview: String = "",
    val activity: String = ""
)

/**
 * WSS Client for connecting to TTY1 server
 * Uses self-signed certificate trust from TermSyncApplication
 * Protocol v2: typed messages, owner/viewer routing, snapshot sync
 *
 * Thread-safety: OkHttp WebSocket callbacks fire on background threads while
 * connect()/disconnect()/sendMessage() may be called from coroutines or the
 * main thread.  A monotonically increasing connection generation ID ensures
 * that callbacks from a stale (replaced) connection never overwrite the state
 * of the current connection.
 */
class WssClient {
    companion object {
        private const val TAG = "WssClient"
        const val HEARTBEAT_INTERVAL = 30_000L // 30 seconds
    }

    /** Monotonic generation counter – incremented on every connect(). */
    private val connectionGeneration = AtomicLong(0)

    private val activeSocket = AtomicReference<WebSocket?>(null)
    private lateinit var client: OkHttpClient
    private val messageBuffer = MutableSharedFlow<WssMessage>(extraBufferCapacity = 100)
    private var heartbeatJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.IO)

    private val _isConnected = AtomicBoolean(false)
    var isConnected: Boolean
        get() = _isConnected.get()
        private set(value) { _isConnected.set(value) }

    @Volatile
    var deviceId: String? = null
        private set

    @Volatile
    var lastError: String? = null
        private set

    val messages: SharedFlow<WssMessage> = messageBuffer

    init {
        client = OkHttpClient.Builder()
            .sslSocketFactory(TermSyncApplication.sslContext.socketFactory, TermSyncApplication.trustManager)
            .pingInterval(30, TimeUnit.SECONDS)
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()
    }

    /**
     * Connect to TTY1 server via WSS
     */
    fun connect(url: String, token: String) {
        disconnect()
        lastError = null

        // Bump generation so that any lingering callbacks from the old
        // connection become no-ops.
        val gen = connectionGeneration.incrementAndGet()

        val request = Request.Builder()
            .url(normalizeUrl(url))
            .header("Sec-WebSocket-Protocol", "termsync-protocol")
            .build()

        val ws = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                if (connectionGeneration.get() != gen) return  // stale
                Log.d(TAG, "WebSocket connected (gen=$gen)")
                isConnected = true

                // Send authentication message
                sendAuth(token)

                // Start heartbeat
                startHeartbeat(gen)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                if (connectionGeneration.get() != gen) return  // stale
                try {
                    val json = JSONObject(text)
                    val msg = WssMessage(
                        type = json.optString("type"),
                        sessionId = json.optString("session_id").takeIf { it.isNotEmpty() },
                        timestamp = json.optLong("timestamp").takeIf { it > 0 },
                        payload = json.optJSONObject("payload")
                    )

                    // Handle auth response
                    if (msg.type == "auth_response") {
                        msg.payload?.let { payload ->
                            deviceId = payload.optString("device_id")
                            val deviceType = payload.optString("device_type")
                            Log.d(TAG, "Authenticated as device: $deviceId (type: $deviceType)")
                        }
                    }

                    // Handle error messages
                    if (msg.type == "error") {
                        msg.payload?.let { payload ->
                            val code = payload.optString("code")
                            val message = payload.optString("message")
                            Log.e(TAG, "Server error [$code]: $message")
                        }
                    }

                    scope.launch {
                        messageBuffer.emit(msg)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to parse message", e)
                }
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                Log.d(TAG, "Received binary message: ${bytes.size} bytes")
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                if (connectionGeneration.get() != gen) return  // stale
                Log.d(TAG, "WebSocket closing: $code - $reason (gen=$gen)")
                isConnected = false
                stopHeartbeat()
                scope.launch {
                    messageBuffer.emit(
                        WssMessage(
                            type = "connection.closed",
                            sessionId = null,
                            timestamp = System.currentTimeMillis() / 1000,
                            payload = JSONObject().put("message", reason)
                        )
                    )
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                if (connectionGeneration.get() != gen) return  // stale
                Log.e(TAG, "WebSocket error (gen=$gen)", t)
                isConnected = false
                lastError = t.message
                stopHeartbeat()
                scope.launch {
                    messageBuffer.emit(
                        WssMessage(
                            type = "connection.error",
                            sessionId = null,
                            timestamp = System.currentTimeMillis() / 1000,
                            payload = JSONObject().put("message", t.message ?: "Unknown websocket error")
                        )
                    )
                }
            }
        })

        activeSocket.set(ws)
    }

    /**
     * Disconnect from server
     */
    fun disconnect() {
        // Bump generation to invalidate any pending callbacks
        connectionGeneration.incrementAndGet()
        activeSocket.getAndSet(null)?.close(1000, "Client disconnecting")
        isConnected = false
        stopHeartbeat()
    }

    /**
     * Send message to server
     */
    fun sendMessage(type: String, sessionId: String? = null, payload: JSONObject? = null) {
        if (!isConnected) {
            Log.w(TAG, "Not connected, dropping $type")
            return
        }

        val json = JSONObject().apply {
            put("type", type)
            sessionId?.let { put("session_id", it) }
            put("timestamp", System.currentTimeMillis() / 1000)
            payload?.let { put("payload", it) }
        }

        activeSocket.get()?.send(json.toString())
    }

    /**
     * Send authentication message - protocol v2
     */
    private fun sendAuth(token: String) {
        val payload = JSONObject().apply {
            put("token", token)
            put("device_type", "mobile")
        }
        sendMessage("auth", payload = payload)
    }

    // ─── Protocol v2: Mobile-specific helpers ─────────────────────────────

    /**
     * Request list of all active sessions.
     * Server responds with session.list_res containing session snapshots.
     */
    fun requestSessionList() {
        sendMessage("session.list")
    }

    /**
     * Subscribe to a session to receive terminal output.
     * Server pushes session.state (snapshot) then incremental terminal.output.
     */
    fun subscribeToSession(sessionId: String) {
        sendMessage("session.subscribe", sessionId = sessionId)
    }

    fun requestTerminalReplay(sessionId: String) {
        sendMessage("terminal.replay_request", sessionId = sessionId)
    }

    fun requestRemoteSessionCreate(desktopId: String, title: String? = null) {
        val payload = JSONObject().apply {
            put("desktop_id", desktopId)
            title?.takeIf { it.isNotBlank() }?.let { put("title", it) }
        }
        sendMessage("session.create_request", payload = payload)
    }

    fun requestRemoteSessionClose(sessionId: String) {
        sendMessage("session.close_request", sessionId = sessionId)
    }

    /**
     * Unsubscribe from a session.
     */
    fun unsubscribeFromSession(sessionId: String) {
        sendMessage("session.unsubscribe", sessionId = sessionId)
    }

    /**
     * Send terminal input to a session (requires subscription).
     */
    fun sendTerminalInput(sessionId: String, input: String) {
        val payload = JSONObject().apply {
            put("data", input)
        }
        sendMessage("terminal.input", sessionId = sessionId, payload = payload)
    }

    /**
     * Request terminal resize (requires subscription).
     */
    fun requestResize(sessionId: String, cols: Int, rows: Int) {
        val payload = JSONObject().apply {
            put("cols", cols)
            put("rows", rows)
        }
        sendMessage("terminal.resize", sessionId = sessionId, payload = payload)
    }

    /**
     * Create a new terminal session (requires owner role).
     */
    fun createSession(title: String = "Terminal", cols: Int = 80, rows: Int = 24) {
        val sessionId = UUID.randomUUID().toString()
        val payload = JSONObject().apply {
            put("title", title)
            put("cols", cols)
            put("rows", rows)
        }
        sendMessage("session.create", sessionId = sessionId, payload = payload)
    }

    /**
     * Close a terminal session (owner only).
     */
    fun closeSession(sessionId: String) {
        sendMessage("session.close", sessionId = sessionId)
    }

    /**
     * Send heartbeat to keep connection alive.
     */
    fun sendHeartbeat() {
        sendMessage("heartbeat")
    }

    /**
     * Start periodic heartbeat bound to a specific connection generation.
     * If the generation changes (i.e. a new connect() was called), the
     * heartbeat loop exits automatically.
     */
    private fun startHeartbeat(gen: Long) {
        stopHeartbeat()
        heartbeatJob = scope.launch {
            while (isConnected && connectionGeneration.get() == gen) {
                delay(HEARTBEAT_INTERVAL)
                if (isConnected && connectionGeneration.get() == gen) {
                    sendHeartbeat()
                }
            }
        }
    }

    /**
     * Stop heartbeat
     */
    private fun stopHeartbeat() {
        heartbeatJob?.cancel()
        heartbeatJob = null
    }

    private fun normalizeUrl(url: String): String {
        if (url.endsWith("/ws")) {
            return url
        }
        return if (url.endsWith("/")) "${url}ws" else "$url/ws"
    }
}
