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
import android.util.Base64

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
    val workspaceId: String = "",
    val title: String,
    val cols: Int,
    val rows: Int,
    val status: String,
    val isOwner: Boolean = false,
    val activity: String = "",
    val taskState: String = "",
    val preview: String = "",
    val screenPreview: String = "",
    val lastActivityAt: Long = 0L,
    val tabId: String = "",
    val tabTitle: String = "",
    val tabOrder: Int = Int.MAX_VALUE,
    val paneId: String = "",
    val paneTitle: String = "",
    val paneOrder: Int = Int.MAX_VALUE,
    val paneCount: Int = 1,
    val tabRoot: TerminalSplitNode? = null
)

data class TerminalSplitNode(
    val type: String,
    val paneId: String = "",
    val size: Float = 1f,
    val children: List<TerminalSplitNode> = emptyList()
)

data class TerminalDeltaBatch(
    val sessionId: String,
    val data: String,
    val version: Long,
    val encoding: String = "base64+vt"
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
        val version: Long,
        val encoding: String = "base64+vt"
    )

    private data class V3ScreenSubscription(
        val workspaceId: String,
        val paneId: String
    )

    private val prefs = application.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val apiClient = ApiClient()
    private val wssClient = WssClient()
    private val _connectionState = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    private val _sessions = MutableStateFlow<List<TerminalSession>>(emptyList())
    private val _selectedSessionId = MutableStateFlow<String?>(null)
    private val _terminalOutput = MutableStateFlow<String>("")
    private val _terminalOutputVersion = MutableStateFlow(0L)
    private val _terminalOutputEncoding = MutableStateFlow("base64+vt")
    // Raw v3 screen delta channel; UI batching keeps WebView updates bounded.
    private val _rawDeltaChannel = Channel<PendingTerminalDelta>(Channel.UNLIMITED)
    // Batched delta flow: merged every DELTA_BATCH_MS, consumed by WebView LaunchedEffect
    private val _terminalDelta = MutableSharedFlow<TerminalDeltaBatch>(extraBufferCapacity = 64)
    private val _debugLog = MutableStateFlow<List<String>>(emptyList())
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
    private val _terminalFontScale = MutableStateFlow(
        prefs.getFloat(KEY_TERMINAL_FONT_SCALE, 1.0f).coerceIn(0.7f, 1.6f)
    )
    private val sessionOutputCache = loadSessionOutputCache().toMutableMap()
    private val sessionCellsCache = mutableMapOf<String, String>()
    private val v3ScreenSeqByPane = mutableMapOf<String, Long>()
    private val v3ResyncRequestedAt = mutableMapOf<String, Long>()
    private val v3ScreenAckSeqByPane = mutableMapOf<String, Long>()
    private val v3ScreenAckSentAt = mutableMapOf<String, Long>()
    private val v3SubscribedScreens = mutableMapOf<String, V3ScreenSubscription>()
    private val commandCatalog = loadCommandCatalog().toMutableList()
    private val _commandLibrary = MutableStateFlow(buildCommandLibraryUiState(commandCatalog))
    private val _appUpdate = MutableStateFlow(AppUpdateUiState())
    private val sessionOutputVersion = mutableMapOf<String, Long>()
    private val sessionCellsVersion = mutableMapOf<String, Long>()
    private val lastRequestedResizeBySession = mutableMapOf<String, Pair<Int, Int>>()
    private val lastResizeRequestAtBySession = mutableMapOf<String, Long>()
    private var reconnectJob: Job? = null
    private var outputCachePersistJob: Job? = null
    private var sessionListRetryJob: Job? = null
    private var manualDisconnect = false
    private var appInForeground = true
    private var reconnectAttempts = 0

    companion object {
        private const val TAG = "MainViewModel"
        private const val PREFS_NAME = "termsync_prefs"
        private const val KEY_SERVER_URL = "server_url"
        private const val KEY_DEVICE_TOKEN = "device_token"
        private const val KEY_DEVICE_NAME = "device_name"
        private const val KEY_PAIRED_DESKTOP_ID = "paired_desktop_id"
        private const val KEY_PAIRED_DESKTOP_NAME = "paired_desktop_name"
        private const val KEY_TERMINAL_FONT_SCALE = "terminal_font_scale"
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
    val terminalOutputEncoding: StateFlow<String> = _terminalOutputEncoding.asStateFlow()
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
    val terminalFontScale: StateFlow<Float> = _terminalFontScale.asStateFlow()
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
                val batchByKey = linkedMapOf<String, StringBuilder>()
                val versionByKey = mutableMapOf<String, Long>()
                val sessionByKey = mutableMapOf<String, String>()
                val encodingByKey = mutableMapOf<String, String>()

                fun append(delta: PendingTerminalDelta) {
                    val key = "${delta.sessionId}\n${delta.encoding}"
                    val builder = batchByKey.getOrPut(key) { StringBuilder() }
                    if (delta.encoding == "base64+cells-json") {
                        builder.clear()
                    }
                    builder.append(delta.data)
                    versionByKey[key] = maxOf(versionByKey[key] ?: 0L, delta.version)
                    sessionByKey[key] = delta.sessionId
                    encodingByKey[key] = delta.encoding
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
                batchByKey.forEach { (key, builder) ->
                    val data = builder.toString()
                    if (data.isNotEmpty()) {
                        _terminalDelta.emit(
                            TerminalDeltaBatch(
                                sessionId = sessionByKey[key].orEmpty(),
                                data = data,
                                version = versionByKey[key] ?: 0L,
                                encoding = encodingByKey[key] ?: "base64+vt"
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
            "workspace.list_res" -> {
                val workspaces = msg.payload?.optJSONArray("workspaces")
                if (workspaces != null && workspaces.length() > 0) {
                    val workspaceId = workspaces.optJSONObject(0)?.optString("workspace_id").orEmpty()
                    if (workspaceId.isNotBlank()) {
                        wssClient.subscribeWorkspace(workspaceId)
                        _statusMessage.value = "已订阅远程工作区"
                    }
                } else {
                    _statusMessage.value = "已连接服务器，当前没有可用终端"
                    scheduleSessionListRetry()
                }
            }
            "layout.snapshot", "layout.patch" -> {
                val body = msg.payload ?: JSONObject()
                val snapshot = body.optJSONObject("snapshot") ?: body
                val sessions = parseV3LayoutSnapshot(msg.workspaceId.orEmpty(), snapshot)
                _sessions.value = sortSessionsForDisplay(sessions)
                ensureSelectedSessionAfterLayout(sessions)
                if (sessions.isEmpty()) {
                    _statusMessage.value = "已连接服务器，当前没有可用终端"
                    scheduleSessionListRetry()
                } else {
                    _statusMessage.value = ""
                    cancelSessionListRetry()
                }
            }
            "screen.snapshot", "screen.delta" -> {
                val paneId = msg.paneId.orEmpty()
                val session = _sessions.value.firstOrNull { it.paneId == paneId || it.sessionId == msg.sessionId }
                val sessionId = msg.sessionId ?: session?.sessionId ?: return
                val workspaceId = msg.workspaceId ?: session?.workspaceId.orEmpty()
                val seqKey = v3ScreenKey(workspaceId, paneId)
                if (msg.type == "screen.snapshot") {
                    val snapshotSeq = msg.payload?.optLong("snapshot_seq", 0L) ?: 0L
                    v3ScreenSeqByPane[seqKey] = snapshotSeq
                } else {
                    val seq = msg.payload?.optLong("seq", 0L) ?: 0L
                    val prevSeq = msg.payload?.optLong("prev_seq", 0L) ?: 0L
                    val lastSeq = v3ScreenSeqByPane[seqKey] ?: 0L
                    if (lastSeq > 0L && prevSeq != lastSeq) {
                        requestScreenResyncThrottled(workspaceId, paneId, lastSeq)
                        return
                    }
                    if (seq > 0L && seq <= lastSeq) return
                    if (seq > 0L) v3ScreenSeqByPane[seqKey] = seq
                }
                val encoded = msg.payload?.optString("data").orEmpty()
                if (encoded.isBlank()) return
                val data = runCatching {
                    String(Base64.decode(encoded, Base64.DEFAULT), Charsets.UTF_8)
                }.getOrDefault("")
                if (data.isBlank()) return
                val encoding = msg.payload?.optString("encoding").orEmpty().ifBlank { "base64+vt" }
                if (encoding == "base64+cells-json") {
                    val version = nextSessionOutputVersion(sessionId)
                    sessionCellsCache[sessionId] = data
                    sessionCellsVersion[sessionId] = version
                    if (msg.type == "screen.snapshot") {
                        val snapshotSeq = v3ScreenSeqByPane[seqKey] ?: 0L
                        if (snapshotSeq > 0L) ackScreenThrottled(workspaceId, paneId, snapshotSeq)
                    } else {
                        val seq = v3ScreenSeqByPane[seqKey] ?: 0L
                        if (seq > 0L) ackScreenThrottled(workspaceId, paneId, seq)
                    }
                    if (_selectedSessionId.value == sessionId) {
                        _terminalOutput.value = data
                        _terminalOutputVersion.value = version
                        _terminalOutputEncoding.value = encoding
                        _rawDeltaChannel.trySend(PendingTerminalDelta(sessionId, data, version, encoding))
                        _replayLoading.value = false
                        _terminalStreamStatus.value = "实时同步中"
                    }
                    return
                }
                if (msg.type == "screen.snapshot") {
                    sessionOutputCache[sessionId] = data
                    val snapshotSeq = v3ScreenSeqByPane[seqKey] ?: 0L
                    if (snapshotSeq > 0L) ackScreenThrottled(workspaceId, paneId, snapshotSeq)
                } else {
                    sessionOutputCache[sessionId] = trimReplay(sessionOutputCache[sessionId].orEmpty() + data)
                    val seq = v3ScreenSeqByPane[seqKey] ?: 0L
                    if (seq > 0L) ackScreenThrottled(workspaceId, paneId, seq)
                }
                val version = nextSessionOutputVersion(sessionId)
                scheduleSessionOutputCacheSave()
                if (_selectedSessionId.value == sessionId) {
                    _terminalOutput.value = sessionOutputCache[sessionId].orEmpty()
                    _terminalOutputVersion.value = version
                    _terminalOutputEncoding.value = encoding
                    _rawDeltaChannel.trySend(PendingTerminalDelta(sessionId, data, version, encoding))
                    _replayLoading.value = false
                    _terminalStreamStatus.value = "实时同步中"
                }
            }
            "connection.error" -> {
                val message = msg.payload?.optString("message", "Connection failed") ?: "Connection failed"
                _connectionState.value = ConnectionState.Error(message)
                v3SubscribedScreens.clear()
                _statusMessage.value = message
                cancelSessionListRetry()
                if (_selectedSessionId.value != null) {
                    _terminalStreamStatus.value = "实时连接异常，等待自动重连"
                }
                scheduleReconnect(message)
            }
            "connection.closed" -> {
                _connectionState.value = ConnectionState.Disconnected
                v3SubscribedScreens.clear()
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
        v3SubscribedScreens.clear()
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

    fun updateTerminalFontScale(value: Float) {
        val normalized = value.coerceIn(0.7f, 1.6f)
        _terminalFontScale.value = normalized
        prefs.edit().putFloat(KEY_TERMINAL_FONT_SCALE, normalized).apply()
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
        unsubscribeSelectedScreen()
        wssClient.disconnect()
        _connectionState.value = ConnectionState.Disconnected
        _sessions.value = emptyList()
        _selectedSessionId.value = null
        _terminalOutput.value = ""
        _terminalOutputVersion.value = 0L
        _terminalOutputEncoding.value = "base64+vt"
        _replayLoading.value = false
        _terminalStreamStatus.value = "已断开连接"
        _statusMessage.value = "已断开连接"
    }

    private var replayTimeoutJob: Job? = null

    fun onAppForeground() {
        appInForeground = true
        val sessionId = _selectedSessionId.value ?: return
        _sessions.value.firstOrNull { it.sessionId == sessionId }?.let { session ->
            syncVisibleScreenSubscriptions(session, forceResync = true)
            if (_terminalStreamStatus.value == "已暂停实时屏幕同步") {
                _terminalStreamStatus.value = "正在同步远程屏幕…"
            }
        }
    }

    fun onAppBackground() {
        appInForeground = false
        unsubscribeAllScreens()
        if (_selectedSessionId.value != null) {
            _terminalStreamStatus.value = "已暂停实时屏幕同步"
        }
    }

    fun selectSession(sessionId: String?) {
        if (sessionId.isNullOrBlank()) {
            dbg("SELECT_SESSION -> null (deselect)")
            unsubscribeAllScreens()
            _selectedSessionId.value = null
            _terminalOutput.value = ""
            _terminalOutputVersion.value = 0L
            _terminalOutputEncoding.value = "base64+vt"
            _replayLoading.value = false
            _terminalStreamStatus.value = "等待进入终端"
            replayTimeoutJob?.cancel()
            return
        }

        val previousSessionId = _selectedSessionId.value
        if (previousSessionId != sessionId) {
            unsubscribeScreensOutsideSelectedTab(sessionId)
        }
        val cachedLen = sessionOutputCache[sessionId].orEmpty().length
        dbg("SELECT_SESSION sid=${sessionId.take(8)} cache.len=$cachedLen")
        _selectedSessionId.value = sessionId
        val cachedOutput = sessionOutputCache[sessionId].orEmpty()
        val cachedCells = sessionCellsCache[sessionId].orEmpty()
        val hasCellsFrame = cachedCells.isNotBlank() && (sessionCellsVersion[sessionId] ?: 0L) > 0L
        _terminalOutput.value = if (hasCellsFrame) cachedCells else cachedOutput
        _terminalOutputVersion.value = ensureSessionOutputVersion(sessionId)
        _terminalOutputEncoding.value = if (hasCellsFrame) "base64+cells-json" else "base64+vt"
        dbg("SELECT_SESSION output.len=${_terminalOutput.value.length}")
        _replayLoading.value = !hasCellsFrame
        _terminalStreamStatus.value = if (hasCellsFrame) {
            "实时同步中"
        } else if (cachedOutput.isBlank()) {
            "正在同步远程屏幕…"
        } else {
            "正在同步远程屏幕…"
        }
        _sessions.value.firstOrNull { it.sessionId == sessionId }?.let { session ->
            syncVisibleScreenSubscriptions(session, forceResync = true)
        }
        
        // 添加超时处理，防止一直等待
        replayTimeoutJob?.cancel()
        replayTimeoutJob = viewModelScope.launch {
            delay(5000) // 5秒超时
            if (_selectedSessionId.value == sessionId && _replayLoading.value) {
                _replayLoading.value = false
                _terminalStreamStatus.value = if ((sessionCellsVersion[sessionId] ?: 0L) > 0L) {
                    "实时同步中"
                } else {
                    "仍在等待远程屏幕更新"
                }
            }
        }
    }

    fun refreshSelectedSessionReplay() {
        val sessionId = _selectedSessionId.value ?: return
        _replayLoading.value = true
        _terminalStreamStatus.value = "正在重新同步远程屏幕…"
        _sessions.value.firstOrNull { it.sessionId == sessionId }?.let { session ->
            syncVisibleScreenSubscriptions(session, forceResync = true)
        }
        
        // 添加超时处理
        replayTimeoutJob?.cancel()
        replayTimeoutJob = viewModelScope.launch {
            delay(5000) // 5秒超时
            if (_selectedSessionId.value == sessionId && _replayLoading.value) {
                _replayLoading.value = false
                _terminalStreamStatus.value = if ((sessionCellsVersion[sessionId] ?: 0L) > 0L) {
                    "实时同步中"
                } else {
                    "仍在等待远程屏幕更新"
                }
            }
        }
    }

    fun sendInput(input: String) {
        val sessionId = _selectedSessionId.value ?: return
        val session = _sessions.value.firstOrNull { it.sessionId == sessionId } ?: return
        if (session.workspaceId.isBlank() || session.paneId.isBlank()) return
        wssClient.sendTerminalInput(
            session.workspaceId,
            session.paneId,
            session.sessionId,
            input,
            "android:${System.currentTimeMillis()}:${input.length}"
        )
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
        val session = _sessions.value.firstOrNull { it.sessionId == sessionId } ?: return
        if (session.workspaceId.isBlank() || session.paneId.isBlank()) return
        wssClient.sendTerminalInput(
            session.workspaceId,
            session.paneId,
            session.sessionId,
            key.escapeSequence,
            "android:${System.currentTimeMillis()}:${key.name}"
        )
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
        val session = _sessions.value.firstOrNull { it.sessionId == sessionId }
        if (session == null || session.workspaceId.isBlank() || session.paneId.isBlank()) {
            _statusMessage.value = "缺少远程终端布局信息"
            return
        }
        _statusMessage.value = "已请求桌面关闭终端…"
        wssClient.requestRemoteSessionClose(session.workspaceId, session.paneId, session.sessionId)
    }

    fun closeSession(sessionId: String) {
        wssClient.closeSession(sessionId)
        if (_selectedSessionId.value == sessionId) {
            _selectedSessionId.value = null
            _terminalOutput.value = ""
            _terminalOutputEncoding.value = "base64+vt"
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
        unsubscribeSelectedScreen()
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

    private fun ensureSelectedSessionAfterLayout(sessions: List<TerminalSession>) {
        val selectedSessionId = _selectedSessionId.value
        if (selectedSessionId.isNullOrBlank()) return

        val selected = sessions.firstOrNull { it.sessionId == selectedSessionId }
        if (selected == null) {
            unsubscribeAllScreens()
            _selectedSessionId.value = null
            _terminalOutput.value = ""
            _terminalOutputVersion.value = 0L
            _terminalOutputEncoding.value = "base64+vt"
            _replayLoading.value = false
            _terminalStreamStatus.value = "当前终端已关闭"
            replayTimeoutJob?.cancel()
            return
        }

        syncVisibleScreenSubscriptions(selected)
    }

    private fun syncVisibleScreenSubscriptions(session: TerminalSession, forceResync: Boolean = false) {
        if (!appInForeground) return
        val visibleSessions = visibleSessionsForDetail(session)
        val desiredKeys = visibleSessions
            .filter { it.workspaceId.isNotBlank() && it.paneId.isNotBlank() }
            .associate { v3ScreenKey(it.workspaceId, it.paneId) to V3ScreenSubscription(it.workspaceId, it.paneId) }

        val staleKeys = v3SubscribedScreens.keys.filterNot { it in desiredKeys.keys }
        staleKeys.forEach { key ->
            v3SubscribedScreens.remove(key)?.let { subscription ->
                wssClient.unsubscribeScreen(subscription.workspaceId, subscription.paneId)
            }
        }

        desiredKeys.forEach { (key, subscription) ->
            if (!v3SubscribedScreens.containsKey(key)) {
                v3SubscribedScreens[key] = subscription
                wssClient.subscribeScreen(subscription.workspaceId, subscription.paneId)
                requestScreenResyncThrottled(subscription.workspaceId, subscription.paneId, 0L)
            } else if (forceResync) {
                val lastSeq = v3ScreenSeqByPane[key] ?: 0L
                requestScreenResyncThrottled(subscription.workspaceId, subscription.paneId, lastSeq)
            }
        }
    }

    private fun visibleSessionsForDetail(selected: TerminalSession): List<TerminalSession> {
        val allSessions = _sessions.value
        if (selected.tabId.isBlank()) return listOf(selected)
        return allSessions
            .filter { it.workspaceId == selected.workspaceId && it.tabId == selected.tabId }
            .ifEmpty { listOf(selected) }
    }

    private fun unsubscribeScreensOutsideSelectedTab(nextSessionId: String) {
        val nextSession = _sessions.value.firstOrNull { it.sessionId == nextSessionId }
        if (nextSession == null) {
            unsubscribeSelectedScreen()
            return
        }
        syncVisibleScreenSubscriptions(nextSession)
    }

    private fun unsubscribeSelectedScreen(sessionId: String? = _selectedSessionId.value) {
        val session = sessionId?.let { id -> _sessions.value.firstOrNull { it.sessionId == id } }
        if (session != null && session.workspaceId.isNotBlank() && session.paneId.isNotBlank()) {
            val key = v3ScreenKey(session.workspaceId, session.paneId)
            val subscription = v3SubscribedScreens.remove(key)
            if (subscription != null) {
                wssClient.unsubscribeScreen(subscription.workspaceId, subscription.paneId)
            }
            return
        }

        v3SubscribedScreens.values.forEach { subscription ->
            wssClient.unsubscribeScreen(subscription.workspaceId, subscription.paneId)
        }
        v3SubscribedScreens.clear()
    }

    private fun unsubscribeAllScreens() {
        v3SubscribedScreens.values.forEach { subscription ->
            wssClient.unsubscribeScreen(subscription.workspaceId, subscription.paneId)
        }
        v3SubscribedScreens.clear()
    }

    private fun v3ScreenKey(workspaceId: String, paneId: String): String {
        return "${workspaceId.length}:$workspaceId${paneId.length}:$paneId"
    }

    private fun requestScreenResyncThrottled(workspaceId: String, paneId: String, lastSeq: Long) {
        if (workspaceId.isBlank() || paneId.isBlank()) return
        val key = v3ScreenKey(workspaceId, paneId)
        val now = System.currentTimeMillis()
        val lastRequestedAt = v3ResyncRequestedAt[key] ?: 0L
        if (now - lastRequestedAt < 1000L) return
        v3ResyncRequestedAt[key] = now
        wssClient.requestScreenResync(workspaceId, paneId, lastSeq)
        _terminalStreamStatus.value = "正在重新同步屏幕"
    }

    private fun ackScreenThrottled(workspaceId: String, paneId: String, ackSeq: Long) {
        if (workspaceId.isBlank() || paneId.isBlank() || ackSeq <= 0L) return
        val key = v3ScreenKey(workspaceId, paneId)
        val lastAck = v3ScreenAckSeqByPane[key] ?: 0L
        if (ackSeq <= lastAck) return
        val now = System.currentTimeMillis()
        val lastSentAt = v3ScreenAckSentAt[key] ?: 0L
        v3ScreenAckSeqByPane[key] = ackSeq
        if (now - lastSentAt < 250L) return
        v3ScreenAckSentAt[key] = now
        wssClient.ackScreen(workspaceId, paneId, ackSeq)
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

    private fun parseV3LayoutSnapshot(workspaceIdFromMessage: String, snapshot: JSONObject): List<TerminalSession> {
        val workspaceId = workspaceIdFromMessage
            .ifBlank { snapshot.optString("workspace_id", "") }
            .ifBlank { _pairedDesktopId.value.trim().takeIf { it.isNotBlank() }?.let { "$it:default" }.orEmpty() }
        val ownerId = snapshot.optString("owner_device_id", _pairedDesktopId.value.trim())
        val tabs = snapshot.optJSONArray("tabs") ?: JSONArray()
        val previousById = _sessions.value.associateBy { it.sessionId }
        val result = mutableListOf<TerminalSession>()
        val now = System.currentTimeMillis()

        for (tabIndex in 0 until tabs.length()) {
            val tab = tabs.optJSONObject(tabIndex) ?: continue
            val tabId = tab.optString("tab_id", tab.optString("id", "tab-$tabIndex"))
            val tabTitle = tab.optString("title", "远程终端")
            val tabRoot = parseTerminalSplitNode(tab.optJSONObject("root"))
            val panes = tab.optJSONArray("panes") ?: JSONArray()
            for (paneIndex in 0 until panes.length()) {
                val pane = panes.optJSONObject(paneIndex) ?: continue
                val paneId = pane.optString("pane_id")
                if (paneId.isBlank()) continue
                val sessionId = pane.optString("session_id", "remote-$paneId")
                val previous = previousById[sessionId]
                val title = pane.optString("title", previous?.title ?: tabTitle)
                val activity = pane.optString("activity", previous?.activity.orEmpty())
                val preview = pane.optString("preview", previous?.preview.orEmpty())
                val screenPreview = pane.optString("screen_preview", previous?.screenPreview.orEmpty())
                val taskState = pane.optString("task_state", previous?.taskState.orEmpty())
                val changed = activity != previous?.activity ||
                    preview != previous?.preview ||
                    screenPreview != previous?.screenPreview ||
                    taskState != previous?.taskState
                result.add(
                    TerminalSession(
                        sessionId = sessionId,
                        workspaceId = workspaceId,
                        title = title,
                        cols = pane.optInt("cols", previous?.cols ?: 80),
                        rows = pane.optInt("rows", previous?.rows ?: 24),
                        status = pane.optString("status", previous?.status ?: "active"),
                        isOwner = ownerId == wssClient.deviceId,
                        activity = activity,
                        taskState = taskState,
                        preview = preview,
                        screenPreview = screenPreview,
                        lastActivityAt = if (changed) now else previous?.lastActivityAt ?: 0L,
                        tabId = tabId,
                        tabTitle = tabTitle,
                        tabOrder = tab.optInt("order", tabIndex),
                        paneId = paneId,
                        paneTitle = title,
                        paneOrder = pane.optInt("order", paneIndex),
                        paneCount = panes.length().coerceAtLeast(1),
                        tabRoot = tabRoot
                    )
                )
            }
        }
        return result
    }

    private fun parseTerminalSplitNode(node: JSONObject?): TerminalSplitNode? {
        if (node == null) return null
        val type = node.optString("type", "leaf").ifBlank { "leaf" }
        val size = node.optDouble("size", 1.0).toFloat().takeIf { it > 0f } ?: 1f
        if (type == "leaf") {
            val paneId = node.optString("pane_id", node.optString("paneId", ""))
            return if (paneId.isBlank()) null else TerminalSplitNode(
                type = "leaf",
                paneId = paneId,
                size = size
            )
        }
        val childrenJson = node.optJSONArray("children") ?: JSONArray()
        val children = mutableListOf<TerminalSplitNode>()
        for (index in 0 until childrenJson.length()) {
            parseTerminalSplitNode(childrenJson.optJSONObject(index))?.let { children.add(it) }
        }
        if (children.isEmpty()) return null
        return TerminalSplitNode(
            type = if (type == "vertical") "vertical" else "horizontal",
            size = size,
            children = children
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
        sessionCellsCache.clear()
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
        if (sessionOutputCache[sessionId].isNullOrEmpty() && sessionCellsCache[sessionId].isNullOrEmpty()) return 0L
        sessionOutputVersion[sessionId] = 1L
        return 1L
    }
}
