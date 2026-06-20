package com.termsync.mobile.viewmodel

import android.app.Application
import android.content.Context
import com.termsync.mobile.BuildConfig
import android.os.Environment
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.termsync.mobile.network.ApiClient
import com.termsync.mobile.network.AppUpdateInfo
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
import org.json.JSONArray
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
    val lastActivityAt: Long = 0L,
    val tabId: String = "",
    val tabTitle: String = "",
    val tabOrder: Int = Int.MAX_VALUE,
    val paneId: String = "",
    val paneTitle: String = "",
    val paneOrder: Int = Int.MAX_VALUE,
    val paneCount: Int = 1
)

data class TerminalDeltaBatch(
    val sessionId: String,
    val data: String,
    val version: Long
)

data class AppUpdateUiState(
    val currentVersionName: String = BuildConfig.VERSION_NAME,
    val checking: Boolean = false,
    val downloading: Boolean = false,
    val latest: AppUpdateInfo? = null,
    val downloadedFilePath: String = "",
    val message: String = ""
) {
    val hasUpdate: Boolean
        get() = latest?.available == true &&
            latest.versionName.isNotBlank() &&
            compareVersionNames(latest.versionName, currentVersionName) > 0 &&
            latest.downloadUrl.isNotBlank()
    val readyToInstall: Boolean
        get() = hasUpdate && downloadedFilePath.isNotBlank()
}

data class TerminalTabGroup(
    val tabId: String,
    val title: String,
    val order: Int,
    val sessions: List<TerminalSession>
)

private fun compareVersionNames(left: String, right: String): Int {
    val leftParts = left.versionParts()
    val rightParts = right.versionParts()
    val maxLen = maxOf(leftParts.size, rightParts.size)
    for (index in 0 until maxLen) {
        val l = leftParts.getOrElse(index) { 0 }
        val r = rightParts.getOrElse(index) { 0 }
        if (l != r) return l.compareTo(r)
    }
    return 0
}

private fun String.versionParts(): List<Int> {
    return trim()
        .trimStart('v', 'V')
        .split('.')
        .map { part -> part.takeWhile(Char::isDigit).toIntOrNull() ?: 0 }
}

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
    private val _serverUrl = MutableStateFlow(normalizeSavedServerUrl(prefs.getString(KEY_SERVER_URL, DEFAULT_SERVER_URL)))
    private val _deviceToken = MutableStateFlow(prefs.getString(KEY_DEVICE_TOKEN, "") ?: "")
    private val defaultDeviceName = resolveDefaultDeviceName(application)
    private val _deviceName = MutableStateFlow(
        prefs.getString(KEY_DEVICE_NAME, defaultDeviceName)
            ?.trim()
            ?.takeIf { it.isNotBlank() }
            ?: defaultDeviceName
    )
    private val _pairedDesktopId = MutableStateFlow(prefs.getString(KEY_PAIRED_DESKTOP_ID, "") ?: "")
    private val _pairedDesktopName = MutableStateFlow(prefs.getString(KEY_PAIRED_DESKTOP_NAME, "") ?: "")
    private val _isPaired = MutableStateFlow(_pairedDesktopId.value.isNotBlank())
    private val sessionOutputCache = loadSessionOutputCache().toMutableMap()
    private val commandCatalog = loadCommandCatalog().toMutableList()
    private val _commandLibrary = MutableStateFlow(buildCommandLibraryUiState(commandCatalog))
    private val _appUpdate = MutableStateFlow(AppUpdateUiState())
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
        private const val KEY_COMMAND_LIBRARY = "command_library"
        private const val DEFAULT_SERVER_URL = "wss://8.153.163.104:7373/ws"
        private const val LEGACY_DEFAULT_SERVER_URL = "wss://nas.smarthome2020.top:7373/ws"
        private const val RECONNECT_DELAY_MS = 3_000L
        private const val MAX_RECONNECT_DELAY_MS = 60_000L
        /** Batched delta flush interval in ms — controls max render rate (~20fps) */
        private const val DELTA_BATCH_MS = 50L

        private fun normalizeSavedServerUrl(value: String?): String {
            val normalized = value?.trim().orEmpty()
            return if (normalized.isBlank() || normalized == LEGACY_DEFAULT_SERVER_URL) {
                DEFAULT_SERVER_URL
            } else {
                normalized
            }
        }

        private fun resolveDefaultDeviceName(context: Context): String {
            val resolver = context.contentResolver
            val manufacturer = Build.MANUFACTURER.orEmpty().trim()
            val model = Build.MODEL.orEmpty().trim()
            val hardwareName = when {
                model.isBlank() -> manufacturer
                manufacturer.isBlank() -> model
                model.startsWith(manufacturer, ignoreCase = true) -> model
                else -> "$manufacturer $model"
            }.trim()

            return listOf(
                runCatching { Settings.Global.getString(resolver, Settings.Global.DEVICE_NAME) }.getOrNull(),
                runCatching { Settings.Secure.getString(resolver, "bluetooth_name") }.getOrNull(),
                hardwareName,
                "Android 手机"
            ).firstNotNullOf { candidate ->
                candidate?.trim()?.takeIf { it.isNotBlank() }
            }
        }
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
    val commandLibrary: StateFlow<CommandLibraryUiState> = _commandLibrary.asStateFlow()
    val appUpdate: StateFlow<AppUpdateUiState> = _appUpdate.asStateFlow()

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
        checkForAppUpdate(silent = true)
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
                        _sessions.value = sortSessionsForDisplay(sessionList)
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
                    _sessions.value = sortSessionsForDisplay(existing + session)
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
                            _terminalOutput.value = sessionOutputCache[msg.sessionId].orEmpty()
                            _terminalOutputVersion.value = version
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
                        _sessions.value = sortSessionsForDisplay(_sessions.value.map { session ->
                            if (session.sessionId == msg.sessionId) {
                                session.copy(
                                    activity = session.activity.ifBlank { preview },
                                    taskState = "running",
                                    preview = preview.ifBlank { session.preview },
                                    lastActivityAt = now
                                )
                            } else {
                                session
                            }
                        })
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
                        val version = nextSessionOutputVersion(sessionId)
                        scheduleSessionOutputCacheSave()
                        if (_selectedSessionId.value == sessionId) {
                            _terminalOutput.value = sessionOutputCache[sessionId].orEmpty()
                            _terminalOutputVersion.value = version
                            _replayLoading.value = false
                            _terminalStreamStatus.value = if (data.isNotBlank()) "正在接收桌面端回放" else "桌面端暂无可回放内容"
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
        val normalizedUrl = url.trim()
        val normalizedToken = token.trim()
        if (normalizedUrl.isBlank()) {
            _statusMessage.value = "请先填写服务器地址"
            return
        }
        if (normalizedToken.isBlank()) {
            viewModelScope.launch {
                try {
                    val readyToken = ensureMobileToken(normalizedUrl)
                    connectWithToken(normalizedUrl, readyToken)
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to prepare mobile device before connect", e)
                    _statusMessage.value = "准备手机身份失败: ${describeException(e)}"
                }
            }
            return
        }
        connectWithToken(normalizedUrl, normalizedToken)
    }

    private fun connectWithToken(url: String, token: String) {
        manualDisconnect = false
        cancelReconnect()
        _connectionState.value = ConnectionState.Connecting
        _statusMessage.value = "正在连接桌面终端服务…"
        saveConnectionSettings(url, token, _deviceName.value)
        wssClient.connect(url, token)
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

    fun checkForAppUpdate(silent: Boolean = false) {
        val url = _serverUrl.value.trim()
        if (url.isBlank()) {
            _appUpdate.value = _appUpdate.value.copy(message = "请先填写服务器地址")
            return
        }
        if (_appUpdate.value.checking) return

        _appUpdate.value = _appUpdate.value.copy(
            checking = true,
            message = if (silent) "" else "正在检查新版本…"
        )
        viewModelScope.launch {
            try {
                val latest = withContext(Dispatchers.IO) {
                    apiClient.getLatestAndroidRelease(url, BuildConfig.UPDATE_BUILD_TYPE)
                }
                val next = AppUpdateUiState(
                    checking = false,
                    latest = latest,
                    message = when {
                        latest.available && compareVersionNames(latest.versionName, BuildConfig.VERSION_NAME) > 0 -> {
                            "发现 ${BuildConfig.UPDATE_BUILD_TYPE} 新版本 ${latest.versionName}"
                        }
                        latest.available -> "当前已是最新版本"
                        else -> "服务器暂无 Android ${BuildConfig.UPDATE_BUILD_TYPE} 安装包"
                    }
                )
                _appUpdate.value = next
                if (next.hasUpdate && silent) {
                    _statusMessage.value = next.message
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to check Android update", e)
                _appUpdate.value = _appUpdate.value.copy(
                    checking = false,
                    message = if (silent) "" else "检查更新失败: ${describeException(e)}"
                )
            }
        }
    }

    fun downloadAppUpdate() {
        val update = _appUpdate.value
        val latest = update.latest ?: return
        if (!update.hasUpdate || latest.downloadUrl.isBlank()) return
        if (update.downloading) return

        _appUpdate.value = update.copy(
            downloading = true,
            downloadedFilePath = "",
            message = "正在下载 ${BuildConfig.UPDATE_BUILD_TYPE} ${latest.versionName}…"
        )
        viewModelScope.launch {
            try {
                val file = withContext(Dispatchers.IO) {
                    val context = getApplication<Application>()
                    val dir = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                        ?.resolve("updates")
                        ?: context.filesDir.resolve("updates")
                    val safeName = latest.fileName.ifBlank {
                        "termsync-android-${BuildConfig.UPDATE_BUILD_TYPE}-${latest.versionName}.apk"
                    }
                    val target = dir.resolve(safeName)
                    apiClient.downloadFile(latest.downloadUrl, target)
                    target
                }
                _appUpdate.value = _appUpdate.value.copy(
                    downloading = false,
                    downloadedFilePath = file.absolutePath,
                    message = "下载完成，点击安装"
                )
            } catch (e: Exception) {
                Log.e(TAG, "Failed to download Android update", e)
                _appUpdate.value = _appUpdate.value.copy(
                    downloading = false,
                    message = "下载失败: ${describeException(e)}"
                )
            }
        }
    }

    fun registerMobileDevice() {
        val url = _serverUrl.value.trim()
        if (url.isBlank()) {
            _statusMessage.value = "请先填写服务器地址"
            return
        }

        viewModelScope.launch {
            try {
                ensureMobileToken(url, forceRefresh = true)
                clearPairingState()
                _statusMessage.value = "手机身份已准备好"
            } catch (e: Exception) {
                Log.e(TAG, "Failed to register mobile device", e)
                _statusMessage.value = "准备手机身份失败: ${describeException(e)}"
            }
        }
    }

    fun completePairing(code: String) {
        val url = _serverUrl.value.trim()
        val normalizedCode = code.filter(Char::isDigit).take(6)
        if (url.isBlank()) {
            _statusMessage.value = "请先填写服务器地址"
            return
        }
        if (normalizedCode.length != 6) {
            _statusMessage.value = "请输入桌面端生成的 6 位配对码"
            return
        }

        viewModelScope.launch {
            try {
                val token = ensureMobileToken(url)
                val result = withContext(Dispatchers.IO) {
                    apiClient.completePairing(url, token, normalizedCode)
                }
                savePairingState(result.desktopId, result.desktopName)
                if (_connectionState.value is ConnectionState.Connected) {
                    _statusMessage.value = "已绑定桌面: ${result.desktopName}"
                    wssClient.requestSessionList()
                } else {
                    _statusMessage.value = "已绑定桌面: ${result.desktopName}，正在连接…"
                    connectWithToken(url, token)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to complete pairing", e)
                _statusMessage.value = "配对失败: ${describeException(e)}"
            }
        }
    }

    private suspend fun ensureMobileToken(url: String, forceRefresh: Boolean = false): String {
        val normalizedUrl = url.trim()
        if (normalizedUrl.isBlank()) {
            throw IllegalArgumentException("服务器地址为空")
        }
        val existingToken = _deviceToken.value.trim()
        if (existingToken.isNotBlank() && !forceRefresh) {
            saveConnectionSettings(normalizedUrl, existingToken, normalizedDeviceName())
            return existingToken
        }

        _statusMessage.value = if (forceRefresh) "正在重新生成手机身份…" else "正在准备手机身份…"
        val device = withContext(Dispatchers.IO) {
            apiClient.registerDevice(normalizedUrl, normalizedDeviceName(), "mobile")
        }
        saveConnectionSettings(normalizedUrl, device.token, device.name)
        return device.token
    }

    private fun normalizedDeviceName(): String {
        val name = _deviceName.value.trim().ifBlank { defaultDeviceName }
        _deviceName.value = name
        return name
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
        _terminalOutputVersion.value = ensureSessionOutputVersion(sessionId)
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

    fun submitCommand(command: String) {
        val normalized = normalizeCommandShortcutValue(command)
        if (normalized.isBlank()) return
        recordCommandUsage(normalized)
        sendInput("$normalized\r")
    }

    fun toggleFavoriteCommand(command: String) {
        val normalized = normalizeCommandShortcutValue(command)
        if (normalized.isBlank()) return
        val index = findCommandIndexByValue(normalized)
        if (index >= 0) {
            val existing = commandCatalog[index]
            commandCatalog[index] = existing.copy(isFavorite = !existing.isFavorite)
        } else {
            commandCatalog.add(
                createCustomCommandShortcut(
                    command = normalized,
                    favorite = true
                )
            )
        }
        publishCommandLibrary()
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
        val taskState = snapshot.optString("task_state", previous?.taskState.orEmpty()).orEmpty()
        val layout = snapshot.optJSONObject("layout")
        val previousActivityAt = previous?.lastActivityAt ?: 0L
        val activityChanged = activity != previous?.activity || preview != previous?.preview || taskState != previous?.taskState
        val sessionId = snapshot.optString("session_id", fallbackSessionId)
        val paneTitle = layout?.optString("pane_title")?.takeIf { it.isNotBlank() }
            ?: snapshot.optString("title", previous?.title ?: "Terminal")
        return TerminalSession(
            sessionId = sessionId,
            title = paneTitle,
            cols = snapshot.optInt("cols", previous?.cols ?: 80),
            rows = snapshot.optInt("rows", previous?.rows ?: 24),
            status = snapshot.optString("status", previous?.status ?: "running"),
            isOwner = snapshot.optString("owner_id") == wssClient.deviceId,
            activity = activity,
            taskState = taskState,
            preview = preview,
            lastActivityAt = if (activity.isNotBlank() || preview.isNotBlank() || taskState.isNotBlank()) {
                if (previousActivityAt == 0L || activityChanged || taskState == "running" || taskState == "waiting_input") now else previousActivityAt
            } else {
                previousActivityAt
            },
            tabId = layout?.optString("tab_id")?.takeIf { it.isNotBlank() } ?: previous?.tabId.orEmpty(),
            tabTitle = layout?.optString("tab_title")?.takeIf { it.isNotBlank() } ?: previous?.tabTitle.orEmpty(),
            tabOrder = layout?.optInt("tab_order", previous?.tabOrder ?: Int.MAX_VALUE) ?: (previous?.tabOrder ?: Int.MAX_VALUE),
            paneId = layout?.optString("pane_id")?.takeIf { it.isNotBlank() } ?: previous?.paneId.orEmpty(),
            paneTitle = paneTitle,
            paneOrder = layout?.optInt("pane_order", previous?.paneOrder ?: Int.MAX_VALUE) ?: (previous?.paneOrder ?: Int.MAX_VALUE),
            paneCount = layout?.optInt("pane_count", previous?.paneCount ?: 1)?.coerceAtLeast(1) ?: (previous?.paneCount ?: 1)
        )
    }

    private fun sortSessionsForDisplay(sessions: List<TerminalSession>): List<TerminalSession> {
        fun activeRank(session: TerminalSession): Int {
            return when (session.taskState) {
                "running", "waiting_input" -> 0
                else -> 1
            }
        }

        return sessions.sortedWith(
            compareBy<TerminalSession> { activeRank(it) }
                .thenByDescending { it.lastActivityAt }
                .thenBy { it.title.lowercase() }
                .thenBy { it.sessionId }
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

    private fun recordCommandUsage(command: String) {
        val normalized = normalizeCommandShortcutValue(command)
        if (normalized.isBlank()) return
        val now = System.currentTimeMillis()
        val index = findCommandIndexByValue(normalized)
        if (index >= 0) {
            val existing = commandCatalog[index]
            commandCatalog[index] = existing.copy(
                useCount = existing.useCount + 1,
                lastUsedAt = now
            )
        } else {
            commandCatalog.add(
                createCustomCommandShortcut(
                    command = normalized,
                    useCount = 1,
                    lastUsedAt = now,
                    createdAt = now
                )
            )
        }
        publishCommandLibrary()
    }

    private fun findCommandIndexByValue(command: String): Int {
        return commandCatalog.indexOfFirst { it.command == command }
    }

    private fun publishCommandLibrary() {
        _commandLibrary.value = buildCommandLibraryUiState(commandCatalog)
        persistCommandCatalog()
    }

    private fun persistCommandCatalog() {
        val payload = JSONArray()
        commandCatalog
            .filter { !it.builtIn || it.isFavorite || it.useCount > 0 || it.lastUsedAt > 0L }
            .sortedBy { it.id }
            .forEach { command ->
                payload.put(
                    JSONObject().apply {
                        put("id", command.id)
                        put("title", command.title)
                        put("command", command.command)
                        put("category", command.category.key)
                        put("dangerous", command.dangerous)
                        put("builtIn", command.builtIn)
                        put("favorite", command.isFavorite)
                        put("useCount", command.useCount)
                        put("lastUsedAt", command.lastUsedAt)
                        put("createdAt", command.createdAt)
                        put("defaultRank", command.defaultRank)
                    }
                )
            }
        prefs.edit().putString(KEY_COMMAND_LIBRARY, payload.toString()).apply()
    }

    private fun loadCommandCatalog(): List<CommandShortcut> {
        val defaults = defaultCommandShortcuts()
        val mergedById = defaults.associateBy { it.id }.toMutableMap()
        val customCommands = mutableListOf<CommandShortcut>()
        val raw = prefs.getString(KEY_COMMAND_LIBRARY, null).orEmpty()
        if (raw.isBlank()) {
            return defaults
        }

        return try {
            val payload = JSONArray(raw)
            for (i in 0 until payload.length()) {
                val obj = payload.optJSONObject(i) ?: continue
                val command = normalizeCommandShortcutValue(obj.optString("command", ""))
                if (command.isBlank()) continue
                val id = obj.optString("id").ifBlank { customCommandIdFor(command) }
                val builtIn = obj.optBoolean("builtIn", false)
                val existing = mergedById[id]
                if (existing != null) {
                    mergedById[id] = existing.copy(
                        isFavorite = obj.optBoolean("favorite", existing.isFavorite),
                        useCount = obj.optInt("useCount", existing.useCount),
                        lastUsedAt = obj.optLong("lastUsedAt", existing.lastUsedAt),
                        createdAt = obj.optLong("createdAt", existing.createdAt)
                    )
                } else {
                    customCommands.add(
                        CommandShortcut(
                            id = id,
                            title = obj.optString("title", deriveCommandTitle(command)),
                            command = command,
                            category = CommandCategory.fromKey(obj.optString("category", CommandCategory.Custom.key)),
                            dangerous = obj.optBoolean("dangerous", false),
                            builtIn = builtIn,
                            isFavorite = obj.optBoolean("favorite", false),
                            useCount = obj.optInt("useCount", 0),
                            lastUsedAt = obj.optLong("lastUsedAt", 0L),
                            createdAt = obj.optLong("createdAt", System.currentTimeMillis()),
                            defaultRank = obj.optInt("defaultRank", 20)
                        )
                    )
                }
            }
            defaults.map { mergedById[it.id] ?: it } + customCommands.distinctBy { it.command }
        } catch (error: Exception) {
            Log.w(TAG, "Failed to restore command catalog", error)
            defaults
        }
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
        val maxLines = 5_000
        val maxLength = 1_500_000
        val normalized = collapseCarriageReturnFrames(text)
        var start = 0
        var lineCount = 0
        for (index in normalized.length - 1 downTo 0) {
            if (normalized[index] == '\n') {
                lineCount += 1
                if (lineCount >= maxLines) {
                    start = index + 1
                    break
                }
            }
        }
        val byLines = if (start > 0) normalized.substring(start) else normalized
        return if (byLines.length <= maxLength) byLines else byLines.takeLast(maxLength)
    }

    private fun collapseCarriageReturnFrames(text: String): String {
        if (text.indexOf('\r') < 0) return text
        val lines = mutableListOf<String>()
        var line = StringBuilder()
        var overlay = StringBuilder()
        var overlayMode = false
        var index = 0

        fun applyOverlay() {
            if (!overlayMode) return
            val replacement = overlay.toString()
            val existing = line.toString()
            line = StringBuilder(replacement + existing.drop(replacement.length))
            overlay = StringBuilder()
            overlayMode = false
        }

        while (index < text.length) {
            val ch = text[index]
            when (ch) {
                '\r' -> {
                    if (index + 1 < text.length && text[index + 1] == '\n') {
                        applyOverlay()
                        lines.add(line.toString())
                        line = StringBuilder()
                        index += 1
                    } else {
                        overlayMode = true
                        overlay = StringBuilder()
                    }
                }
                '\n' -> {
                    applyOverlay()
                    lines.add(line.toString())
                    line = StringBuilder()
                }
                else -> {
                    if (overlayMode) overlay.append(ch) else line.append(ch)
                }
            }
            index += 1
        }
        applyOverlay()
        lines.add(line.toString())
        return lines.joinToString("\n")
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

    private fun ensureSessionOutputVersion(sessionId: String): Long {
        val current = currentSessionOutputVersion(sessionId)
        if (current > 0L) return current
        if (sessionOutputCache[sessionId].isNullOrEmpty()) return 0L
        sessionOutputVersion[sessionId] = 1L
        return 1L
    }
}
