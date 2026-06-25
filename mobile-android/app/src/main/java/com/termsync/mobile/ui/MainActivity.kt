package com.termsync.mobile.ui

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.webkit.ConsoleMessage
import android.webkit.WebChromeClient
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.webkit.JavascriptInterface
import android.view.ViewGroup
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.core.content.FileProvider
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import java.io.File
import com.termsync.mobile.viewmodel.TerminalSession
import com.termsync.mobile.viewmodel.TerminalSplitNode
import com.termsync.mobile.viewmodel.TerminalDeltaBatch
import com.termsync.mobile.viewmodel.TerminalTabGroup
import com.termsync.mobile.viewmodel.ConnectionState
import com.termsync.mobile.viewmodel.CommandLibraryUiState
import com.termsync.mobile.viewmodel.CommandShortcut
import com.termsync.mobile.viewmodel.MainViewModel
import com.termsync.mobile.viewmodel.SpecialKey
import com.termsync.mobile.viewmodel.AppUpdateUiState
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalContext

private const val DEFAULT_SERVER_URL = "wss://8.153.163.104:7373/ws"

private enum class CommandPanelSection(val key: String, val label: String) {
    Favorites("favorites", "收藏"),
    Recent("recent", "最近");
}

private val PRIMARY_SPECIAL_KEYS = listOf(
    "ESC" to SpecialKey.Escape,
    "TAB" to SpecialKey.Tab,
    "↑" to SpecialKey.ArrowUp,
    "↓" to SpecialKey.ArrowDown,
    "Ctrl+C" to SpecialKey.CtrlC,
    "Ctrl+D" to SpecialKey.CtrlD
)
private val ALL_SPECIAL_KEYS = PRIMARY_SPECIAL_KEYS + listOf(
    "←" to SpecialKey.ArrowLeft,
    "→" to SpecialKey.ArrowRight,
    "Ctrl+Z" to SpecialKey.CtrlZ,
    "PgUp" to SpecialKey.PageUp,
    "PgDn" to SpecialKey.PageDown,
    "Home" to SpecialKey.Home,
    "End" to SpecialKey.End
)

private data class CodexQuickPrompt(
    val label: String,
    val prompt: String
)

private val CODEX_QUICK_PROMPTS = listOf(
    CodexQuickPrompt("继续", "继续当前任务，完成后简要汇报结果。"),
    CodexQuickPrompt("测试", "运行相关测试，优先汇报失败点和需要我决策的地方。"),
    CodexQuickPrompt("总结", "总结当前进展、已改文件、验证结果和下一步建议。"),
    CodexQuickPrompt("修复失败", "根据刚才的错误继续修复，先定位原因，再做最小改动。"),
    CodexQuickPrompt("等我确认", "先停在需要确认的地方，列出选项和推荐方案。")
)

private enum class ComposerQuickActionKind {
    ContinuePrompt,
    CommandLibrary,
    Favorite,
    TerminalSubmit,
    Escape,
    CtrlC,
    Tab,
    ArrowUp,
    ArrowDown
}

private data class ComposerQuickActionSpec(
    val kind: ComposerQuickActionKind,
    val label: String,
    val defaultRank: Int
)

private data class ComposerQuickActionUsage(
    val count: Int = 0,
    val lastUsedOrder: Int = 0
)

private val COMPOSER_QUICK_ACTIONS = listOf(
    ComposerQuickActionSpec(ComposerQuickActionKind.ContinuePrompt, "继续", 100),
    ComposerQuickActionSpec(ComposerQuickActionKind.Escape, "ESC", 92),
    ComposerQuickActionSpec(ComposerQuickActionKind.CtrlC, "Ctrl+C", 90),
    ComposerQuickActionSpec(ComposerQuickActionKind.Tab, "TAB", 88),
    ComposerQuickActionSpec(ComposerQuickActionKind.ArrowUp, "↑", 86),
    ComposerQuickActionSpec(ComposerQuickActionKind.ArrowDown, "↓", 84),
    ComposerQuickActionSpec(ComposerQuickActionKind.CommandLibrary, "命令库", 70),
    ComposerQuickActionSpec(ComposerQuickActionKind.Favorite, "收藏", 56),
    ComposerQuickActionSpec(ComposerQuickActionKind.TerminalSubmit, "发到终端", 52)
)

/**
 * Main Activity for TTY1 mobile app
 * Shows terminal list and terminal view
 */
class MainActivity : ComponentActivity() {
    private val viewModel: MainViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        setContent {
            MaterialTheme(
                colorScheme = darkColorScheme()
            ) {
                TTY1App(viewModel)
            }
        }
    }

    override fun onStart() {
        super.onStart()
        viewModel.onAppForeground()
    }

    override fun onStop() {
        viewModel.onAppBackground()
        super.onStop()
    }
}

@Composable
fun TTY1App(viewModel: MainViewModel) {
    var showConnectionDialog by remember { mutableStateOf(false) }
    val connectionState by viewModel.connectionState.collectAsState()
    val sessions by viewModel.sessions.collectAsState()
    val selectedSessionId by viewModel.selectedSessionId.collectAsState()
    val terminalOutput by viewModel.terminalOutput.collectAsState()
    val terminalOutputVersion by viewModel.terminalOutputVersion.collectAsState()
    val terminalOutputEncoding by viewModel.terminalOutputEncoding.collectAsState()
    val statusMessage by viewModel.statusMessage.collectAsState()
    val replayLoading by viewModel.replayLoading.collectAsState()
    val terminalStreamStatus by viewModel.terminalStreamStatus.collectAsState()
    val serverUrl by viewModel.serverUrl.collectAsState()
    val deviceToken by viewModel.deviceToken.collectAsState()
    val deviceName by viewModel.deviceName.collectAsState()
    val isPaired by viewModel.isPaired.collectAsState()
    val pairedDesktopName by viewModel.pairedDesktopName.collectAsState()
    val terminalFontScale by viewModel.terminalFontScale.collectAsState()
    val commandLibrary by viewModel.commandLibrary.collectAsState()
    val appUpdate by viewModel.appUpdate.collectAsState()
    val selectedSession = sessions.firstOrNull { it.sessionId == selectedSessionId }
    val tabGroups = remember(sessions) { buildTerminalTabGroups(sessions) }
    val selectedTabSessions = remember(sessions, selectedSession) {
        if (selectedSession == null) {
            emptyList()
        } else if (selectedSession.tabId.isNotBlank()) {
            sessions
                .filter { it.tabId == selectedSession.tabId }
                .sortedWith(
                    compareBy<TerminalSession> { normalizedOrder(it.paneOrder) }
                        .thenBy { it.title.lowercase() }
                        .thenBy { it.sessionId }
                )
        } else {
            listOf(selectedSession)
        }
    }
    val hasToken = deviceToken.isNotBlank()
    val canRequestRemoteTerminal = connectionState is ConnectionState.Connected && isPaired
    val activeSessionCount = sessions.count { it.taskState == "running" || it.taskState == "waiting_input" }

    BackHandler(enabled = selectedSessionId != null) {
        viewModel.selectSession(null)
    }

    LaunchedEffect(hasToken) {
        if (!hasToken) {
            showConnectionDialog = true
        }
    }
    
    Scaffold(
        topBar = {
            if (selectedSessionId == null) {
                CompactHomeTopBar(
                    sessionCount = sessions.size,
                    activeSessionCount = activeSessionCount,
                    connectionState = connectionState,
                    canCreateTerminal = canRequestRemoteTerminal,
                    onCreateTerminal = { viewModel.requestRemoteSessionCreate() },
                    onRefresh = { viewModel.refreshSessions() },
                    onOpenSettings = { showConnectionDialog = true }
                )
            }
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            when {
                selectedSessionId != null -> {
                    TerminalViewScreen(
                        connectionState = connectionState,
                        session = selectedSession,
                        sameTabSessions = selectedTabSessions,
                        output = terminalOutput,
                        outputVersion = terminalOutputVersion,
                        outputEncoding = terminalOutputEncoding,
                        terminalDelta = viewModel.terminalDelta,
                        replayLoading = replayLoading,
                        terminalStreamStatus = terminalStreamStatus,
                        terminalFontScale = terminalFontScale,
                        commandLibrary = commandLibrary,
                        onSubmitCommand = { viewModel.submitCommand(it) },
                        onSendRawInput = { viewModel.sendInput(it) },
                        onToggleFavoriteCommand = { viewModel.toggleFavoriteCommand(it) },
                        onSendSpecialKey = { viewModel.sendSpecialKey(it) },
                        onRefreshTerminal = { viewModel.refreshSelectedSessionReplay() },
                        onTerminalFontScaleChange = { viewModel.updateTerminalFontScale(it) },
                        onRequestCloseSession = { viewModel.requestRemoteSessionClose(it) },
                        onTerminalResize = { cols, rows, force -> viewModel.requestSelectedSessionResize(cols, rows, force) },
                        onSessionSelected = { viewModel.selectSession(it) },
                        onDebug = { msg -> viewModel.addDebugLine(msg) },
                        onClose = { viewModel.selectSession(null) }
                    )
                }

                else -> {
                    HomeScreen(
                        connectionState = connectionState,
                        sessions = sessions,
                        tabGroups = tabGroups,
                        serverUrl = serverUrl,
                        deviceName = deviceName,
                        hasToken = hasToken,
                        isPaired = isPaired,
                        pairedDesktopName = pairedDesktopName,
                        statusMessage = statusMessage,
                        onOpenSettings = { showConnectionDialog = true },
                        onConnect = {
                            viewModel.connect(serverUrl, deviceToken)
                        },
                        onDisconnect = { viewModel.disconnect() },
                        onRefresh = { viewModel.refreshSessions() },
                        onSessionSelected = { viewModel.selectSession(it) }
                    )
                }
            }
        }
    }
    
    // Connection dialog
    if (showConnectionDialog) {
        ConnectionDialog(
            onDismiss = { showConnectionDialog = false },
            serverUrl = serverUrl,
            deviceToken = deviceToken,
            deviceName = deviceName,
            statusMessage = statusMessage,
            appUpdate = appUpdate,
            onServerUrlChange = viewModel::updateServerUrl,
            onDeviceTokenChange = viewModel::updateDeviceToken,
            onDeviceNameChange = viewModel::updateDeviceName,
            onCheckUpdate = { viewModel.checkForAppUpdate(silent = false) },
            onDownloadUpdate = { viewModel.downloadAppUpdate() },
            onRegister = { viewModel.registerMobileDevice() },
            onPair = { code -> viewModel.completePairing(code) },
            onConnect = {
                viewModel.connect(serverUrl, deviceToken)
                showConnectionDialog = false
            }
        )
    }
}

@Composable
fun CompactHomeTopBar(
    sessionCount: Int,
    activeSessionCount: Int,
    connectionState: ConnectionState,
    canCreateTerminal: Boolean,
    onCreateTerminal: () -> Unit,
    onRefresh: () -> Unit,
    onOpenSettings: () -> Unit
) {
    val (connectionLabel, connectionColor) = connectionStateVisual(connectionState)
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(1.dp)
            ) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(7.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = "TermSync",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold
                    )
                    Box(
                        modifier = Modifier
                            .size(7.dp)
                            .background(connectionColor, RoundedCornerShape(999.dp))
                    )
                    Text(
                        text = connectionLabel,
                        style = MaterialTheme.typography.labelSmall,
                        color = connectionColor,
                        maxLines = 1
                    )
                }
                Text(
                    text = if (activeSessionCount > 0) {
                        "$activeSessionCount 活跃 · $sessionCount 总计"
                    } else {
                        "$sessionCount 个终端"
                    },
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                IconButton(
                    onClick = onCreateTerminal,
                    enabled = canCreateTerminal,
                    modifier = Modifier.size(40.dp)
                ) {
                    Icon(Icons.Default.Add, contentDescription = "新建终端", modifier = Modifier.size(18.dp))
                }
                IconButton(onClick = onRefresh, modifier = Modifier.size(40.dp)) {
                    Icon(Icons.Default.Refresh, contentDescription = "刷新", modifier = Modifier.size(18.dp))
                }
                IconButton(onClick = onOpenSettings, modifier = Modifier.size(40.dp)) {
                    Icon(Icons.Default.Settings, contentDescription = "设置", modifier = Modifier.size(18.dp))
                }
            }
        }
    }
}

private fun connectionStateVisual(state: ConnectionState): Pair<String, Color> {
    return when (state) {
        is ConnectionState.Disconnected -> "离线" to Color(0xFFFF7A7A)
        is ConnectionState.Connecting -> "连接中" to Color(0xFFFFC857)
        is ConnectionState.Connected -> "已连接" to Color(0xFF59D499)
        is ConnectionState.Error -> "异常" to Color(0xFFFF7A7A)
    }
}

@Composable
fun ConnectionStatusBar(state: ConnectionState) {
    val (text, color) = connectionStateVisual(state)
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = color.copy(alpha = 0.12f)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 5.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(7.dp)
                    .background(color, RoundedCornerShape(999.dp))
            )
            Text(
                text = text,
                fontSize = 11.sp,
                color = color
            )
        }
    }
}

@Composable
fun HomeScreen(
    connectionState: ConnectionState,
    sessions: List<TerminalSession>,
    tabGroups: List<TerminalTabGroup>,
    serverUrl: String,
    deviceName: String,
    hasToken: Boolean,
    isPaired: Boolean,
    pairedDesktopName: String,
    statusMessage: String,
    onOpenSettings: () -> Unit,
    onConnect: () -> Unit,
    onDisconnect: () -> Unit,
    onRefresh: () -> Unit,
    onSessionSelected: (String) -> Unit
) {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .navigationBarsPadding(),
        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        if (!isPaired) {
            item {
                QuickStartCard(
                    connectionState = connectionState,
                    serverUrl = serverUrl,
                    deviceName = deviceName,
                    hasToken = hasToken,
                    onOpenSettings = onOpenSettings,
                    onConnect = onConnect,
                    onDisconnect = onDisconnect,
                    onRefresh = onRefresh
                )
            }
        } else {
            item {
                ConnectedDesktopCard(
                    connectionState = connectionState,
                    deviceName = deviceName,
                    pairedDesktopName = pairedDesktopName,
                    onOpenSettings = onOpenSettings,
                    onConnect = onConnect,
                    onDisconnect = onDisconnect,
                    onRefresh = onRefresh
                )
            }
        }

        if (statusMessage.isNotBlank()) {
            item {
                ElevatedCard(
                    colors = CardDefaults.elevatedCardColors(
                        containerColor = MaterialTheme.colorScheme.secondaryContainer
                    )
                ) {
                    Text(
                        text = statusMessage,
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
                        style = MaterialTheme.typography.bodySmall,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
        }

        item {
            if (sessions.isEmpty()) {
                EmptyStateScreen(connectionState, hasToken, isPaired)
            } else {
                Text(
                    text = if (tabGroups.size > 1) {
                        "终端 (${tabGroups.size} 个标签 · ${sessions.size} 个屏幕)"
                    } else {
                        "终端 (${sessions.size})"
                    },
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )
            }
        }

        if (sessions.isNotEmpty()) {
            if (tabGroups.any { it.tabId.startsWith("desktop_tab_") }) {
                items(tabGroups, key = { it.tabId }) { group ->
                    TerminalTabGroupSection(
                        group = group,
                        onSessionSelected = onSessionSelected
                    )
                }
            } else {
                items(sessions, key = { it.sessionId }) { session ->
                    SessionCard(session, onClick = { onSessionSelected(session.sessionId) })
                }
            }
        }
    }
}

private fun buildTerminalTabGroups(sessions: List<TerminalSession>): List<TerminalTabGroup> {
    if (sessions.isEmpty()) return emptyList()

    return sessions
        .groupBy { session ->
            session.tabId.takeIf { it.isNotBlank() }
                ?.let { "desktop_tab_$it" }
                ?: "ungrouped_${session.sessionId}"
        }
        .map { (groupId, groupSessions) ->
            val first = groupSessions.first()
            val sortedSessions = groupSessions.sortedWith(
                compareBy<TerminalSession> { terminalSessionAttentionRank(it) }
                    .thenByDescending { it.lastActivityAt }
                    .thenBy { normalizedOrder(it.paneOrder) }
                    .thenBy { it.title.lowercase() }
                    .thenBy { it.sessionId }
            )
            val title = first.tabTitle.takeIf { it.isNotBlank() }
                ?: if (sessions.size == 1) "未分组终端" else "标签"
            TerminalTabGroup(
                tabId = groupId,
                title = title,
                order = normalizedOrder(first.tabOrder),
                sessions = sortedSessions
            )
        }
        .sortedWith(
            compareBy<TerminalTabGroup> { groupAttentionRank(it) }
                .thenByDescending { groupLastActivityAt(it) }
                .thenBy { it.order }
                .thenBy { it.title.lowercase() }
                .thenBy { it.tabId }
        )
}

private fun normalizedOrder(value: Int): Int {
    return if (value < 0 || value == Int.MAX_VALUE) Int.MAX_VALUE else value
}

private fun terminalSessionAttentionRank(session: TerminalSession): Int {
    return when (session.taskState) {
        "waiting_input" -> 0
        "running" -> 1
        else -> 2
    }
}

private fun groupAttentionRank(group: TerminalTabGroup): Int {
    return group.sessions.minOfOrNull(::terminalSessionAttentionRank) ?: 2
}

private fun groupLastActivityAt(group: TerminalTabGroup): Long {
    return group.sessions.maxOfOrNull { it.lastActivityAt } ?: 0L
}

@Composable
fun TerminalTabGroupSection(
    group: TerminalTabGroup,
    onSessionSelected: (String) -> Unit
) {
    val activeCount = group.sessions.count { it.taskState == "running" || it.taskState == "waiting_input" }
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(7.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 2.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(
                modifier = Modifier.weight(1f),
                horizontalArrangement = Arrangement.spacedBy(7.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = Icons.Default.Terminal,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp),
                    tint = MaterialTheme.colorScheme.primary
                )
                Text(
                    text = group.title,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Text(
                text = if (activeCount > 0) {
                    "${group.sessions.size} 屏 · $activeCount 活跃"
                } else {
                    "${group.sessions.size} 屏"
                },
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1
            )
        }

        val splitRoot = group.sessions.firstNotNullOfOrNull { it.tabRoot }
        if (splitRoot != null && group.sessions.size > 1) {
            TerminalSplitPreview(
                root = splitRoot,
                sessions = group.sessions,
                onSessionSelected = onSessionSelected,
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 128.dp, max = 220.dp)
            )
        } else {
            group.sessions.forEach { session ->
                key(session.sessionId) {
                    SessionCard(session, onClick = { onSessionSelected(session.sessionId) })
                }
            }
        }
    }
}

@Composable
private fun TerminalSplitPreview(
    root: TerminalSplitNode,
    sessions: List<TerminalSession>,
    onSessionSelected: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    val byPaneId = remember(sessions) { sessions.associateBy { it.paneId } }
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(8.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.42f)
    ) {
        TerminalSplitNodePreview(
            node = root,
            sessionsByPaneId = byPaneId,
            onSessionSelected = onSessionSelected,
            modifier = Modifier
                .fillMaxWidth()
                .padding(6.dp)
        )
    }
}

@Composable
private fun TerminalSplitNodePreview(
    node: TerminalSplitNode,
    sessionsByPaneId: Map<String, TerminalSession>,
    onSessionSelected: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    if (node.type == "leaf") {
        val session = sessionsByPaneId[node.paneId]
        if (session != null) {
            SplitLeafPreview(
                session = session,
                onClick = { onSessionSelected(session.sessionId) },
                modifier = modifier
            )
        } else {
            SplitEmptyLeafPreview(modifier = modifier)
        }
        return
    }

    val children = node.children.ifEmpty { return SplitEmptyLeafPreview(modifier = modifier) }
    val horizontal = node.type == "horizontal"
    if (horizontal) {
        Row(
            modifier = modifier,
            horizontalArrangement = Arrangement.spacedBy(5.dp)
        ) {
            children.forEach { child ->
                TerminalSplitNodePreview(
                    node = child,
                    sessionsByPaneId = sessionsByPaneId,
                    onSessionSelected = onSessionSelected,
                    modifier = Modifier
                        .weight(child.size.coerceAtLeast(0.1f))
                        .fillMaxHeight()
                )
            }
        }
    } else {
        Column(
            modifier = modifier,
            verticalArrangement = Arrangement.spacedBy(5.dp)
        ) {
            children.forEach { child ->
                TerminalSplitNodePreview(
                    node = child,
                    sessionsByPaneId = sessionsByPaneId,
                    onSessionSelected = onSessionSelected,
                    modifier = Modifier
                        .weight(child.size.coerceAtLeast(0.1f))
                        .fillMaxWidth()
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SplitLeafPreview(
    session: TerminalSession,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val stateVisual = sessionTaskVisual(session, false)
    Surface(
        onClick = onClick,
        modifier = modifier,
        shape = RoundedCornerShape(6.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.96f),
        tonalElevation = 1.dp
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .border(1.dp, stateVisual.color.copy(alpha = 0.34f), RoundedCornerShape(6.dp))
                .padding(8.dp),
            verticalArrangement = Arrangement.spacedBy(5.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .size(7.dp)
                        .background(stateVisual.color, RoundedCornerShape(999.dp))
                )
                Text(
                    text = session.paneTitle.ifBlank { session.title },
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
            }
            Text(
                text = session.activity.ifBlank { session.preview.ifBlank { stateVisual.label } },
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
            TerminalScreenPreviewText(
                text = session.screenPreview,
                minLines = 3,
                maxLines = 5,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

@Composable
private fun SplitEmptyLeafPreview(modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(6.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.52f)
    ) {
        Spacer(modifier = Modifier.fillMaxSize())
    }
}

@Composable
fun QuickStartCard(
    connectionState: ConnectionState,
    serverUrl: String,
    deviceName: String,
    hasToken: Boolean,
    onOpenSettings: () -> Unit,
    onConnect: () -> Unit,
    onDisconnect: () -> Unit,
    onRefresh: () -> Unit
) {
    val isConnected = connectionState is ConnectionState.Connected
    val isConnecting = connectionState is ConnectionState.Connecting
    val showCustomServerUrl = isCustomServerUrl(serverUrl)
    val detail = buildList {
        add(if (hasToken) "手机身份已准备" else "首次配对会自动准备手机身份")
        add("等待桌面配对码")
        add(deviceName)
        if (showCustomServerUrl) add("自定义服务器")
    }.joinToString(" · ")

    HomeSummaryBar(
        icon = if (hasToken) Icons.Default.Verified else Icons.Default.Smartphone,
        iconTint = MaterialTheme.colorScheme.primary,
        headline = "连接桌面终端",
        detail = detail,
        containerColor = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.52f)
    ) {
        val primaryIcon = when {
            isConnected -> Icons.Default.Refresh
            else -> Icons.Default.Link
        }
        SummaryActionButton(
            icon = primaryIcon,
            contentDescription = when {
                isConnected -> "刷新"
                isConnecting -> "连接中"
                else -> "连接服务器"
            },
            onClick = when {
                isConnected -> onRefresh
                else -> onConnect
            },
            enabled = !isConnecting
        )
        SummaryActionButton(
            icon = Icons.Default.Settings,
            contentDescription = "设置",
            onClick = onOpenSettings
        )
    }
}

@Composable
fun ConnectedDesktopCard(
    connectionState: ConnectionState,
    deviceName: String,
    pairedDesktopName: String,
    onOpenSettings: () -> Unit,
    onConnect: () -> Unit,
    onDisconnect: () -> Unit,
    onRefresh: () -> Unit
) {
    val isConnected = connectionState is ConnectionState.Connected
    val isConnecting = connectionState is ConnectionState.Connecting
    val (_, connectionColor) = connectionStateVisual(connectionState)

    HomeSummaryBar(
        icon = Icons.Default.Verified,
        iconTint = connectionColor,
        headline = if (pairedDesktopName.isNotBlank()) pairedDesktopName else "已完成配对",
        detail = deviceName,
        containerColor = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.44f)
    ) {
        if (isConnected) {
            SummaryActionButton(
                icon = Icons.Default.Refresh,
                contentDescription = "刷新",
                onClick = onRefresh
            )
        } else {
            SummaryActionButton(
                icon = Icons.Default.Link,
                contentDescription = if (isConnecting) "连接中" else "连接服务器",
                onClick = onConnect,
                enabled = !isConnecting
            )
        }
        SummaryActionButton(
            icon = Icons.Default.Settings,
            contentDescription = "设置",
            onClick = onOpenSettings
        )
    }
}

@Composable
private fun HomeSummaryBar(
    icon: ImageVector,
    iconTint: Color,
    headline: String,
    detail: String,
    containerColor: Color,
    actions: @Composable RowScope.() -> Unit
) {
    ElevatedCard(
        colors = CardDefaults.elevatedCardColors(containerColor = containerColor),
        shape = RoundedCornerShape(8.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 7.dp),
            horizontalArrangement = Arrangement.spacedBy(7.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Surface(
                modifier = Modifier.size(28.dp),
                shape = RoundedCornerShape(8.dp),
                color = iconTint.copy(alpha = 0.14f)
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = icon,
                        contentDescription = null,
                        tint = iconTint,
                        modifier = Modifier.size(16.dp)
                    )
                }
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(1.dp)
            ) {
                Text(
                    text = headline,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    text = detail,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(0.dp),
                verticalAlignment = Alignment.CenterVertically,
                content = actions
            )
        }
    }
}

@Composable
private fun SummaryActionButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    enabled: Boolean = true
) {
    IconButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.size(40.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            modifier = Modifier.size(17.dp)
        )
    }
}

@Composable
fun TerminalListScreen(
    sessions: List<TerminalSession>,
    onSessionSelected: (String) -> Unit
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        item {
            Text(
                text = "终端 (${sessions.size})",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(bottom = 4.dp)
            )
        }
        
        items(sessions) { session ->
            SessionCard(session, onClick = { onSessionSelected(session.sessionId) })
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun SessionCard(session: TerminalSession, onClick: () -> Unit) {
    val now by produceState(initialValue = System.currentTimeMillis(), session.lastActivityAt) {
        while (true) {
            value = System.currentTimeMillis()
            delay(1000)
        }
    }
    val isRecentlyActive = session.lastActivityAt > 0L && now - session.lastActivityAt < 3000L
    val stateVisual = sessionTaskVisual(session, isRecentlyActive)
    val pulseAlpha = if (stateVisual.pulse) {
        rememberInfiniteTransition(label = "session-activity").animateFloat(
            initialValue = 0.45f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(
                animation = tween(650),
                repeatMode = RepeatMode.Reverse
            ),
            label = "session-activity-alpha"
        ).value
    } else {
        1f
    }
    val activityText = session.activity.ifBlank {
        when (stateVisual.state) {
            "completed" -> "任务已完成"
            "waiting_input" -> "等待输入"
            "running" -> session.preview.ifBlank { "正在处理终端任务" }
            "error" -> session.preview.ifBlank { "终端任务出错" }
            else -> session.preview.ifBlank { "等待新的输出" }
        }
    }
    val previewText = session.preview.takeIf { it.isNotBlank() && it != activityText }
    val relativeTime = formatRelativeActivity(now, session.lastActivityAt)
    Card(
        modifier = Modifier.fillMaxWidth(),
        onClick = onClick,
        shape = RoundedCornerShape(8.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(7.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .size(9.dp)
                        .graphicsLayer { alpha = pulseAlpha }
                        .background(
                            color = stateVisual.color,
                            shape = RoundedCornerShape(999.dp)
                        )
                )
                Text(
                    text = session.title,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                Surface(
                    shape = RoundedCornerShape(999.dp),
                    color = stateVisual.color.copy(alpha = 0.14f)
                ) {
                    Text(
                        text = stateVisual.label,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                        style = MaterialTheme.typography.labelSmall,
                        color = stateVisual.color,
                        maxLines = 1
                    )
                }
            }

            Text(
                text = activityText,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )

            if (previewText != null) {
                Text(
                    text = previewText,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }

            TerminalScreenPreviewText(
                text = session.screenPreview,
                minLines = 4,
                maxLines = 7,
                modifier = Modifier.fillMaxWidth()
            )

            FlowRow(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(5.dp)
            ) {
                SessionMetaChip("${session.cols}x${session.rows}")
                if (session.isOwner) {
                    SessionMetaChip("本机")
                }
                if (relativeTime.isNotBlank()) {
                    SessionMetaChip(relativeTime)
                }
            }
        }
    }
}

@Composable
private fun TerminalScreenPreviewText(
    text: String,
    minLines: Int,
    maxLines: Int,
    modifier: Modifier = Modifier
) {
    val lines = remember(text, maxLines) {
        text
            .replace("\r", "")
            .lines()
            .takeLast(maxLines)
            .joinToString("\n")
            .ifBlank { "等待终端输出" }
    }
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(6.dp),
        color = Color(0xFF101214)
    ) {
        Text(
            text = lines,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
            style = MaterialTheme.typography.labelSmall.copy(
                fontFamily = FontFamily.Monospace,
                lineHeight = 13.sp
            ),
            color = Color(0xFFD6D6D6),
            minLines = minLines,
            maxLines = maxLines,
            overflow = TextOverflow.Clip
        )
    }
}

@Composable
private fun SessionMetaChip(text: String) {
    Surface(
        shape = RoundedCornerShape(999.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.65f)
    ) {
        Text(
            text = text,
            modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1
        )
    }
}

private fun formatRelativeActivity(now: Long, lastActivityAt: Long): String {
    if (lastActivityAt <= 0L) return ""
    val seconds = ((now - lastActivityAt).coerceAtLeast(0L) / 1000L).toInt()
    return when {
        seconds < 5 -> "刚刚"
        seconds < 60 -> "${seconds}秒前"
        seconds < 3600 -> "${seconds / 60}分钟前"
        seconds < 86400 -> "${seconds / 3600}小时前"
        else -> "${seconds / 86400}天前"
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun TerminalViewScreen(
    connectionState: ConnectionState,
    session: TerminalSession?,
    sameTabSessions: List<TerminalSession>,
    output: String,
    outputVersion: Long,
    outputEncoding: String,
    terminalDelta: SharedFlow<TerminalDeltaBatch>,
    replayLoading: Boolean,
    terminalStreamStatus: String,
    terminalFontScale: Float,
    commandLibrary: CommandLibraryUiState,
    onSubmitCommand: (String) -> Unit,
    onSendRawInput: (String) -> Unit,
    onToggleFavoriteCommand: (String) -> Unit,
    onSendSpecialKey: (SpecialKey) -> Unit,
    onRefreshTerminal: () -> Unit,
    onTerminalFontScaleChange: (Float) -> Unit,
    onRequestCloseSession: (String) -> Unit,
    onTerminalResize: (Int, Int, Boolean) -> Unit,
    onSessionSelected: (String) -> Unit,
    onDebug: (String) -> Unit,
    onClose: () -> Unit
) {
    var input by rememberSaveable(session?.sessionId) { mutableStateOf("") }
    var showSpecialKeysDialog by rememberSaveable(session?.sessionId) { mutableStateOf(false) }
    var showCloseSessionDialog by rememberSaveable(session?.sessionId) { mutableStateOf(false) }
    var copyMode by rememberSaveable(session?.sessionId) { mutableStateOf(false) }
    val fontScale = terminalFontScale.coerceIn(0.7f, 1.6f)
    var showLayoutControls by rememberSaveable(session?.sessionId) { mutableStateOf(false) }
    var showCommandLibraryDialog by rememberSaveable(session?.sessionId) { mutableStateOf(false) }
    var showMoreMenu by remember { mutableStateOf(false) }
    var terminalAtBottom by rememberSaveable(session?.sessionId) { mutableStateOf(true) }
    var scrollToBottomRequest by rememberSaveable(session?.sessionId) { mutableStateOf(0L) }
    var inputHistory by rememberSaveable(session?.sessionId) { mutableStateOf(emptyList<String>()) }
    var quickActionOrder by remember(session?.sessionId) { mutableStateOf(0) }
    var quickActionUsage by remember(session?.sessionId) {
        mutableStateOf(emptyMap<String, ComposerQuickActionUsage>())
    }
    var selectedCommandSectionKey by rememberSaveable(session?.sessionId) {
        mutableStateOf(CommandPanelSection.Favorites.key)
    }
    val focusManager = LocalFocusManager.current
    fun rememberQuickAction(kind: ComposerQuickActionKind) {
        quickActionOrder += 1
        val key = kind.name
        val previous = quickActionUsage[key] ?: ComposerQuickActionUsage()
        quickActionUsage = quickActionUsage + (key to previous.copy(
            count = previous.count + 1,
            lastUsedOrder = quickActionOrder
        ))
    }
    fun submitCurrentInput() {
        if (input.isNotBlank()) {
            val submitted = input
            inputHistory = (listOf(submitted) + inputHistory.filterNot { it == submitted }).take(12)
            onSubmitCommand(submitted)
            input = ""
            focusManager.clearFocus()
        }
    }
    fun sendCurrentInputToTerminal() {
        if (input.isNotBlank()) {
            val submitted = input
            inputHistory = (listOf(submitted) + inputHistory.filterNot { it == submitted }).take(12)
            onSendRawInput(buildTuiSubmitPayload(submitted))
            input = ""
            focusManager.clearFocus()
        } else {
            onSendRawInput("\r")
        }
    }

    val stateVisual = sessionTaskVisual(session, false)
    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        val activityText = session?.activity?.ifBlank {
            session.preview.ifBlank {
                when (stateVisual.state) {
                    "completed" -> "任务已完成"
                    "waiting_input" -> "等待输入"
                    "running" -> "正在处理终端任务"
                    "error" -> "终端任务出错"
                    else -> "等待新的输出"
                }
            }
        }.orEmpty()
        val overlayStatus = when {
            terminalStreamStatus.isNotBlank() && terminalStreamStatus != "实时同步中" -> terminalStreamStatus
            copyMode -> "复制模式已开启，可在终端区域长按后框选复制"
            else -> ""
        }
        LaunchedEffect(maxWidth, maxHeight, showSpecialKeysDialog, copyMode, fontScale, showLayoutControls, showCommandLibraryDialog) {
            onDebug(
                "TV_LAYOUT max=${maxWidth.value}x${maxHeight.value}dp keysDialog=$showSpecialKeysDialog copyMode=$copyMode renderedCells=true fontScale=$fontScale layoutExpanded=$showLayoutControls commandDialog=$showCommandLibraryDialog"
            )
        }
        Column(
            modifier = Modifier.fillMaxSize()
        ) {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.96f)
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 8.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(
                        modifier = Modifier.weight(1f),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        IconButton(onClick = onClose, modifier = Modifier.size(40.dp)) {
                            Icon(Icons.Default.ArrowBack, contentDescription = "返回", modifier = Modifier.size(20.dp))
                        }
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(1.dp)
                        ) {
                            Text(
                                text = session?.title ?: "远程终端",
                                style = MaterialTheme.typography.titleSmall,
                                fontWeight = FontWeight.SemiBold,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                val (connLabel, connColor) = connectionStateVisual(connectionState)
                                Box(
                                    modifier = Modifier
                                        .size(7.dp)
                                        .background(connColor, RoundedCornerShape(999.dp))
                                )
                                Text(
                                    text = connLabel,
                                    color = connColor,
                                    style = MaterialTheme.typography.labelSmall,
                                    maxLines = 1
                                )
                                Text(
                                    text = stateVisual.label,
                                    color = stateVisual.color,
                                    style = MaterialTheme.typography.labelSmall,
                                    maxLines = 1
                                )
                                if (activityText.isNotBlank()) {
                                    Text(
                                        text = activityText,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        style = MaterialTheme.typography.labelSmall,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f)
                                    )
                                }
                            }
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                        IconButton(onClick = { copyMode = !copyMode }, modifier = Modifier.size(40.dp)) {
                            Icon(
                                Icons.Default.ContentCopy,
                                contentDescription = if (copyMode) "退出复制模式" else "进入复制模式",
                                modifier = Modifier.size(19.dp),
                                tint = if (copyMode) Color(0xFF4CAF50) else MaterialTheme.colorScheme.onSurface
                            )
                        }
                        Box {
                            IconButton(onClick = { showMoreMenu = true }, modifier = Modifier.size(40.dp)) {
                                Icon(Icons.Default.MoreVert, contentDescription = "更多", modifier = Modifier.size(20.dp))
                            }
                            DropdownMenu(
                                expanded = showMoreMenu,
                                onDismissRequest = { showMoreMenu = false }
                            ) {
                                DropdownMenuItem(
                                    text = { Text(if (replayLoading) "正在刷新" else "刷新输出") },
                                    leadingIcon = {
                                        Icon(Icons.Default.Refresh, contentDescription = null)
                                    },
                                    onClick = {
                                        showMoreMenu = false
                                        onRefreshTerminal()
                                    }
                                )
                                DropdownMenuItem(
                                    text = { Text("特殊键") },
                                    leadingIcon = {
                                        Icon(Icons.Default.Keyboard, contentDescription = null)
                                    },
                                    onClick = {
                                        showMoreMenu = false
                                        showSpecialKeysDialog = true
                                    }
                                )
                                DropdownMenuItem(
                                    text = { Text("命令库") },
                                    leadingIcon = {
                                        Icon(Icons.Default.Terminal, contentDescription = null)
                                    },
                                    onClick = {
                                        showMoreMenu = false
                                        showCommandLibraryDialog = true
                                    }
                                )
                                DropdownMenuItem(
                                    text = { Text("字号") },
                                    leadingIcon = {
                                        Icon(Icons.Default.Settings, contentDescription = null)
                                    },
                                    onClick = {
                                        showMoreMenu = false
                                        showLayoutControls = true
                                    }
                                )
                                if (session != null) {
                                    DropdownMenuItem(
                                        text = { Text("关闭终端") },
                                        leadingIcon = {
                                            Icon(Icons.Default.Delete, contentDescription = null)
                                        },
                                        onClick = {
                                            showMoreMenu = false
                                            showCloseSessionDialog = true
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
            }
            if (sameTabSessions.size > 1) {
                TerminalPaneSwitcher(
                    currentSessionId = session?.sessionId,
                    panes = sameTabSessions,
                    onSessionSelected = onSessionSelected
                )
            }
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(horizontal = 0.dp, vertical = 0.dp)
            ) {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = Color(0xFF1E1E1E),
                    shape = RoundedCornerShape(0.dp)
                ) {
                    TerminalWebView(
                        sessionId = session?.sessionId,
                        output = output,
                        outputVersion = outputVersion,
                        outputEncoding = outputEncoding,
                        terminalDelta = terminalDelta,
                        desktopCols = session?.cols ?: 80,
                        desktopRows = session?.rows ?: 24,
                        fontScale = fontScale,
                        copyMode = copyMode,
                        scrollToBottomRequest = scrollToBottomRequest,
                        onTerminalResize = onTerminalResize,
                        onScrollAtBottom = { terminalAtBottom = it },
                        onTuiDetected = {},
                        onReaderCommand = onSubmitCommand,
                        onDebug = onDebug,
                        modifier = Modifier.fillMaxSize()
                    )
                }
                if (overlayStatus.isNotBlank()) {
                    Surface(
                        modifier = Modifier
                            .align(Alignment.TopStart)
                            .padding(8.dp),
                        shape = RoundedCornerShape(8.dp),
                        color = when {
                            copyMode -> MaterialTheme.colorScheme.tertiaryContainer.copy(alpha = 0.94f)
                            replayLoading -> MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.94f)
                            else -> MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.88f)
                        }
                    ) {
                        Text(
                            text = overlayStatus,
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                            style = MaterialTheme.typography.labelSmall,
                            color = when {
                                copyMode -> MaterialTheme.colorScheme.onTertiaryContainer
                                replayLoading -> MaterialTheme.colorScheme.onSecondaryContainer
                                else -> MaterialTheme.colorScheme.onSurfaceVariant
                            },
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
                if (!terminalAtBottom) {
                    Surface(
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .padding(12.dp),
                        shape = RoundedCornerShape(999.dp),
                        color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.96f),
                        tonalElevation = 5.dp
                    ) {
                        IconButton(
                            onClick = { scrollToBottomRequest += 1 },
                            modifier = Modifier.size(42.dp)
                        ) {
                            Icon(
                                Icons.Default.KeyboardArrowDown,
                                contentDescription = "回到底部",
                                tint = MaterialTheme.colorScheme.onPrimaryContainer,
                                modifier = Modifier.size(24.dp)
                            )
                        }
                    }
                }
            }

            MobileTerminalComposer(
                input = input,
                onInputChange = { input = it },
                onSubmit = { submitCurrentInput() },
                inputHistory = inputHistory,
                quickActionUsage = quickActionUsage,
                onQuickActionUsed = ::rememberQuickAction,
                onSendToTerminal = { sendCurrentInputToTerminal() },
                onInsertNewline = { input += "\n" },
                onHistorySelected = { input = it },
                onOpenCommandLibrary = { showCommandLibraryDialog = true },
                onToggleFavorite = {
                    if (input.isNotBlank()) {
                        onToggleFavoriteCommand(input)
                    }
                },
                onSendSpecialKey = onSendSpecialKey,
                modifier = Modifier
                    .fillMaxWidth()
                    .imePadding()
                    .navigationBarsPadding()
            )
        }
    }

    if (showSpecialKeysDialog) {
        AlertDialog(
            onDismissRequest = { showSpecialKeysDialog = false },
            title = { Text("特殊键") },
            text = {
                FlowRow(
                    modifier = Modifier.fillMaxWidth(),
                    maxItemsInEachRow = 4,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    ALL_SPECIAL_KEYS.forEach { (label, key) ->
                        SpecialKeyButton(label) {
                            onSendSpecialKey(key)
                            showSpecialKeysDialog = false
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showSpecialKeysDialog = false }) {
                    Text("关闭")
                }
            }
        )
    }

    if (showCommandLibraryDialog) {
        Dialog(
            onDismissRequest = { showCommandLibraryDialog = false },
            properties = DialogProperties(usePlatformDefaultWidth = false)
        ) {
            Surface(
                modifier = Modifier
                    .fillMaxWidth(0.94f)
                    .fillMaxHeight(0.82f),
                shape = RoundedCornerShape(12.dp),
                color = MaterialTheme.colorScheme.surface,
                tonalElevation = 6.dp
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = "命令库",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold
                        )
                        TextButton(onClick = { showCommandLibraryDialog = false }) {
                            Text("关闭")
                        }
                    }
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .verticalScroll(androidx.compose.foundation.rememberScrollState())
                    ) {
                        CommandLibraryPanel(
                            library = commandLibrary,
                            selectedSectionKey = selectedCommandSectionKey,
                            expanded = true,
                            showToggle = false,
                            inputHistory = inputHistory,
                            onToggleExpanded = {},
                            onSectionSelected = { selectedCommandSectionKey = it },
                            onHistorySelected = { history ->
                                input = history
                                showCommandLibraryDialog = false
                            },
                            onCommandSelected = { shortcut ->
                                onSubmitCommand(shortcut.command)
                                input = ""
                                focusManager.clearFocus()
                                showCommandLibraryDialog = false
                            }
                        )
                    }
                }
            }
        }
    }

    if (showLayoutControls) {
        AlertDialog(
            onDismissRequest = { showLayoutControls = false },
            title = { Text("字号") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        TextButton(
                            onClick = { onTerminalFontScaleChange((fontScale - 0.1f).coerceIn(0.7f, 1.6f)) }
                        ) {
                            Text("A-")
                        }
                        TextButton(onClick = { onTerminalFontScaleChange(1.0f) }) {
                            Text(
                                text = "${(fontScale * 100).toInt()}%",
                                style = MaterialTheme.typography.titleSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        TextButton(
                            onClick = { onTerminalFontScaleChange((fontScale + 0.1f).coerceIn(0.7f, 1.6f)) }
                        ) {
                            Text("A+")
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showLayoutControls = false }) {
                    Text("完成")
                }
            }
        )
    }

    if (showCloseSessionDialog && session != null) {
        AlertDialog(
            onDismissRequest = { showCloseSessionDialog = false },
            title = { Text("关闭桌面终端") },
            text = { Text("这会让已配对桌面关闭当前终端。") },
            confirmButton = {
                Button(
                    onClick = {
                        showCloseSessionDialog = false
                        onRequestCloseSession(session.sessionId)
                    }
                ) {
                    Text("关闭")
                }
            },
            dismissButton = {
                TextButton(onClick = { showCloseSessionDialog = false }) {
                    Text("取消")
                }
            }
        )
    }
}

@Composable
fun SpecialKeyButton(label: String, onClick: () -> Unit) {
    TextButton(
        onClick = onClick,
        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 5.dp)
    ) {
        Text(label, fontSize = 12.sp)
    }
}

private fun buildTuiSubmitPayload(input: String): String {
    val text = input.replace("\r\n", "\n").replace("\r", "\n")
    if (text.isBlank()) return "\r"
    val pasteSafeText = text.replace("\u001B", "")
    return if (pasteSafeText.contains('\n')) {
        "\u001B[200~$pasteSafeText\u001B[201~\r"
    } else {
        "$pasteSafeText\r"
    }
}

@Composable
private fun TerminalPaneSwitcher(
    currentSessionId: String?,
    panes: List<TerminalSession>,
    onSessionSelected: (String) -> Unit
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.72f)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = panes.firstOrNull()?.tabTitle?.takeIf { it.isNotBlank() } ?: "当前标签",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(0.36f)
            )
            LazyRow(
                modifier = Modifier.weight(0.64f),
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                items(panes, key = { it.sessionId }) { pane ->
                    val selected = pane.sessionId == currentSessionId
                    val order = normalizedOrder(pane.paneOrder)
                    val label = pane.paneTitle
                        .ifBlank { pane.title }
                        .ifBlank { if (order == Int.MAX_VALUE) "屏幕" else "屏幕 ${order + 1}" }
                    if (selected) {
                        Button(
                            onClick = {},
                            enabled = false,
                            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp),
                            modifier = Modifier.height(32.dp)
                        ) {
                            Text(
                                text = label,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                style = MaterialTheme.typography.labelSmall
                            )
                        }
                    } else {
                        TextButton(
                            onClick = { onSessionSelected(pane.sessionId) },
                            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp),
                            modifier = Modifier.height(32.dp)
                        ) {
                            Text(
                                text = label,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                style = MaterialTheme.typography.labelSmall
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MobileTerminalComposer(
    input: String,
    onInputChange: (String) -> Unit,
    onSubmit: () -> Unit,
    inputHistory: List<String>,
    quickActionUsage: Map<String, ComposerQuickActionUsage>,
    onQuickActionUsed: (ComposerQuickActionKind) -> Unit,
    onSendToTerminal: () -> Unit,
    onInsertNewline: () -> Unit,
    onHistorySelected: (String) -> Unit,
    onOpenCommandLibrary: () -> Unit,
    onToggleFavorite: () -> Unit,
    onSendSpecialKey: (SpecialKey) -> Unit,
    modifier: Modifier = Modifier
) {
    val canSubmit = input.isNotBlank()
    val sortedQuickActions = remember(quickActionUsage) {
        COMPOSER_QUICK_ACTIONS.sortedWith(
            compareByDescending<ComposerQuickActionSpec> { quickActionUsage[it.kind.name]?.count ?: 0 }
                .thenByDescending { quickActionUsage[it.kind.name]?.lastUsedOrder ?: 0 }
                .thenByDescending { it.defaultRank }
        )
    }

    Surface(
        modifier = modifier,
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.98f),
        tonalElevation = 3.dp
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 6.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            LazyRow(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                contentPadding = PaddingValues(horizontal = 0.dp)
            ) {
                items(sortedQuickActions, key = { it.kind.name }) { action ->
                    val enabled = when (action.kind) {
                        ComposerQuickActionKind.Favorite,
                        ComposerQuickActionKind.TerminalSubmit -> canSubmit
                        else -> true
                    }
                    val selected = action.kind == ComposerQuickActionKind.Favorite && canSubmit
                    ComposerToolChip(
                        label = action.label,
                        selected = selected,
                        enabled = enabled,
                        onClick = {
                            onQuickActionUsed(action.kind)
                            when (action.kind) {
                                ComposerQuickActionKind.ContinuePrompt -> {
                                    val prompt = CODEX_QUICK_PROMPTS.first().prompt
                                    onInputChange(
                                        if (input.isBlank()) {
                                            prompt
                                        } else {
                                            input.trimEnd() + "\n" + prompt
                                        }
                                    )
                                }
                                ComposerQuickActionKind.CommandLibrary -> onOpenCommandLibrary()
                                ComposerQuickActionKind.Favorite -> onToggleFavorite()
                                ComposerQuickActionKind.TerminalSubmit -> onSendToTerminal()
                                ComposerQuickActionKind.Escape -> onSendSpecialKey(SpecialKey.Escape)
                                ComposerQuickActionKind.CtrlC -> onSendSpecialKey(SpecialKey.CtrlC)
                                ComposerQuickActionKind.Tab -> onSendSpecialKey(SpecialKey.Tab)
                                ComposerQuickActionKind.ArrowUp -> onSendSpecialKey(SpecialKey.ArrowUp)
                                ComposerQuickActionKind.ArrowDown -> onSendSpecialKey(SpecialKey.ArrowDown)
                            }
                        }
                    )
                }
                item("newline") {
                    ComposerToolChip(
                        label = "换行",
                        selected = false,
                        onClick = {
                            onInsertNewline()
                        }
                    )
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.Bottom
            ) {
                OutlinedTextField(
                    value = input,
                    onValueChange = onInputChange,
                    modifier = Modifier
                        .weight(1f)
                        .heightIn(min = 48.dp, max = 136.dp),
                    placeholder = { Text("给 Codex 的下一步指令") },
                    minLines = 1,
                    maxLines = 5,
                    singleLine = false,
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Text,
                        imeAction = ImeAction.Send
                    ),
                    keyboardActions = KeyboardActions(
                        onSend = { onSubmit() }
                    )
                )
                Button(
                    onClick = onSubmit,
                    enabled = canSubmit,
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp),
                    modifier = Modifier
                        .height(48.dp)
                        .width(56.dp)
                ) {
                    Icon(Icons.Default.Send, contentDescription = "发送", modifier = Modifier.size(18.dp))
                }
            }

            if (inputHistory.isNotEmpty()) {
                LazyRow(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    contentPadding = PaddingValues(horizontal = 0.dp)
                ) {
                    items(inputHistory.take(6), key = { it }) { historyItem ->
                        ComposerToolChip(
                            label = historyItem.replace("\n", " ").let { if (it.length > 28) it.take(27) + "…" else it },
                            selected = false,
                            onClick = { onHistorySelected(historyItem) }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ComposerToolChip(
    label: String,
    selected: Boolean,
    enabled: Boolean = true,
    onClick: () -> Unit
) {
    Surface(
        shape = RoundedCornerShape(999.dp),
        color = if (selected) {
            MaterialTheme.colorScheme.primary.copy(alpha = 0.18f)
        } else {
            MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.72f)
        }
    ) {
        TextButton(
            onClick = onClick,
            enabled = enabled,
            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp),
            modifier = Modifier.height(32.dp)
        ) {
            Text(
                text = label,
                style = MaterialTheme.typography.labelSmall,
                color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun CommandLibraryPanel(
    library: CommandLibraryUiState,
    selectedSectionKey: String,
    expanded: Boolean,
    showToggle: Boolean = true,
    inputHistory: List<String> = emptyList(),
    onToggleExpanded: () -> Unit,
    onSectionSelected: (String) -> Unit,
    onHistorySelected: (String) -> Unit = {},
    onCommandSelected: (CommandShortcut) -> Unit
) {
    val sectionTabs = remember(library.sections) {
        buildList {
            add(CommandPanelSection.Favorites.key to CommandPanelSection.Favorites.label)
            add(CommandPanelSection.Recent.key to CommandPanelSection.Recent.label)
            library.sections.forEach { section ->
                add(section.key to section.label)
            }
        }
    }
    val selectedCommands = remember(selectedSectionKey, library.favorites, library.recent, library.sections) {
        when (selectedSectionKey) {
            CommandPanelSection.Favorites.key -> library.favorites
            CommandPanelSection.Recent.key -> library.recent
            else -> library.sections.firstOrNull { it.key == selectedSectionKey }?.commands.orEmpty()
        }
    }
    val selectedSectionLabel = sectionTabs.firstOrNull { it.first == selectedSectionKey }?.second ?: "收藏"

    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 2.dp)
            .animateContentSize(),
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 6.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "命令库",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                if (showToggle) {
                    TextButton(
                        onClick = onToggleExpanded,
                        contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp)
                    ) {
                        Text(if (expanded) "收起" else "展开")
                        Icon(
                            imageVector = if (expanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp)
                        )
                    }
                } else {
                    Text(
                        text = "点一下立即发送执行",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            if (expanded) {
                Text(
                    text = "推荐",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                LazyRow(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    contentPadding = PaddingValues(horizontal = 2.dp)
                ) {
                    items(library.recommended, key = { it.id }) { shortcut ->
                        CommandShortcutChip(
                            shortcut = shortcut,
                            onClick = { onCommandSelected(shortcut) }
                        )
                    }
                }

                LazyRow(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    contentPadding = PaddingValues(horizontal = 2.dp)
                ) {
                    items(sectionTabs, key = { it.first }) { (key, label) ->
                        SectionTabChip(
                            label = label,
                            selected = key == selectedSectionKey,
                            onClick = { onSectionSelected(key) }
                        )
                    }
                }

                Text(
                    text = selectedSectionLabel,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                if (selectedCommands.isEmpty()) {
                    Text(
                        text = when (selectedSectionKey) {
                            CommandPanelSection.Favorites.key -> "把当前命令加入收藏后，会出现在这里"
                            CommandPanelSection.Recent.key -> "你发过的命令会自动进入最近使用"
                            else -> "当前分组还没有命令"
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                } else {
                    FlowRow(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        selectedCommands.forEach { shortcut ->
                            CommandShortcutChip(
                                shortcut = shortcut,
                                onClick = { onCommandSelected(shortcut) }
                            )
                        }
                    }
                }

                Text(
                    text = if (showToggle) "点一下把命令填入输入框，再点发送" else "命令会直接发送到当前终端",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

        }
    }
}

@Composable
private fun CommandShortcutChip(
    shortcut: CommandShortcut,
    onClick: () -> Unit
) {
    val background = when {
        shortcut.dangerous -> Color(0x33FF9800)
        shortcut.isFavorite -> MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.7f)
        else -> MaterialTheme.colorScheme.surface.copy(alpha = 0.9f)
    }
    val textColor = when {
        shortcut.dangerous -> Color(0xFFFFC107)
        shortcut.isFavorite -> MaterialTheme.colorScheme.onPrimaryContainer
        else -> MaterialTheme.colorScheme.onSurface
    }

    Surface(
        shape = RoundedCornerShape(999.dp),
        color = background
    ) {
        TextButton(
            onClick = onClick,
            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp)
        ) {
            Text(
                text = shortcut.title,
                style = MaterialTheme.typography.labelSmall,
                color = textColor
            )
        }
    }
}

@Composable
private fun SectionTabChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit
) {
    Surface(
        shape = RoundedCornerShape(999.dp),
        color = if (selected) {
            MaterialTheme.colorScheme.primary.copy(alpha = 0.18f)
        } else {
            MaterialTheme.colorScheme.surface.copy(alpha = 0.82f)
        }
    ) {
        TextButton(
            onClick = onClick,
            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp)
        ) {
            Text(
                text = label,
                style = MaterialTheme.typography.labelSmall,
                color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
fun EmptyStateScreen(connectionState: ConnectionState, hasToken: Boolean, isPaired: Boolean) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 8.dp),
        contentAlignment = Alignment.Center
    ) {
        ElevatedCard {
            Column(
                modifier = Modifier.padding(18.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
            Icon(
                imageVector = Icons.Default.Terminal,
                contentDescription = null,
                modifier = Modifier.size(44.dp),
                tint = MaterialTheme.colorScheme.primary
            )
            
            Spacer(modifier = Modifier.height(10.dp))
            
            Text(
                text = when (connectionState) {
                    is ConnectionState.Disconnected -> when {
                        !hasToken -> "输入桌面配对码即可开始"
                        !isPaired -> "先完成桌面配对"
                        else -> "还没有连接服务器"
                    }
                    is ConnectionState.Connecting -> "正在连接..."
                    is ConnectionState.Connected -> "还没有可用终端"
                    is ConnectionState.Error -> "连接出了点问题"
                },
                style = MaterialTheme.typography.titleMedium
            )
            
            Spacer(modifier = Modifier.height(6.dp))
            
            Text(
                text = when (connectionState) {
                    is ConnectionState.Disconnected -> when {
                        !hasToken -> "在桌面端生成 6 位配对码，手机会自动准备身份并完成绑定。"
                        !isPaired -> "输入桌面端生成的 6 位配对码，完成一次绑定后这里就不会再提示。"
                        else -> "点击上方连接服务器，随后就能看到桌面端共享的终端。"
                    }
                    is ConnectionState.Connecting -> "请稍等，正在建立安全连接。"
                    is ConnectionState.Connected -> "去桌面端打开一个终端，手机上会自动显示在这里。"
                    is ConnectionState.Error -> "检查服务器地址、网络和证书后重试。"
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            }
        }
    }
}

@Composable
fun ConnectionDialog(
    onDismiss: () -> Unit,
    serverUrl: String,
    deviceToken: String,
    deviceName: String,
    statusMessage: String,
    appUpdate: AppUpdateUiState,
    onServerUrlChange: (String) -> Unit,
    onDeviceTokenChange: (String) -> Unit,
    onDeviceNameChange: (String) -> Unit,
    onCheckUpdate: () -> Unit,
    onDownloadUpdate: () -> Unit,
    onRegister: () -> Unit,
    onPair: (String) -> Unit,
    onConnect: () -> Unit
) {
    var pairingCode by remember { mutableStateOf("") }
    var showAdvanced by rememberSaveable { mutableStateOf(false) }
    val displayedServerUrl = if (isCustomServerUrl(serverUrl)) serverUrl else ""
    val context = LocalContext.current
    
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Surface(
            modifier = Modifier
                .fillMaxWidth(0.94f)
                .fillMaxHeight(0.86f)
                .imePadding()
                .navigationBarsPadding(),
            shape = RoundedCornerShape(12.dp),
            color = MaterialTheme.colorScheme.surface,
            tonalElevation = 6.dp
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text(
                    text = "连接桌面",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .verticalScroll(androidx.compose.foundation.rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Surface(
                        shape = RoundedCornerShape(14.dp),
                        color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.65f)
                    ) {
                        Column(modifier = Modifier.padding(12.dp)) {
                            Text("输入桌面端生成的 6 位配对码", fontWeight = FontWeight.SemiBold)
                            Spacer(modifier = Modifier.height(4.dp))
                            Text("手机身份会自动准备，配对成功后会直接连接到桌面终端。", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    OutlinedTextField(
                        value = pairingCode,
                        onValueChange = { pairingCode = it.filter(Char::isDigit).take(6) },
                        label = { Text("桌面配对码") },
                        modifier = Modifier.fillMaxWidth(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        singleLine = true
                    )
                    Button(
                        onClick = { onPair(pairingCode) },
                        enabled = pairingCode.length == 6,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text("完成配对并连接")
                    }
                    TextButton(onClick = { showAdvanced = !showAdvanced }) {
                        Text(if (showAdvanced) "收起高级设置" else "高级设置")
                    }
                    if (showAdvanced) {
                        OutlinedTextField(
                            value = displayedServerUrl,
                            onValueChange = {
                                val trimmed = it.trim()
                                onServerUrlChange(if (trimmed.isBlank()) DEFAULT_SERVER_URL else trimmed)
                            },
                            label = { Text("服务器地址") },
                            placeholder = { Text(DEFAULT_SERVER_URL) },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true
                        )
                        OutlinedTextField(
                            value = deviceName,
                            onValueChange = onDeviceNameChange,
                            label = { Text("手机名称") },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true
                        )
                        OutlinedTextField(
                            value = deviceToken,
                            onValueChange = onDeviceTokenChange,
                            label = { Text("手机身份 Token") },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true
                        )
                        TextButton(onClick = onRegister) {
                            Text("重新生成手机身份")
                        }
                    }
                    VersionUpdatePanel(
                        appUpdate = appUpdate,
                        onCheckUpdate = onCheckUpdate,
                        onDownloadUpdate = onDownloadUpdate,
                        onInstallUpdate = {
                            installDownloadedApk(context, appUpdate.downloadedFilePath)
                        }
                    )
                    if (statusMessage.isNotBlank()) {
                        Surface(
                            shape = RoundedCornerShape(12.dp),
                            color = MaterialTheme.colorScheme.secondaryContainer
                        ) {
                            Text(
                                text = statusMessage,
                                modifier = Modifier.padding(10.dp),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSecondaryContainer
                            )
                        }
                    }
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    TextButton(
                        onClick = onDismiss,
                        modifier = Modifier.weight(1f)
                    ) {
                        Text("关闭")
                    }
                    Button(
                        onClick = onConnect,
                        modifier = Modifier.weight(1f)
                    ) {
                        Text("连接")
                    }
                }
            }
        }
    }
}

@Composable
private fun VersionUpdatePanel(
    appUpdate: AppUpdateUiState,
    onCheckUpdate: () -> Unit,
    onDownloadUpdate: () -> Unit,
    onInstallUpdate: () -> Unit
) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("版本升级", fontWeight = FontWeight.SemiBold)
                    Text(
                        text = "当前版本 ${appUpdate.currentVersionName}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                TextButton(
                    onClick = onCheckUpdate,
                    enabled = !appUpdate.checking && !appUpdate.downloading
                ) {
                    Text(if (appUpdate.checking) "检查中" else "检查")
                }
            }
            if (appUpdate.message.isNotBlank()) {
                Text(
                    text = appUpdate.message,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            if (appUpdate.hasUpdate) {
                val latest = appUpdate.latest
                Text(
                    text = listOfNotNull(
                        latest?.fileName,
                        latest?.size?.takeIf { it.isNotBlank() },
                        latest?.updatedAt?.takeIf { it.isNotBlank() }
                    ).joinToString(" · "),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
                Button(
                    onClick = if (appUpdate.readyToInstall) onInstallUpdate else onDownloadUpdate,
                    enabled = !appUpdate.downloading,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        when {
                            appUpdate.downloading -> "下载中"
                            appUpdate.readyToInstall -> "安装"
                            else -> "下载更新"
                        }
                    )
                }
            }
        }
    }
}

private fun installDownloadedApk(context: Context, filePath: String) {
    val apk = File(filePath)
    if (!apk.exists()) {
        Toast.makeText(context, "安装包不存在，请重新下载", Toast.LENGTH_SHORT).show()
        return
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !context.packageManager.canRequestPackageInstalls()) {
        context.startActivity(
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                data = Uri.parse("package:${context.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        )
        Toast.makeText(context, "请允许安装未知来源应用后再点安装", Toast.LENGTH_LONG).show()
        return
    }

    val uri = FileProvider.getUriForFile(
        context,
        "${context.packageName}.fileprovider",
        apk
    )
    context.startActivity(
        Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    )
}

private class TerminalAndroidBridge(
    private val context: Context,
    private val onResize: (Int, Int, Boolean) -> Unit,
    private val onScrollAtBottom: (Boolean) -> Unit,
    private val onTuiDetected: () -> Unit,
    private val onReaderCommand: (String) -> Unit,
    private val onDebug: (String) -> Unit
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var lastCols = 0
    private var lastRows = 0
    private var lastResizeAt = 0L

    @JavascriptInterface
    fun reportSize(cols: Int, rows: Int, reason: String?) {
        if (cols < 10 || rows < 4) return
        val now = System.currentTimeMillis()
        val changed = cols != lastCols || rows != lastRows
        val force = reason?.contains("init", ignoreCase = true) == true ||
            reason?.contains("setRenderMode", ignoreCase = true) == true
        if (!changed && !force) return
        if (!force && now - lastResizeAt < 350L) return
        lastCols = cols
        lastRows = rows
        lastResizeAt = now
        onDebug("WV_REPORT_SIZE cols=$cols rows=$rows reason=${reason.orEmpty()} force=$force")
        onResize(cols, rows, force)
    }

    @JavascriptInterface
    fun reportScrollAtBottom(atBottom: Boolean) {
        mainHandler.post {
            onScrollAtBottom(atBottom)
        }
    }

    @JavascriptInterface
    fun reportTuiDetected() {
        mainHandler.post {
            onTuiDetected()
        }
    }

    @JavascriptInterface
    fun copyReaderText(text: String?) {
        val value = text.orEmpty()
        if (value.isBlank()) return
        mainHandler.post {
            val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(ClipData.newPlainText("TTY1", value))
            Toast.makeText(context, "已复制", Toast.LENGTH_SHORT).show()
        }
    }

    @JavascriptInterface
    fun sendReaderCommand(command: String?) {
        val value = command.orEmpty().trim()
        if (value.isBlank()) return
        mainHandler.post {
            onReaderCommand(value)
        }
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun TerminalWebView(
    sessionId: String?,
    output: String,
    outputVersion: Long,
    outputEncoding: String,
    terminalDelta: SharedFlow<TerminalDeltaBatch>,
    desktopCols: Int,
    desktopRows: Int,
    fontScale: Float,
    copyMode: Boolean,
    scrollToBottomRequest: Long,
    onTerminalResize: (Int, Int, Boolean) -> Unit,
    onScrollAtBottom: (Boolean) -> Unit,
    onTuiDetected: () -> Unit,
    onReaderCommand: (String) -> Unit,
    onDebug: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    var webView by remember { mutableStateOf<WebView?>(null) }
    var pageReady by remember(sessionId) { mutableStateOf(false) }
    // Track the output that was last fully rendered (for session switch / replay detection)
    var lastFullRendered by remember(sessionId) { mutableStateOf("") }
    var lastFullRenderedVersion by remember(sessionId) { mutableStateOf(0L) }
    var lastAppliedDeltaVersion by remember(sessionId) { mutableStateOf(0L) }
    var pendingFullRender by remember(sessionId) { mutableStateOf<Triple<String, Long, String>?>(null) }
    val bridge = remember(sessionId) {
        TerminalAndroidBridge(
            context = context,
            onResize = onTerminalResize,
            onScrollAtBottom = onScrollAtBottom,
            onTuiDetected = onTuiDetected,
            onReaderCommand = onReaderCommand,
            onDebug = onDebug
        )
    }

    LaunchedEffect(sessionId) {
        onDebug("WV_INIT sid=${sessionId?.take(8)}")
    }

    LaunchedEffect(copyMode, pageReady, webView) {
        if (pageReady && webView != null) {
            webView?.evaluateJavascript("window.termsyncSetSelectionMode(${if (copyMode) "true" else "false"});") { result ->
                onDebug("WV_COPY_MODE mode=$copyMode result=$result")
            }
        }
    }

    LaunchedEffect(scrollToBottomRequest, pageReady, webView) {
        if (!pageReady || webView == null || scrollToBottomRequest == 0L) return@LaunchedEffect
        webView?.evaluateJavascript("window.termsyncScrollToBottom && window.termsyncScrollToBottom();") {
            onDebug("WV_SCROLL_BOTTOM request=$scrollToBottomRequest result=$it")
        }
    }

    LaunchedEffect(fontScale, desktopCols, desktopRows, pageReady, webView) {
        if (!pageReady || webView == null) return@LaunchedEffect
        webView?.evaluateJavascript(
            "window.termsyncSetRenderMode ? window.termsyncSetRenderMode(\"desktop-mirror\", ${fontScale}, $desktopCols, $desktopRows) : \"NO_RENDER_MODE\";"
        ) { result ->
            onDebug("WV_RENDER_MODE renderedCells=true fontScale=$fontScale result=$result")
        }
        listOf(0L, 120L, 400L).forEach { delayMs ->
            launch {
                delay(delayMs)
                webView?.evaluateJavascript("window.termsyncEnsureLayout && window.termsyncEnsureLayout(\"nativeRenderMode.$delayMs\")", null)
            }
        }
    }

    // Delta streaming: collect batched deltas and push directly to WebView
    // This bypasses Compose recomposition entirely for high-frequency updates
    LaunchedEffect(sessionId, pageReady, webView) {
        if (!pageReady || webView == null) return@LaunchedEffect
        val activeSessionId = sessionId ?: return@LaunchedEffect
        onDebug("WV_DELTA_COLLECTOR started sid=${activeSessionId.take(8)}")
        terminalDelta.collect { batchedDelta ->
            val wv = webView ?: return@collect
            if (batchedDelta.sessionId != activeSessionId) return@collect
            if (batchedDelta.version <= lastAppliedDeltaVersion) return@collect
            val b64 = batchedDelta.data.toJsBase64()
            val result = wv.applyTerminalPayloadBase64(
                base64 = b64,
                mode = "append",
                encoding = batchedDelta.encoding
            )
            if (result.contains("OK")) {
                lastAppliedDeltaVersion = batchedDelta.version
            }
            onDebug("WV_APPEND_RESULT version=${batchedDelta.version} result=$result")
        }
    }

    LaunchedEffect(output, outputVersion, pageReady, webView) {
        if (!pageReady || webView == null) return@LaunchedEffect
        if (output.isEmpty()) return@LaunchedEffect
        if (output == lastFullRendered && outputVersion == lastFullRenderedVersion) return@LaunchedEffect
        delay(220)
        if (outputVersion <= lastAppliedDeltaVersion) return@LaunchedEffect
        pendingFullRender = Triple(output, outputVersion, outputEncoding)
    }

    LaunchedEffect(sessionId, pageReady, webView, pendingFullRender) {
        if (!pageReady || webView == null) return@LaunchedEffect
        val pending = pendingFullRender ?: return@LaunchedEffect
        val pendingOutput = pending.first
        val pendingVersion = pending.second
        val pendingEncoding = pending.third
        onDebug("WV_FULL_RENDER out.len=${pendingOutput.length} version=$pendingVersion encoding=$pendingEncoding reason=${if (lastFullRendered.isEmpty()) "initial" else "replay"}")
        val b64 = pendingOutput.toJsBase64()
        val result = webView?.applyTerminalPayloadBase64(
            base64 = b64,
            mode = "render",
            encoding = pendingEncoding
        )
        if (result?.contains("OK") == true) {
            lastFullRendered = pendingOutput
            lastFullRenderedVersion = pendingVersion
            lastAppliedDeltaVersion = maxOf(lastAppliedDeltaVersion, pendingVersion)
        }
        if (pendingFullRender == pending) {
            pendingFullRender = null
        }
        onDebug("WV_RENDER_RESULT version=$pendingVersion result=$result")
    }

    key(sessionId) {
        AndroidView(
            modifier = modifier
                .background(Color(0xFF1E1E1E))
                .border(1.dp, Color(0xFF3C3C3C), RoundedCornerShape(8.dp)),
            factory = { context ->
                onDebug("WV_FACTORY creating WebView sid=${sessionId?.take(8)}")
                WebView(context).apply {
                    layoutParams = ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT
                    )
                    addOnLayoutChangeListener { _, left, top, right, bottom, _, _, _, _ ->
                        if (pageReady) {
                            onDebug("WV_NATIVE_LAYOUT sid=${sessionId?.take(8)} px=${right - left}x${bottom - top}")
                            evaluateJavascript("window.termsyncEnsureLayout && window.termsyncEnsureLayout(\"nativeLayout\")", null)
                        }
                    }
                    setBackgroundColor(android.graphics.Color.parseColor("#1E1E1E"))
                    webChromeClient = object : WebChromeClient() {
                        override fun onConsoleMessage(consoleMessage: ConsoleMessage): Boolean {
                            val level = consoleMessage.messageLevel()?.name ?: "?"
                            val msg = consoleMessage.message() ?: ""
                            onDebug("JS_$level: $msg")
                            return true
                        }
                    }
                    webViewClient = object : WebViewClient() {
                        override fun onPageFinished(view: WebView?, url: String?) {
                            onDebug("WV_PAGE_READY sid=${sessionId?.take(8)} desktopCols=$desktopCols desktopRows=$desktopRows renderedCells=true fontScale=$fontScale")
                            view?.addJavascriptInterface(bridge, "TermsyncAndroid")
                            view?.evaluateJavascript("window.termsyncHealthCheck ? window.termsyncHealthCheck() : 'NO_HEALTH_CHECK'") { result ->
                                onDebug("WV_HEALTH: $result")
                            }
                            pageReady = true
                        }
                    }
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = false
                    settings.cacheMode = WebSettings.LOAD_NO_CACHE
                    settings.allowFileAccess = true
                    settings.allowContentAccess = false
                    settings.builtInZoomControls = false
                    settings.displayZoomControls = false
                    settings.loadsImagesAutomatically = true
                    addJavascriptInterface(bridge, "TermsyncAndroid")
                    isVerticalScrollBarEnabled = false
                    isHorizontalScrollBarEnabled = false
                    loadUrl("file:///android_asset/terminal/terminal.html")
                    webView = this
                }
            },
            update = { view ->
                webView = view
            }
        )
    }

    LaunchedEffect(sessionId) {
        if (webView != null && pageReady) {
            delay(16)
            webView?.evaluateJavascript("window.termsyncFocus();", null)
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            webView?.destroy()
            webView = null
            pageReady = false
            lastFullRendered = ""
            lastFullRenderedVersion = 0L
            lastAppliedDeltaVersion = 0L
        }
    }
}

private fun String.toJsBase64(): String {
    return Base64.encodeToString(toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
}

private const val WEBVIEW_JS_PAYLOAD_CHUNK_SIZE = 128 * 1024

private suspend fun WebView.applyTerminalPayloadBase64(
    base64: String,
    mode: String,
    encoding: String
): String {
    if (base64.length <= WEBVIEW_JS_PAYLOAD_CHUNK_SIZE) {
        val js = if (encoding == "base64+cells-json") {
            "window.termsyncRenderCellsBase64(\"$base64\");"
        } else if (mode == "append") {
            "window.termsyncAppendBase64(\"$base64\");"
        } else {
            "window.termsyncRenderBase64(\"$base64\");"
        }
        return evaluateJavascriptAwait(js)
    }

    val payloadId = "p${System.nanoTime()}"
    var offset = 0
    var result = "OK:chunk"
    while (offset < base64.length) {
        val end = minOf(offset + WEBVIEW_JS_PAYLOAD_CHUNK_SIZE, base64.length)
        val chunk = base64.substring(offset, end)
        val done = end >= base64.length
        result = evaluateJavascriptAwait(
            "window.termsyncApplyPayloadChunk(\"$payloadId\",\"$mode\",\"$encoding\",\"$chunk\",$done);"
        )
        if (!result.contains("OK")) return result
        offset = end
    }
    return result
}

private suspend fun WebView.evaluateJavascriptAwait(script: String): String =
    suspendCancellableCoroutine { continuation ->
        evaluateJavascript(script) { result ->
            if (continuation.isActive) {
                continuation.resume(result ?: "null")
            }
        }
    }

private data class SessionTaskVisual(
    val state: String,
    val label: String,
    val color: Color,
    val pulse: Boolean
)

private fun sessionTaskVisual(session: TerminalSession?, isRecentlyActive: Boolean): SessionTaskVisual {
    val state = when {
        session == null -> "idle"
        session.status == "offline" -> "offline"
        session.taskState.isNotBlank() -> session.taskState
        isRecentlyActive -> "running"
        else -> "idle"
    }
    return when (state) {
        "offline" -> SessionTaskVisual("offline", "离线", Color(0xFF9AA0A6), false)
        "running" -> SessionTaskVisual("running", "运行中", Color(0xFF59D499), true)
        "waiting_input" -> SessionTaskVisual("waiting_input", "等待输入", Color(0xFFFFC857), true)
        "completed" -> SessionTaskVisual("completed", "已完成", Color(0xFF7FC8FF), false)
        "error" -> SessionTaskVisual("error", "异常", Color(0xFFFF7A7A), false)
        else -> SessionTaskVisual("idle", if (isRecentlyActive) "运行中" else "空闲", if (isRecentlyActive) Color(0xFF59D499) else Color(0xFF9AA0A6), isRecentlyActive)
    }
}

private fun isCustomServerUrl(url: String): Boolean {
    val normalized = url.trim()
    return normalized.isNotEmpty() && normalized != DEFAULT_SERVER_URL
}
