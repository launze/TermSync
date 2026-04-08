package com.termsync.mobile.viewmodel

import android.app.Application
import android.content.Context
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.termsync.mobile.network.ApiClient
import com.termsync.mobile.network.WssClient
import com.termsync.mobile.network.WssMessage
import kotlinx.coroutines.Job
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

sealed class ConnectionState {
    object Disconnected : ConnectionState()
    object Connecting : ConnectionState()
    data class Connected(val deviceId: String, val deviceType: String) : ConnectionState()
    data class Error(val message: String) : ConnectionState()
}

enum class SpecialKey(val escapeSequence: String) {
    Escape("\u001B"),
    Tab("\u0009"),
    ArrowUp("\u001B[A"),
    ArrowDown("\u001B[B"),
    ArrowLeft("\u001B[D"),
    ArrowRight("\u001B[C"),
    CtrlC("\u0003"),
    CtrlD("\u0004"),
    CtrlZ("\u001A"),
    Enter("\r"),
    Backspace("\u007F"),
    Home("\u001B[H"),
    End("\u001B[F"),
    PageUp("\u001B[5~"),
    PageDown("\u001B[6~"),
    F1("\u001BOP"),
    F2("\u001BOQ"),
    F3("\u001BOR"),
    F4("\u001BOS"),
    F5("\u001B[15~"),
    F6("\u001B[17~"),
    F7("\u001B[18~"),
    F8("\u001B[19~"),
    F9("\u001B[20~"),
    F10("\u001B[21~"),
    F11("\u001B[23~"),
    F12("\u001B[24~")
}

data class TerminalSession(
    val sessionId: String,
    val title: String,
    val cols: Int,
    val rows: Int,
    val status: String,
    val isOwner: Boolean = false,
    val activity: String = "",
    val taskState: String = "",
    val preview: String = "",
    val lastActivityAt: Long = 0L
)

data class TerminalDeltaBatch(
    val sessionId: String,
    val data: String,
    val version: Long
)

class MainViewModel(application: Application) : AndroidViewModel(application) {

    private data class PendingTerminalDelta(
        val sessionId: String,
        val data: String,
        val version: Long
    )

    private val prefs = application.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val apiClient = ApiClient()
    private val wssClient = WssClient()
    private val observedSessionIds = mutableSetOf<String>()
    private val _connectionState = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    private val _sessions = MutableStateFlow<List<TerminalSession>>(emptyList())
    private val _selectedSessionId = MutableStateFlow<String?>(null)
    private val _terminalOutput = MutableStateFlow<String>("")
    private val _terminalOutputVersion = MutableStateFlow(0L)
    // Raw delta channel: every terminal.output chunk goes here
    private val _rawDeltaChannel = Channel<PendingTerminalDelta>(Channel.UNLIMITED)
    // Batched delta flow: merged every DELTA_BATCH_MS, consumed by WebView LaunchedEffect
    private val _terminalDelta = MutableSharedFlow<TerminalDeltaBatch>(extraBufferCapacity = 64)
    private val _debugLog = MutableStateFlow<List<String>>(emptyList())
    private var _debugOutputMsgCount = 0
    private var _debugOutputTotalBytes = 0L
    private var _debugReplayCount = 0
    private val _statusMessage = MutableStateFlow<String>("")
    private val _replayLoading = MutableStateFlow(false)
    private val _terminalStreamStatus = MutableStateFlow("等待进入终端")
    private val _serverUrl = MutableStateFlow(prefs.getString(KEY_SERVER_URL, "wss://nas.smarthome2020.top:7373/ws") ?: "wss://nas.smarthome2020.top:7373/ws")
    private val _deviceToken = MutableStateFlow(prefs.getString(KEY_DEVICE_TOKEN, "") ?: "")
    private val _deviceName = MutableStateFlow(prefs.getString(KEY_DEVICE_NAME, "我的手机") ?: "我的手机")
    private val _pairedDesktopId = MutableStateFlow(prefs.getString(KEY_PAIRED_DESKTOP_ID, "") ?: "")
    private val _pairedDesktopName = MutableStateFlow(prefs.getString(KEY_PAIRED_DESKTOP_NAME, "") ?: "")
    private val _isPaired = MutableStateFlow(_pairedDesktopId.value.isNotBlank())
    private val sessionOutputCache = loadSessionOutputCache().toMutableMap()
    private val sessionOutputVersion = mutableMapOf<String, Long>()
    private val lastRequestedResizeBySession = mutableMapOf<String, Pair<Int, Int>>()
    private val lastResizeRequestAtBySession = mutableMapOf<String, Long>()
    private var reconnectJob: Job? = null
    private var outputCachePersistJob: Job? = null
    private var sessionListRetryJob: Job? = null
    private var manualDisconnect = false
    private var reconnectAttempts = 0

    companion object {
        private const val TAG = "MainViewModel"
        private const val PREFS_NAME = "termsync_prefs"
        private const val KEY_SERVER_URL = "server_url"
        private const val KEY_DEVICE_TOKEN = "device_token"
        private const val KEY_DEVICE_NAME = "device_name"
        private const val KEY_PAIRED_DESKTOP_ID = "paired_desktop_id"
        private const val KEY_PAIRED_DESKTOP_NAME = "paired_desktop_name"
        private const val KEY_SESSION_OUTPUT_CACHE = "session_output_cache"
        private const val RECONNECT_DELAY_MS = 3_000L
        private const val MAX_RECONNECT_DELAY_MS = 60_000L
        /** Batched delta flush interval in ms — controls max render rate (~20fps) */
        private const val DELTA_BATCH_MS = 50L
    }

    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()
    val sessions: StateFlow<List<TerminalSession>> = _sessions.asStateFlow()
    val selectedSessionId: StateFlow<String?> = _selectedSessionId.asStateFlow()
    val terminalOutput: StateFlow<String> = _terminalOutput.asStateFlow()
    val terminalOutputVersion: StateFlow<Long> = _terminalOutputVersion.asStateFlow()
    val terminalDelta: SharedFlow<TerminalDeltaBatch> = _terminalDelta
    val debugLog: StateFlow<List<String>> = _debugLog.asStateFlow()
    val statusMessage: StateFlow<String> = _statusMessage.asStateFlow()
    val replayLoading: StateFlow<Boolean> = _replayLoading.asStateFlow()
    val terminalStreamStatus: StateFlow<String> = _terminalStreamStatus.asStateFlow()
    val serverUrl: StateFlow<String> = _serverUrl.asStateFlow()
    val deviceToken: StateFlow<String> = _deviceToken.asStateFlow()
    val deviceName: StateFlow<String> = _deviceName.asStateFlow()
    val pairedDesktopId: StateFlow<String> = _pairedDesktopId.asStateFlow()
    val pairedDesktopName: StateFlow<String> = _pairedDesktopName.asStateFlow()
    val isPaired: StateFlow<Boolean> = _isPaired.asStateFlow()

    init {
        viewModelScope.launch {
            wssClient.messages.collect { msg -> handleMessage(msg) }
        }
        // Delta batching coroutine: merges rapid terminal output into ~20fps batches
        viewModelScope.launch {
            while (isActive) {
                val first = _rawDeltaChannel.receive()
                val batchBySession = linkedMapOf<String, StringBuilder>()
                val versionBySession = mutableMapOf<String, Long>()

                fun append(delta: PendingTerminalDelta) {
                    val builder = batchBySession.getOrPut(delta.sessionId) { StringBuilder() }
                    builder.append(delta.data)
                    versionBySession[delta.sessionId] = maxOf(versionBySession[delta.sessionId] ?: 0L, delta.version)
                }

                // Block until at least one delta arrives
                append(first)
                // Accumulate more deltas for DELTA_BATCH_MS
                delay(DELTA_BATCH_MS)
                // Drain everything that accumulated
                while (true) {
                    val more = _rawDeltaChannel.tryReceive().getOrNull() ?: break
                    append(more)
                }
                batchBySession.forEach { (sessionId, builder) ->
                    val data = builder.toString()
                    if (data.isNotEmpty()) {
                        _terminalDelta.emit(
                            TerminalDeltaBatch(
                                sessionId = sessionId,
                                data = data,
                                version = versionBySession[sessionId] ?: 0L
                            )
                        )
                    }
                }
            }
        }
        autoConnectIfPossible()
    }

    private fun handleMessage(msg: WssMessage) {
        if (msg.type != "heartbeat") {
            dbg("MSG type=${msg.type} sid=${msg.sessionId?.take(8)} hasPayload=${msg.payload != null}")
        }
        when (msg.type) {
            "auth_response" -> {
                msg.payload?.let { payload ->
                    val success = payload.optBoolean("success", false)
                    if (success) {
                        val devId = payload.optString("device_id", "unknown")
                        val devType = payload.optString("device_type", "unknown")
                        observedSessionIds.clear()
                        reconnectAttempts = 0
                        cancelReconnect()
                        _connectionState.value = ConnectionState.Connected(devId, devType)
                        _statusMessage.value = "已连接服务器，正在同步终端列表…"
                        dbg("AUTH OK devId=$devId type=$devType")
                        wssClient.requestSessionList()
                        scheduleSessionListRetry()
                    } else {
                        cancelReconnect()
                        cancelSessionListRetry()
                        _connectionState.value = ConnectionState.Error("Authentication failed")
                        _statusMessage.value = "认证失败，请检查手机设备 Token"
                    }
                }
            }
            "session.list_res" -> {
                msg.payload?.let { payload ->
                    val sessionsArray = payload.optJSONArray("sessions")
                    if (sessionsArray != null) {
                        dbg("SESSION_LIST count=${sessionsArray.length()}")
                        val previousById = _sessions.value.associateBy { it.sessionId }
                        val sessionList = mutableListOf<TerminalSession>()
                        for (i in 0 until sessionsArray.length()) {
                            val obj = sessionsArray.getJSONObject(i)
                            val sessionId = obj.optString("session_id")
                            val previous = previousById[sessionId]
                            sessionList.add(parseSessionSnapshot(obj, previous, sessionId))
                            subscribeForPreview(sessionId)
                        }
                        _sessions.value = sessionList
                        if (sessionList.isEmpty()) {
                            _statusMessage.value = "已连接服务器，当前没有可用终端"
                            scheduleSessionListRetry()
                        } else {
                            _statusMessage.value = ""
                            cancelSessionListRetry()
                        }
                        Log.d(TAG, "Received ${sessionList.size} sessions")
                    }
                }
            }
            "session.create" -> {
                if (_connectionState.value is ConnectionState.Connected) {
                    wssClient.requestSessionList()
                    scheduleSessionListRetry()
                }
            }
            "session.state" -> {
                msg.payload?.let { payload ->
                    val snapshot = payload.optJSONObject("snapshot") ?: payload
                    val sessionId = snapshot.optString("session_id", msg.sessionId ?: "")
                    val previous = _sessions.value.firstOrNull { it.sessionId == sessionId }
                    val session = parseSessionSnapshot(snapshot, previous, sessionId)
                    val existing = _sessions.value.filterNot { it.sessionId == session.sessionId }
                    _sessions.value = existing + session
                    _statusMessage.value = ""
                    subscribeForPreview(session.sessionId)
                    cancelSessionListRetry()
                }
            }
            "terminal.output" -> {
                msg.payload?.let { payload ->
                    val data = payload.optString("data", "")
                    _debugOutputMsgCount++
                    _debugOutputTotalBytes += data.length
                    val selSid = _selectedSessionId.value
                    val matches = msg.sessionId == selSid
                    // Only log every 50th message to avoid recomposition storm from _debugLog updates
                    if (_debugOutputMsgCount <= 3 || _debugOutputMsgCount % 50 == 0) {
                        dbg("TERM_OUT #$_debugOutputMsgCount sid=${msg.sessionId?.take(8)} data.len=${data.length} totalBytes=$_debugOutputTotalBytes match=$matches")
                    }
                    if (msg.sessionId != null && data.isNotEmpty()) {
                        val existing = sessionOutputCache[msg.sessionId].orEmpty()
                        sessionOutputCache[msg.sessionId] = trimReplay(existing + data)
                        val version = nextSessionOutputVersion(msg.sessionId)
                        scheduleSessionOutputCacheSave()
                        if (matches) {
                            // Send raw delta to batching channel — NOT directly to UI
                            _rawDeltaChannel.trySend(
                                PendingTerminalDelta(
                                    sessionId = msg.sessionId,
                                    data = data,
                                    version = version
                                )
                            )
                        }
                    }
                    if (matches) {
                        _replayLoading.value = false
                        _terminalStreamStatus.value = "实时同步中"
                    }
                    val preview = extractPreview(data)
                    if (msg.sessionId != null) {
                        val now = System.currentTimeMillis()
                        _sessions.value = _sessions.value.map { session ->
                            if (session.sessionId == msg.sessionId) {
                                session.copy(
                                    activity = session.activity.ifBlank { preview },
                                    taskState = session.taskState.ifBlank { "running" },
                                    preview = preview.ifBlank { session.preview },
                                    lastActivityAt = now
                                )
                            } else {
                                session
                            }
                        }
                    }
                }
            }
            "terminal.replay" -> {
                msg.payload?.let { payload ->
                    val data = payload.optString("data", "")
                    val sessionId = msg.sessionId
                    _debugReplayCount++
                    dbg("REPLAY #$_debugReplayCount sid=${sessionId?.take(8)} data.len=${data.length} selected=${_selectedSessionId.value?.take(8)}")
                    if (!sessionId.isNullOrBlank()) {
                        val merged = mergeReplayWithLive(data, sessionOutputCache[sessionId].orEmpty())
                        sessionOutputCache[sessionId] = trimReplay(merged)
                        scheduleSessionOutputCacheSave()
                        if (_selectedSessionId.value == sessionId) {
                            _terminalOutput.value = sessionOutputCache[sessionId].orEmpty()
                            _terminalOutputVersion.value = currentSessionOutputVersion(sessionId)
                            _replayLoading.value = false
                            _terminalStreamStatus.value = if (data.isNotBlank()) "已加载桌面端回放" else "桌面端暂无可回放内容"
                        }
                    }
                }
            }
            "session.close" -> {
                val sid = msg.sessionId
                if (sid != null) {
                    observedSessionIds.remove(sid)
                    sessionOutputCache.remove(sid)
                    scheduleSessionOutputCacheSave()
                    _sessions.value = _sessions.value.filter { it.sessionId != sid }
                    if (_selectedSessionId.value == sid) {
                        _selectedSessionId.value = null
                        _terminalOutput.value = ""
                        _terminalOutputVersion.value = 0L
                        _replayLoading.value = false
                        _terminalStreamStatus.value = "终端已关闭"
                    }
                }
            }
            "connection.error" -> {
                val message = msg.payload?.optString("message", "Connection failed") ?: "Connection failed"
                _connectionState.value = ConnectionState.Error(message)
                _statusMessage.value = message
                cancelSessionListRetry()
                if (_selectedSessionId.value != null) {
                    _terminalStreamStatus.value = "实时连接异常，等待自动重连"
                }
                scheduleReconnect(message)
            }
            "connection.closed" -> {
                _connectionState.value = ConnectionState.Disconnected
                cancelSessionListRetry()
                if (_selectedSessionId.value != null) {
                    _terminalStreamStatus.value = "连接已关闭，等待自动重连"
                }
                scheduleReconnect(msg.payload?.optString("message", "连接已关闭") ?: "连接已关闭")
            }
            "error" -> {
                msg.payload?.let { payload ->
                    val code = payload.optString("code")
                    val message = payload.optString("message")
                    Log.e(TAG, "Server error [$code]: $message")
                    _statusMessage.value = "[$code] $message"
                }
            }
            else -> {
                Log.d(TAG, "Unhandled message type: ${msg.type}")
            }
        }
    }

    fun connect(url: String, token: String) {
        saveConnectionSettings(url, token, _deviceName.value)
        manualDisconnect = false
        cancelReconnect()
        _connectionState.value = ConnectionState.Connecting
        _statusMessage.value = "正在连接桌面终端服务…"
        wssClient.connect(url.trim(), token.trim())
    }

    fun updateServerUrl(value: String) {
        _serverUrl.value = value
    }

    fun updateDeviceToken(value: String) {
        _deviceToken.value = value
    }

    fun updateDeviceName(value: String) {
        _deviceName.value = value
    }

    fun registerMobileDevice() {
        val url = _serverUrl.value.trim()
        val name = _deviceName.value.trim().ifBlank { "我的手机" }
        if (url.isBlank()) {
            _statusMessage.value = "请先填写服务器地址"
            return
        }

        viewModelScope.launch {
            try {
                val device = withContext(Dispatchers.IO) {
                    apiClient.registerDevice(url, name, "mobile")
                }
                saveConnectionSettings(url, device.token, device.name)
                clearPairingState()
                _statusMessage.value = "手机设备已注册: ${device.name}"
            } catch (e: Exception) {
                Log.e(TAG, "Failed to register mobile device", e)
                _statusMessage.value = "注册手机设备失败: ${describeException(e)}"
            }
        }
    }

    fun completePairing(code: String) {
        val url = _serverUrl.value.trim()
        val token = _deviceToken.value.trim()
        if (url.isBlank()) {
            _statusMessage.value = "请先填写服务器地址"
            return
        }
        if (token.isBlank()) {
            _statusMessage.value = "请先注册手机设备获取 Token"
            return
        }
        if (code.isBlank()) {
            _statusMessage.value = "请输入桌面配对码"
            return
        }

        viewModelScope.launch {
            try {
                val result = withContext(Dispatchers.IO) {
                    apiClient.completePairing(url, token, code)
                }
                savePairingState(result.desktopId, result.desktopName)
                _statusMessage.value = "已绑定桌面: ${result.desktopName}"
                if (_connectionState.value is ConnectionState.Connected) {
                    wssClient.requestSessionList()
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to complete pairing", e)
                _statusMessage.value = "配对失败: ${describeException(e)}"
            }
        }
    }

    fun disconnect() {
        manualDisconnect = true
        cancelReconnect()
        cancelSessionListRetry()
        wssClient.disconnect()
        observedSessionIds.clear()
        _connectionState.value = ConnectionState.Disconnected
        _sessions.value = emptyList()
        _selectedSessionId.value = null
        _terminalOutput.value = ""
        _terminalOutputVersion.value = 0L
        _replayLoading.value = false
        _terminalStreamStatus.value = "已断开连接"
        _statusMessage.value = "已断开连接"
    }

    private var replayTimeoutJob: Job? = null

    fun selectSession(sessionId: String?) {
        if (sessionId.isNullOrBlank()) {
            dbg("SELECT_SESSION -> null (deselect)")
            _selectedSessionId.value = null
            _terminalOutput.value = ""
            _terminalOutputVersion.value = 0L
            _replayLoading.value = false
            _terminalStreamStatus.value = "等待进入终端"
            replayTimeoutJob?.cancel()
            return
        }

        val cachedLen = sessionOutputCache[sessionId].orEmpty().length
        dbg("SELECT_SESSION sid=${sessionId.take(8)} cache.len=$cachedLen")
        _selectedSessionId.value = sessionId
        _terminalOutput.value = sessionOutputCache[sessionId].orEmpty()
        _terminalOutputVersion.value = currentSessionOutputVersion(sessionId)
        dbg("SELECT_SESSION output.len=${_terminalOutput.value.length}")
        _replayLoading.value = _terminalOutput.value.isBlank()
        _terminalStreamStatus.value = if (_terminalOutput.value.isBlank()) "正在请求桌面端回放…" else "已加载本地缓存，正在同步实时输出"
        subscribeForPreview(sessionId, force = true)
        wssClient.requestTerminalReplay(sessionId)
        
        // 添加超时处理，防止一直等待
        replayTimeoutJob?.cancel()
        replayTimeoutJob = viewModelScope.launch {
            delay(5000) // 5秒超时
            if (_selectedSessionId.value == sessionId && _replayLoading.value) {
                _replayLoading.value = false
                _terminalStreamStatus.value = "回放请求超时，显示本地缓存"
            }
        }
    }

    fun refreshSelectedSessionReplay() {
        val sessionId = _selectedSessionId.value ?: return
        _replayLoading.value = true
        _terminalStreamStatus.value = "正在刷新桌面端回放…"
        wssClient.requestTerminalReplay(sessionId)
        
        // 添加超时处理
        replayTimeoutJob?.cancel()
        replayTimeoutJob = viewModelScope.launch {
            delay(5000) // 5秒超时
            if (_selectedSessionId.value == sessionId && _replayLoading.value) {
                _replayLoading.value = false
                _terminalStreamStatus.value = "刷新请求超时，显示当前内容"
            }
        }
    }

    fun sendInput(input: String) {
        val sessionId = _selectedSessionId.value ?: return
        wssClient.sendTerminalInput(sessionId, input)
    }

    fun sendSpecialKey(key: SpecialKey) {
        val sessionId = _selectedSessionId.value ?: return
        wssClient.sendTerminalInput(sessionId, key.escapeSequence)
    }

    fun requestSelectedSessionResize(cols: Int, rows: Int, force: Boolean = false) {
        val sessionId = _selectedSessionId.value ?: return
        if (cols < 10 || rows < 4) return
        if (_connectionState.value !is ConnectionState.Connected) return

        val now = System.currentTimeMillis()
        val previous = lastRequestedResizeBySession[sessionId]
        val lastAt = lastResizeRequestAtBySession[sessionId] ?: 0L
        val sameSize = previous?.first == cols && previous.second == rows

        if (!force && sameSize) {
            return
        }
        if (!force && previous != null && now - lastAt < 350L) {
            val colsClose = kotlin.math.abs(previous.first - cols) <= 1
            val rowsClose = kotlin.math.abs(previous.second - rows) <= 1
            if (colsClose && rowsClose) {
                return
            }
        }

        dbg("RESIZE_REQ sid=${sessionId.take(8)} cols=$cols rows=$rows force=$force")
        lastRequestedResizeBySession[sessionId] = cols to rows
        lastResizeRequestAtBySession[sessionId] = now
        wssClient.requestResize(sessionId, cols, rows)
    }

    fun createSession(title: String = "Terminal", cols: Int = 80, rows: Int = 24) {
        wssClient.createSession(title, cols, rows)
    }

    fun requestRemoteSessionCreate(title: String? = null) {
        val desktopId = _pairedDesktopId.value.trim()
        if (desktopId.isBlank()) {
            _statusMessage.value = "先完成桌面配对"
            return
        }
        if (_connectionState.value !is ConnectionState.Connected) {
            _statusMessage.value = "请先连接服务器"
            return
        }
        _statusMessage.value = "已请求桌面新建终端…"
        wssClient.requestRemoteSessionCreate(desktopId, title)
        scheduleSessionListRetry(2500L)
    }

    fun requestRemoteSessionClose(sessionId: String) {
        if (sessionId.isBlank()) return
        if (_connectionState.value !is ConnectionState.Connected) {
            _statusMessage.value = "请先连接服务器"
            return
        }
        _statusMessage.value = "已请求桌面关闭终端…"
        wssClient.requestRemoteSessionClose(sessionId)
    }

    fun closeSession(sessionId: String) {
        wssClient.closeSession(sessionId)
        if (_selectedSessionId.value == sessionId) {
            _selectedSessionId.value = null
            _terminalOutput.value = ""
        }
    }

    fun refreshSessions() {
        if (_connectionState.value is ConnectionState.Connected) {
            _statusMessage.value = "正在刷新终端列表…"
        }
        wssClient.requestSessionList()
    }

    override fun onCleared() {
        super.onCleared()
        persistSessionOutputCache()
        wssClient.disconnect()
    }

    private fun saveConnectionSettings(url: String, token: String, name: String) {
        _serverUrl.value = url
        _deviceToken.value = token
        _deviceName.value = name
        prefs.edit()
            .putString(KEY_SERVER_URL, url)
            .putString(KEY_DEVICE_TOKEN, token)
            .putString(KEY_DEVICE_NAME, name)
            .apply()
    }

    private fun savePairingState(desktopId: String, desktopName: String) {
        _pairedDesktopId.value = desktopId
        _pairedDesktopName.value = desktopName
        _isPaired.value = desktopId.isNotBlank()
        prefs.edit()
            .putString(KEY_PAIRED_DESKTOP_ID, desktopId)
            .putString(KEY_PAIRED_DESKTOP_NAME, desktopName)
            .apply()
    }

    private fun clearPairingState() {
        _pairedDesktopId.value = ""
        _pairedDesktopName.value = ""
        _isPaired.value = false
        prefs.edit()
            .remove(KEY_PAIRED_DESKTOP_ID)
            .remove(KEY_PAIRED_DESKTOP_NAME)
            .apply()
        clearSessionOutputCache()
    }

    private fun subscribeForPreview(sessionId: String, force: Boolean = false) {
        if (sessionId.isBlank()) return
        if (!force && !observedSessionIds.add(sessionId)) return
        if (force) observedSessionIds.add(sessionId)
        wssClient.subscribeToSession(sessionId)
    }

    private fun extractPreview(data: String): String {
        val cleaned = data
            .replace(Regex("\\u001B\\[[0-9;?]*[ -/]*[@-~]"), " ")
            .replace(Regex("\\u001B[@-_]"), " ")
            .replace("\r", "\n")
            .lines()
            .asReversed()
            .map { it.trim() }
            .firstOrNull { it.isNotBlank() }
            .orEmpty()

        return cleaned.replace(Regex("\\s+"), " ").take(64)
    }

    private fun parseSessionSnapshot(
        snapshot: JSONObject,
        previous: TerminalSession?,
        fallbackSessionId: String
    ): TerminalSession {
        val now = System.currentTimeMillis()
        val preview = snapshot.optString("preview", previous?.preview.orEmpty()).orEmpty()
        val activity = snapshot.optString("activity", previous?.activity.orEmpty()).orEmpty()
        return TerminalSession(
            sessionId = snapshot.optString("session_id", fallbackSessionId),
            title = snapshot.optString("title", previous?.title ?: "Terminal"),
            cols = snapshot.optInt("cols", previous?.cols ?: 80),
            rows = snapshot.optInt("rows", previous?.rows ?: 24),
            status = snapshot.optString("status", previous?.status ?: "running"),
            isOwner = snapshot.optString("owner_id") == wssClient.deviceId,
            activity = activity,
            taskState = snapshot.optString("task_state", previous?.taskState.orEmpty()).orEmpty(),
            preview = preview,
            lastActivityAt = if (activity.isNotBlank() || preview.isNotBlank()) {
                previous?.lastActivityAt ?: now
            } else {
                previous?.lastActivityAt ?: 0L
            }
        )
    }

    private fun autoConnectIfPossible() {
        val url = _serverUrl.value.trim()
        val token = _deviceToken.value.trim()
        if (url.isBlank() || token.isBlank()) return
        manualDisconnect = false
        _connectionState.value = ConnectionState.Connecting
        _statusMessage.value = "正在恢复之前的连接…"
        wssClient.connect(url, token)
    }

    private fun scheduleReconnect(reason: String) {
        if (manualDisconnect) return
        val url = _serverUrl.value.trim()
        val token = _deviceToken.value.trim()
        if (url.isBlank() || token.isBlank()) return
        if (reconnectJob?.isActive == true) return

        reconnectAttempts += 1
        // Exponential backoff: 3s, 6s, 12s, 24s, 48s, capped at 60s
        val backoffMs = minOf(
            RECONNECT_DELAY_MS * (1L shl minOf(reconnectAttempts - 1, 5)),
            MAX_RECONNECT_DELAY_MS
        )
        _statusMessage.value = "$reason，${backoffMs / 1000} 秒后自动重连"
        reconnectJob = viewModelScope.launch {
            delay(backoffMs)
            reconnectJob = null
            if (manualDisconnect) return@launch
            _connectionState.value = ConnectionState.Connecting
            _statusMessage.value = "正在自动重连第 $reconnectAttempts 次…"
            wssClient.connect(url, token)
        }
    }

    private fun cancelReconnect() {
        reconnectJob?.cancel()
        reconnectJob = null
    }

    private fun scheduleSessionListRetry(delayMs: Long = 1500L) {
        if (_connectionState.value !is ConnectionState.Connected) return
        sessionListRetryJob?.cancel()
        sessionListRetryJob = viewModelScope.launch {
            delay(delayMs)
            if (_connectionState.value is ConnectionState.Connected && _sessions.value.isEmpty()) {
                wssClient.requestSessionList()
            }
            sessionListRetryJob = null
        }
    }

    private fun cancelSessionListRetry() {
        sessionListRetryJob?.cancel()
        sessionListRetryJob = null
    }

    private fun scheduleSessionOutputCacheSave() {
        outputCachePersistJob?.cancel()
        outputCachePersistJob = viewModelScope.launch {
            delay(400)
            writeSessionOutputCache()
            outputCachePersistJob = null
        }
    }

    private fun persistSessionOutputCache() {
        outputCachePersistJob?.cancel()
        outputCachePersistJob = null
        writeSessionOutputCache()
    }

    private fun writeSessionOutputCache() {
        val snapshot = JSONObject()
        sessionOutputCache.entries
            .sortedByDescending { it.value.length }
            .take(8)
            .forEach { (sessionId, output) ->
                if (output.isNotBlank()) {
                    snapshot.put(sessionId, trimReplay(output))
                }
            }
        prefs.edit().putString(KEY_SESSION_OUTPUT_CACHE, snapshot.toString()).apply()
    }

    private fun loadSessionOutputCache(): Map<String, String> {
        val raw = prefs.getString(KEY_SESSION_OUTPUT_CACHE, null).orEmpty()
        if (raw.isBlank()) return emptyMap()
        return try {
            val json = JSONObject(raw)
            buildMap {
                json.keys().forEach { key ->
                    val value = json.optString(key, "")
                    if (value.isNotBlank()) {
                        put(key, trimReplay(value))
                    }
                }
            }
        } catch (error: Exception) {
            Log.w(TAG, "Failed to restore session output cache", error)
            emptyMap()
        }
    }

    private fun clearSessionOutputCache() {
        sessionOutputCache.clear()
        sessionOutputVersion.clear()
        prefs.edit().remove(KEY_SESSION_OUTPUT_CACHE).apply()
    }

    private fun describeException(error: Throwable): String {
        val message = error.message?.trim().orEmpty()
        return if (message.isNotEmpty()) message else error.javaClass.simpleName
    }

    private fun dbg(msg: String) {
        val ts = java.text.SimpleDateFormat("HH:mm:ss.SSS", java.util.Locale.US)
            .format(java.util.Date())
        val line = "[$ts] $msg"
        Log.d(TAG, "DBG: $line")
        val current = _debugLog.value.toMutableList()
        current.add(line)
        // Keep last 80 lines
        if (current.size > 80) {
            _debugLog.value = current.takeLast(80)
        } else {
            _debugLog.value = current
        }
    }

    fun clearDebugLog() {
        _debugLog.value = emptyList()
        _debugOutputMsgCount = 0
        _debugOutputTotalBytes = 0L
        _debugReplayCount = 0
    }

    fun addDebugLine(msg: String) {
        dbg(msg)
    }

    private fun trimReplay(text: String): String {
        val maxLines = 1_000
        val maxLength = 400_000
        var start = 0
        var lineCount = 0
        for (index in text.length - 1 downTo 0) {
            if (text[index] == '\n') {
                lineCount += 1
                if (lineCount >= maxLines) {
                    start = index + 1
                    break
                }
            }
        }
        val byLines = if (start > 0) text.substring(start) else text
        return if (byLines.length <= maxLength) byLines else byLines.takeLast(maxLength)
    }

    private fun mergeReplayWithLive(replay: String, live: String): String {
        if (replay.isEmpty()) return live
        if (live.isEmpty()) return replay
        if (live.startsWith(replay)) return live
        if (replay.startsWith(live)) return replay

        val maxOverlap = minOf(replay.length, live.length)
        for (size in maxOverlap downTo 1) {
            if (replay.regionMatches(replay.length - size, live, 0, size, ignoreCase = false)) {
                return replay + live.substring(size)
            }
        }
        return replay + live
    }

    private fun nextSessionOutputVersion(sessionId: String): Long {
        val next = (sessionOutputVersion[sessionId] ?: 0L) + 1L
        sessionOutputVersion[sessionId] = next
        return next
    }

    private fun currentSessionOutputVersion(sessionId: String): Long {
        return sessionOutputVersion[sessionId] ?: 0L
    }
}
