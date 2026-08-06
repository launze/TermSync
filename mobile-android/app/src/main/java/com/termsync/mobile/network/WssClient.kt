package com.termsync.mobile.network

import android.util.Log
import com.termsync.mobile.TermSyncApplication
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONObject
import android.util.Base64
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * Data models for WebSocket messages
 */
data class WssMessage(
    val type: String,
    val id: String?,
    val workspaceId: String?,
    val paneId: String?,
    val sessionId: String?,
    val timestamp: Long?,
    val payload: JSONObject?
)

/**
 * WSS Client for connecting to TTY1 server
 * Uses self-signed certificate trust from TermSyncApplication
 * Protocol v3: workspace/layout/screen/input streams.
 *
 * Thread-safety: OkHttp WebSocket callbacks fire on background threads while
 * connect()/disconnect()/sendMessage() may be called from coroutines or the
 * main thread.  A monotonically increasing connection generation ID ensures
 * that callbacks from a stale (replaced) connection never overwrite the state
 * of the current connection.
 */
class WssClient internal constructor(
    private val client: OkHttpClient = buildDefaultClient()
) {
    private data class QueuedMessage(
        val generation: Long,
        val message: WssMessage
    )

    companion object {
        private const val TAG = "WssClient"
        const val HEARTBEAT_INTERVAL = 30_000L // 30 seconds

        private fun buildDefaultClient(): OkHttpClient = OkHttpClient.Builder()
            .sslSocketFactory(TermSyncApplication.sslContext.socketFactory, TermSyncApplication.trustManager)
            .pingInterval(30, TimeUnit.SECONDS)
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()
    }

    /** Monotonic generation counter – incremented on every connect(). */
    private val connectionGeneration = AtomicLong(0)

    private val activeSocket = AtomicReference<WebSocket?>(null)
    // Retain early auth events and preserve OkHttp callback order.
    private val messageQueue = Channel<QueuedMessage>(Channel.UNLIMITED)
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

    val messages: Flow<WssMessage> = messageQueue.receiveAsFlow()
        .filter { it.generation == connectionGeneration.get() }
        .map { it.message }

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
                // The transport is not usable until auth_response succeeds.
                if (!sendAuth(webSocket, token, gen)) {
                    lastError = "Failed to enqueue authentication"
                    webSocket.cancel()
                }
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                if (connectionGeneration.get() != gen) return  // stale
                try {
                    val json = JSONObject(text)
                    val msg = WssMessage(
                        type = json.optString("type"),
                        id = json.optString("id").takeIf { it.isNotEmpty() },
                        workspaceId = json.optString("workspace_id").takeIf { it.isNotEmpty() },
                        paneId = json.optString("pane_id").takeIf { it.isNotEmpty() },
                        sessionId = json.optString("session_id").takeIf { it.isNotEmpty() },
                        timestamp = json.optLong("timestamp").takeIf { it > 0 },
                        payload = json.optJSONObject("payload")
                    )

                    // Handle auth response
                    if (msg.type == "auth_response") {
                        msg.payload?.let { payload ->
                            val success = payload.optBoolean("success", false)
                            isConnected = success
                            if (success) {
                                deviceId = payload.optString("device_id")
                                val deviceType = payload.optString("device_type")
                                Log.d(TAG, "Authenticated as device: $deviceId (type: $deviceType)")
                                startHeartbeat(gen)
                            } else {
                                deviceId = null
                                lastError = payload.optString("message", "Authentication failed")
                                stopHeartbeat()
                            }
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

                    publishMessage(msg, gen)
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
                activeSocket.compareAndSet(webSocket, null)
                stopHeartbeat()
                publishMessage(
                    WssMessage(
                        type = "connection.closed",
                        id = null,
                        workspaceId = null,
                        paneId = null,
                        sessionId = null,
                        timestamp = System.currentTimeMillis() / 1000,
                        payload = JSONObject().put("message", reason)
                    ),
                    gen
                )
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                if (connectionGeneration.get() != gen) return  // stale
                Log.e(TAG, "WebSocket error (gen=$gen)", t)
                isConnected = false
                activeSocket.compareAndSet(webSocket, null)
                lastError = t.message
                stopHeartbeat()
                publishMessage(
                    WssMessage(
                        type = "connection.error",
                        id = null,
                        workspaceId = null,
                        paneId = null,
                        sessionId = null,
                        timestamp = System.currentTimeMillis() / 1000,
                        payload = JSONObject().put("message", t.message ?: "Unknown websocket error")
                    ),
                    gen
                )
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
        deviceId = null
        stopHeartbeat()
    }

    /**
     * Send message to server
     */
    fun sendMessage(
        type: String,
        workspaceId: String? = null,
        paneId: String? = null,
        sessionId: String? = null,
        payload: JSONObject? = null
    ): Boolean {
        if (!isConnected) {
            Log.w(TAG, "Not authenticated, dropping $type")
            return false
        }

        val json = JSONObject().apply {
            put("type", type)
            put("v", 3)
            put("id", "android-${System.currentTimeMillis()}-${connectionGeneration.get()}")
            workspaceId?.takeIf { it.isNotBlank() }?.let { put("workspace_id", it) }
            paneId?.takeIf { it.isNotBlank() }?.let { put("pane_id", it) }
            sessionId?.let { put("session_id", it) }
            put("timestamp", System.currentTimeMillis() / 1000)
            payload?.let { put("payload", it) }
        }

        val socket = activeSocket.get()
        val sent = socket?.send(json.toString()) == true
        if (!sent) {
            Log.w(TAG, "Failed to enqueue $type")
            failActiveConnection(socket, "Failed to send $type")
        }
        return sent
    }

    /**
     * Send authentication message - protocol v3
     */
    private fun sendAuth(webSocket: WebSocket, token: String, generation: Long): Boolean {
        val payload = JSONObject().apply {
            put("token", token)
            put("device_type", "mobile")
            put("client_instance_id", "android-${android.os.Process.myPid()}")
            put("connection_generation", generation)
            put("supported_protocols", org.json.JSONArray().put(3))
        }
        val json = JSONObject().apply {
            put("type", "auth")
            put("v", 3)
            put("id", "android-${System.currentTimeMillis()}-$generation")
            put("timestamp", System.currentTimeMillis() / 1000)
            put("payload", payload)
        }
        return webSocket.send(json.toString())
    }

    // ─── Protocol v3: Mobile viewer helpers ───────────────────────────────

    /**
     * Request visible v3 workspaces. The server responds with workspace.list_res.
     */
    fun requestSessionList(): Boolean = sendMessage("workspace.list")

    fun subscribeWorkspace(workspaceId: String): Boolean =
        sendMessage("workspace.subscribe", workspaceId = workspaceId, payload = JSONObject().put("workspace_id", workspaceId))

    fun subscribeScreen(workspaceId: String, paneId: String): Boolean {
        val payload = JSONObject()
            .put("pane_id", paneId)
            .put("encoding", "base64+cells-json")
        return sendMessage("screen.subscribe", workspaceId = workspaceId, paneId = paneId, payload = payload)
    }

    fun unsubscribeScreen(workspaceId: String, paneId: String): Boolean =
        sendMessage("screen.unsubscribe", workspaceId = workspaceId, paneId = paneId, payload = JSONObject().put("pane_id", paneId))

    fun requestScreenResync(workspaceId: String, paneId: String, lastSeq: Long): Boolean {
        val payload = JSONObject().apply {
            put("pane_id", paneId)
            put("last_seq", lastSeq)
            put("encoding", "base64+cells-json")
        }
        return sendMessage("screen.resync_request", workspaceId = workspaceId, paneId = paneId, payload = payload)
    }

    fun requestScreenHistory(workspaceId: String, paneId: String, beforeLine: Long, limit: Int = 2000): Boolean {
        val payload = JSONObject().apply {
            put("pane_id", paneId)
            put("request_id", "android-history-${System.currentTimeMillis()}")
            put("before_line", beforeLine)
            put("limit", limit)
            put("encoding", "base64+cells-json")
        }
        return sendMessage("screen.history_request", workspaceId = workspaceId, paneId = paneId, payload = payload)
    }

    fun ackScreen(workspaceId: String, paneId: String, ackSeq: Long): Boolean {
        val payload = JSONObject().apply {
            put("pane_id", paneId)
            put("ack_seq", ackSeq)
        }
        return sendMessage("screen.ack", workspaceId = workspaceId, paneId = paneId, payload = payload)
    }

    fun subscribeToSession(sessionId: String) {
        Log.d(TAG, "subscribeToSession ignored in v3: $sessionId")
    }

    fun requestTerminalReplay(sessionId: String) {
        Log.d(TAG, "requestTerminalReplay ignored in v3: $sessionId")
    }

    fun requestRemoteSessionCreate(desktopId: String, title: String? = null): Boolean {
        val workspaceId = "$desktopId:default"
        val payload = JSONObject().apply {
            put("action", "new_tab")
            title?.takeIf { it.isNotBlank() }?.let { put("title", it) }
        }
        return sendMessage("layout.action_request", workspaceId = workspaceId, payload = payload)
    }

    fun requestRemoteSessionClose(workspaceId: String, paneId: String, sessionId: String): Boolean {
        val payload = JSONObject().apply {
            put("action", "close_pane")
            put("pane_id", paneId)
            put("session_id", sessionId)
        }
        return sendMessage("layout.action_request", workspaceId = workspaceId, paneId = paneId, sessionId = sessionId, payload = payload)
    }

    /**
     * Unsubscribe from a session.
     */
    fun unsubscribeFromSession(sessionId: String) {
        Log.d(TAG, "unsubscribeFromSession ignored in v3: $sessionId")
    }

    fun sendTerminalInput(workspaceId: String, paneId: String, sessionId: String, input: String, inputId: String): Boolean {
        val payload = JSONObject().apply {
            put("input_id", inputId)
            put("encoding", "base64")
            put("mode", "raw")
            put("data", Base64.encodeToString(input.toByteArray(Charsets.UTF_8), Base64.NO_WRAP))
        }
        return sendMessage("input.send", workspaceId = workspaceId, paneId = paneId, sessionId = sessionId, payload = payload)
    }

    /**
     * Request terminal resize (requires subscription).
     */
    fun requestResize(sessionId: String, cols: Int, rows: Int) {
        Log.d(TAG, "requestResize ignored in v3: $sessionId ${cols}x$rows")
    }

    /**
     * Create a new terminal session (requires owner role).
     */
    fun createSession(title: String = "Terminal", cols: Int = 80, rows: Int = 24) {
        Log.d(TAG, "createSession ignored on mobile v3: $title ${cols}x$rows")
    }

    /**
     * Close a terminal session (owner only).
     */
    fun closeSession(sessionId: String) {
        Log.d(TAG, "closeSession ignored in v3: $sessionId")
    }

    /**
     * Send heartbeat to keep connection alive.
     */
    fun sendHeartbeat(): Boolean = sendMessage("heartbeat")

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

    private fun publishMessage(
        message: WssMessage,
        generation: Long = connectionGeneration.get()
    ) {
        val result = messageQueue.trySend(QueuedMessage(generation, message))
        if (result.isFailure) {
            Log.e(TAG, "Failed to queue ${message.type}", result.exceptionOrNull())
        }
    }

    private fun failActiveConnection(socket: WebSocket?, message: String) {
        if (!_isConnected.compareAndSet(true, false)) return
        lastError = message
        activeSocket.compareAndSet(socket, null)
        socket?.cancel()
        stopHeartbeat()
        publishMessage(
            WssMessage(
                type = "connection.error",
                id = null,
                workspaceId = null,
                paneId = null,
                sessionId = null,
                timestamp = System.currentTimeMillis() / 1000,
                payload = JSONObject().put("message", message)
            )
        )
    }

    private fun normalizeUrl(url: String): String {
        if (url.endsWith("/ws")) {
            return url
        }
        return if (url.endsWith("/")) "${url}ws" else "$url/ws"
    }
}
