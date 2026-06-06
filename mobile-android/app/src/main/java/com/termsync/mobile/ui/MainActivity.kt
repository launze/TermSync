package com.termsync.mobile.ui

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
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
import androidx.activity.compose.setContent
import androidx.activity.viewModels
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.LazyRow
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
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
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
import com.termsync.mobile.viewmodel.TerminalSession
import com.termsync.mobile.viewmodel.TerminalDeltaBatch
import com.termsync.mobile.viewmodel.ConnectionState
import com.termsync.mobile.viewmodel.CommandLibraryUiState
import com.termsync.mobile.viewmodel.CommandShortcut
import com.termsync.mobile.viewmodel.MainViewModel
import com.termsync.mobile.viewmodel.SpecialKey
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalContext

private const val DEFAULT_SERVER_URL = "wss://8.153.163.104:7373/ws"
enum class TerminalRenderMode {
    MobileFit,
    DesktopMirror
}

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
}

@Composable
fun TTY1App(viewModel: MainViewModel) {
    var showConnectionDialog by remember { mutableStateOf(false) }
    val connectionState by viewModel.connectionState.collectAsState()
    val sessions by viewModel.sessions.collectAsState()
    val selectedSessionId by viewModel.selectedSessionId.collectAsState()
    val terminalOutput by viewModel.terminalOutput.collectAsState()
    val terminalOutputVersion by viewModel.terminalOutputVersion.collectAsState()
    val statusMessage by viewModel.statusMessage.collectAsState()
    val replayLoading by viewModel.replayLoading.collectAsState()
    val terminalStreamStatus by viewModel.terminalStreamStatus.collectAsState()
    val serverUrl by viewModel.serverUrl.collectAsState()
    val deviceToken by viewModel.deviceToken.collectAsState()
    val deviceName by viewModel.deviceName.collectAsState()
    val isPaired by viewModel.isPaired.collectAsState()
    val pairedDesktopName by viewModel.pairedDesktopName.collectAsState()
    val commandLibrary by viewModel.commandLibrary.collectAsState()
    val selectedSession = sessions.firstOrNull { it.sessionId == selectedSessionId }
    val hasToken = deviceToken.isNotBlank()
    val canRequestRemoteTerminal = connectionState is ConnectionState.Connected && isPaired
    val activeSessionCount = sessions.count { it.taskState == "running" || it.taskState == "waiting_input" }

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
                        output = terminalOutput,
                        outputVersion = terminalOutputVersion,
                        terminalDelta = viewModel.terminalDelta,
                        replayLoading = replayLoading,
                        terminalStreamStatus = terminalStreamStatus,
                        commandLibrary = commandLibrary,
                        onSubmitCommand = { viewModel.submitCommand(it) },
                        onSendRawInput = { viewModel.sendInput(it) },
                        onToggleFavoriteCommand = { viewModel.toggleFavoriteCommand(it) },
                        onSendSpecialKey = { viewModel.sendSpecialKey(it) },
                        onRefreshTerminal = { viewModel.refreshSelectedSessionReplay() },
                        onRequestCloseSession = { viewModel.requestRemoteSessionClose(it) },
                        onTerminalResize = { cols, rows, force -> viewModel.requestSelectedSessionResize(cols, rows, force) },
                        onDebug = { msg -> viewModel.addDebugLine(msg) },
                        onClose = { viewModel.selectSession(null) }
                    )
                }

                else -> {
                    ConnectionStatusBar(connectionState)
                    HomeScreen(
                        connectionState = connectionState,
                        sessions = sessions,
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
            onServerUrlChange = viewModel::updateServerUrl,
            onDeviceTokenChange = viewModel::updateDeviceToken,
            onDeviceNameChange = viewModel::updateDeviceName,
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
                    modifier = Modifier.size(32.dp)
                ) {
                    Icon(Icons.Default.Add, contentDescription = "新建终端", modifier = Modifier.size(18.dp))
                }
                IconButton(onClick = onRefresh, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Default.Refresh, contentDescription = "刷新", modifier = Modifier.size(18.dp))
                }
                IconButton(onClick = onOpenSettings, modifier = Modifier.size(32.dp)) {
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
        modifier = Modifier.fillMaxSize(),
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
                    text = "终端 (${sessions.size})",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )
            }
        }

        if (sessions.isNotEmpty()) {
            items(sessions) { session ->
                SessionCard(session, onClick = { onSessionSelected(session.sessionId) })
            }
        }
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
    val (connectionLabel, connectionColor) = connectionStateVisual(connectionState)

    HomeSummaryBar(
        icon = Icons.Default.Verified,
        iconTint = connectionColor,
        headline = if (pairedDesktopName.isNotBlank()) pairedDesktopName else "已完成配对",
        detail = "$connectionLabel · $deviceName",
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
        modifier = Modifier.size(30.dp)
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

@OptIn(ExperimentalMaterial3Api::class)
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

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                SessionMetaChip("${session.cols}x${session.rows}")
                if (session.isOwner) {
                    SessionMetaChip("本机")
                }
                if (relativeTime.isNotBlank()) {
                    SessionMetaChip(relativeTime)
                }
                Spacer(modifier = Modifier.weight(1f))
                Icon(
                    imageVector = Icons.Default.Terminal,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(16.dp)
                )
            }
        }
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
    output: String,
    outputVersion: Long,
    terminalDelta: SharedFlow<TerminalDeltaBatch>,
    replayLoading: Boolean,
    terminalStreamStatus: String,
    commandLibrary: CommandLibraryUiState,
    onSubmitCommand: (String) -> Unit,
    onSendRawInput: (String) -> Unit,
    onToggleFavoriteCommand: (String) -> Unit,
    onSendSpecialKey: (SpecialKey) -> Unit,
    onRefreshTerminal: () -> Unit,
    onRequestCloseSession: (String) -> Unit,
    onTerminalResize: (Int, Int, Boolean) -> Unit,
    onDebug: (String) -> Unit,
    onClose: () -> Unit
) {
    var input by rememberSaveable(session?.sessionId) { mutableStateOf("") }
    var showSpecialKeysDialog by rememberSaveable(session?.sessionId) { mutableStateOf(false) }
    var showCloseSessionDialog by rememberSaveable(session?.sessionId) { mutableStateOf(false) }
    var copyMode by rememberSaveable(session?.sessionId) { mutableStateOf(false) }
    var renderModeName by rememberSaveable(session?.sessionId) { mutableStateOf(TerminalRenderMode.MobileFit.name) }
    var fontScale by rememberSaveable(session?.sessionId) { mutableStateOf(1.0f) }
    var showLayoutControls by rememberSaveable(session?.sessionId) { mutableStateOf(false) }
    var showCommandLibraryDialog by rememberSaveable(session?.sessionId) { mutableStateOf(false) }
    var showMoreMenu by remember { mutableStateOf(false) }
    var terminalAtBottom by rememberSaveable(session?.sessionId) { mutableStateOf(true) }
    var tuiHintVisible by rememberSaveable(session?.sessionId) { mutableStateOf(false) }
    var scrollToBottomRequest by rememberSaveable(session?.sessionId) { mutableStateOf(0L) }
    var sendRawMode by rememberSaveable(session?.sessionId) { mutableStateOf(false) }
    var inputHistory by rememberSaveable(session?.sessionId) { mutableStateOf(emptyList<String>()) }
    var selectedCommandSectionKey by rememberSaveable(session?.sessionId) {
        mutableStateOf(CommandPanelSection.Favorites.key)
    }
    val focusManager = LocalFocusManager.current
    val renderMode = remember(renderModeName) { TerminalRenderMode.valueOf(renderModeName) }
    fun submitCurrentInput() {
        if (input.isNotBlank()) {
            val submitted = input
            inputHistory = (listOf(submitted) + inputHistory.filterNot { it == submitted }).take(12)
            if (sendRawMode) {
                onSendRawInput(submitted)
            } else {
                onSubmitCommand(submitted)
            }
            input = ""
            focusManager.clearFocus()
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
        LaunchedEffect(maxWidth, maxHeight, showSpecialKeysDialog, copyMode, renderModeName, fontScale, showLayoutControls, showCommandLibraryDialog) {
            onDebug(
                "TV_LAYOUT max=${maxWidth.value}x${maxHeight.value}dp keysDialog=$showSpecialKeysDialog copyMode=$copyMode mode=$renderModeName fontScale=$fontScale layoutExpanded=$showLayoutControls commandDialog=$showCommandLibraryDialog"
            )
        }
        Column(
            modifier = Modifier.fillMaxSize()
        ) {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.96f)
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 8.dp, vertical = 4.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Row(
                            modifier = Modifier.weight(1f),
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            IconButton(onClick = onClose, modifier = Modifier.size(32.dp)) {
                                Icon(Icons.Default.ArrowBack, contentDescription = "返回", modifier = Modifier.size(20.dp))
                            }
                            Text(
                                text = session?.title ?: "远程终端",
                                style = MaterialTheme.typography.titleSmall,
                                fontWeight = FontWeight.SemiBold,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f)
                            )
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                            IconButton(onClick = { copyMode = !copyMode }, modifier = Modifier.size(32.dp)) {
                                Icon(
                                    Icons.Default.ContentCopy,
                                    contentDescription = if (copyMode) "退出复制模式" else "进入复制模式",
                                    modifier = Modifier.size(19.dp),
                                    tint = if (copyMode) Color(0xFF4CAF50) else MaterialTheme.colorScheme.onSurface
                                )
                            }
                            Box {
                                IconButton(onClick = { showMoreMenu = true }, modifier = Modifier.size(32.dp)) {
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
                                        text = { Text("布局与字号") },
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
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(start = 38.dp),
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
                        terminalDelta = terminalDelta,
                        desktopCols = session?.cols ?: 80,
                        desktopRows = session?.rows ?: 24,
                        renderMode = renderMode,
                        fontScale = fontScale,
                        copyMode = copyMode,
                        scrollToBottomRequest = scrollToBottomRequest,
                        onTerminalResize = onTerminalResize,
                        onScrollAtBottom = { terminalAtBottom = it },
                        onTuiDetected = { tuiHintVisible = true },
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
                if (tuiHintVisible && renderMode == TerminalRenderMode.MobileFit) {
                    Surface(
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .padding(8.dp),
                        shape = RoundedCornerShape(8.dp),
                        color = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.96f),
                        tonalElevation = 4.dp
                    ) {
                        Row(
                            modifier = Modifier.padding(start = 10.dp, end = 6.dp, top = 4.dp, bottom = 4.dp),
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = "检测到 TUI",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSecondaryContainer
                            )
                            TextButton(
                                onClick = {
                                    renderModeName = TerminalRenderMode.DesktopMirror.name
                                    tuiHintVisible = false
                                },
                                contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp),
                                modifier = Modifier.height(28.dp)
                            ) {
                                Text("镜像")
                            }
                            TextButton(
                                onClick = { tuiHintVisible = false },
                                contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp),
                                modifier = Modifier.height(28.dp)
                            ) {
                                Text("忽略")
                            }
                        }
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
                sendRawMode = sendRawMode,
                inputHistory = inputHistory,
                onToggleSendRawMode = { sendRawMode = !sendRawMode },
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
            title = { Text("布局与字号") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        TextButton(
                            onClick = { renderModeName = TerminalRenderMode.MobileFit.name },
                            modifier = Modifier.weight(1f)
                        ) {
                            Text(
                                text = "阅读流",
                                color = if (renderMode == TerminalRenderMode.MobileFit) {
                                    MaterialTheme.colorScheme.primary
                                } else {
                                    MaterialTheme.colorScheme.onSurfaceVariant
                                }
                            )
                        }
                        TextButton(
                            onClick = { renderModeName = TerminalRenderMode.DesktopMirror.name },
                            modifier = Modifier.weight(1f)
                        ) {
                            Text(
                                text = "桌面镜像",
                                color = if (renderMode == TerminalRenderMode.DesktopMirror) {
                                    MaterialTheme.colorScheme.primary
                                } else {
                                    MaterialTheme.colorScheme.onSurfaceVariant
                                }
                            )
                        }
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        TextButton(
                            onClick = { fontScale = (fontScale - 0.1f).coerceIn(0.7f, 1.6f) }
                        ) {
                            Text("A-")
                        }
                        Text(
                            text = "${(fontScale * 100).toInt()}%",
                            style = MaterialTheme.typography.titleSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        TextButton(
                            onClick = { fontScale = (fontScale + 0.1f).coerceIn(0.7f, 1.6f) }
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

@Composable
private fun MobileTerminalComposer(
    input: String,
    onInputChange: (String) -> Unit,
    onSubmit: () -> Unit,
    sendRawMode: Boolean,
    inputHistory: List<String>,
    onToggleSendRawMode: () -> Unit,
    onInsertNewline: () -> Unit,
    onHistorySelected: (String) -> Unit,
    onOpenCommandLibrary: () -> Unit,
    onToggleFavorite: () -> Unit,
    onSendSpecialKey: (SpecialKey) -> Unit,
    modifier: Modifier = Modifier
) {
    val canSubmit = input.isNotBlank()

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
                item("commands") {
                    ComposerToolChip(
                        label = "命令库",
                        selected = false,
                        onClick = onOpenCommandLibrary
                    )
                }
                item("favorite") {
                    ComposerToolChip(
                        label = "收藏",
                        selected = canSubmit,
                        enabled = canSubmit,
                        onClick = onToggleFavorite
                    )
                }
                item("mode") {
                    ComposerToolChip(
                        label = if (sendRawMode) "原始输入" else "回车执行",
                        selected = sendRawMode,
                        onClick = onToggleSendRawMode
                    )
                }
                item("newline") {
                    ComposerToolChip(
                        label = "换行",
                        selected = false,
                        onClick = onInsertNewline
                    )
                }
                items(PRIMARY_SPECIAL_KEYS, key = { it.first }) { (label, key) ->
                    ComposerToolChip(
                        label = label,
                        selected = false,
                        onClick = { onSendSpecialKey(key) }
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
                    placeholder = { Text("输入命令或 Codex 提示") },
                    minLines = 1,
                    maxLines = 5,
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Text,
                        imeAction = ImeAction.Default
                    )
                )
                Button(
                    onClick = onSubmit,
                    enabled = canSubmit,
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp),
                    modifier = Modifier.height(48.dp)
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
    onServerUrlChange: (String) -> Unit,
    onDeviceTokenChange: (String) -> Unit,
    onDeviceNameChange: (String) -> Unit,
    onRegister: () -> Unit,
    onPair: (String) -> Unit,
    onConnect: () -> Unit
) {
    var pairingCode by remember { mutableStateOf("") }
    var showAdvanced by rememberSaveable { mutableStateOf(false) }
    val displayedServerUrl = if (isCustomServerUrl(serverUrl)) serverUrl else ""
    
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("连接桌面") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(androidx.compose.foundation.rememberScrollState()),
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
                if (statusMessage.isNotBlank()) {
                    Spacer(modifier = Modifier.height(12.dp))
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
        },
        confirmButton = {
            Button(
                onClick = onConnect
            ) {
                Text("连接")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("关闭")
            }
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
    terminalDelta: SharedFlow<TerminalDeltaBatch>,
    desktopCols: Int,
    desktopRows: Int,
    renderMode: TerminalRenderMode,
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
    var pendingFullRender by remember(sessionId) { mutableStateOf<Pair<String, Long>?>(null) }
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

    LaunchedEffect(renderMode, fontScale, desktopCols, desktopRows, pageReady, webView) {
        if (!pageReady || webView == null) return@LaunchedEffect
        val modeJs = if (renderMode == TerminalRenderMode.MobileFit) "mobile-fit" else "desktop-mirror"
        webView?.evaluateJavascript(
            "window.termsyncSetRenderMode ? window.termsyncSetRenderMode(\"$modeJs\", ${fontScale}, $desktopCols, $desktopRows) : \"NO_RENDER_MODE\";"
        ) { result ->
            onDebug("WV_RENDER_MODE mode=$modeJs fontScale=$fontScale result=$result")
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
            val result = wv.evaluateJavascriptAwait("window.termsyncAppendBase64(\"$b64\");")
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
        pendingFullRender = output to outputVersion
    }

    LaunchedEffect(sessionId, pageReady, webView, pendingFullRender) {
        if (!pageReady || webView == null) return@LaunchedEffect
        val pending = pendingFullRender ?: return@LaunchedEffect
        val (pendingOutput, pendingVersion) = pending
        onDebug("WV_FULL_RENDER out.len=${pendingOutput.length} version=$pendingVersion reason=${if (lastFullRendered.isEmpty()) "initial" else "replay"}")
        val result = webView?.evaluateJavascriptAwait(
            "window.termsyncRenderBase64(\"${pendingOutput.toJsBase64()}\");"
        )
        lastFullRendered = pendingOutput
        lastFullRenderedVersion = pendingVersion
        lastAppliedDeltaVersion = maxOf(lastAppliedDeltaVersion, pendingVersion)
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
                            onDebug("WV_PAGE_READY sid=${sessionId?.take(8)} desktopCols=$desktopCols desktopRows=$desktopRows mode=${renderMode.name} fontScale=$fontScale")
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
        session.taskState.isNotBlank() -> session.taskState
        isRecentlyActive -> "running"
        else -> "idle"
    }
    return when (state) {
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
