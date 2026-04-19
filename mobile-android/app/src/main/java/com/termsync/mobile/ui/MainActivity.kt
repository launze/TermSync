package com.termsync.mobile.ui

import android.annotation.SuppressLint
import android.os.Bundle
import android.util.Base64
import android.webkit.ConsoleMessage
import android.webkit.WebChromeClient
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.view.ViewGroup
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
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredHeightIn
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
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.South
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
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
import androidx.compose.runtime.rememberCoroutineScope
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
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import com.termsync.mobile.viewmodel.TerminalSession
import com.termsync.mobile.viewmodel.TerminalDeltaBatch
import com.termsync.mobile.viewmodel.ConnectionState
import com.termsync.mobile.viewmodel.CommandLibraryUiState
import com.termsync.mobile.viewmodel.CommandShortcut
import com.termsync.mobile.viewmodel.MainViewModel
import com.termsync.mobile.viewmodel.SpecialKey
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.platform.LocalFocusManager

private const val DEFAULT_SERVER_URL = "wss://nas.smarthome2020.top:7373/ws"
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
                        onToggleFavoriteCommand = { viewModel.toggleFavoriteCommand(it) },
                        onSendSpecialKey = { viewModel.sendSpecialKey(it) },
                        onRequestCloseSession = { viewModel.requestRemoteSessionClose(it) },
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
                        onRegister = { showConnectionDialog = true },
                        onConnect = {
                            if (hasToken) viewModel.connect(serverUrl, deviceToken)
                            else showConnectionDialog = true
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
    canCreateTerminal: Boolean,
    onCreateTerminal: () -> Unit,
    onRefresh: () -> Unit,
    onOpenSettings: () -> Unit
) {
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
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "TermSync",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold
                )
                Text(
                    text = "$sessionCount 个终端",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
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
    onRegister: () -> Unit,
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
                    onRegister = onRegister,
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
    onRegister: () -> Unit,
    onConnect: () -> Unit,
    onDisconnect: () -> Unit,
    onRefresh: () -> Unit
) {
    val isConnected = connectionState is ConnectionState.Connected
    val isConnecting = connectionState is ConnectionState.Connecting
    val showCustomServerUrl = isCustomServerUrl(serverUrl)
    val detail = buildList {
        add(if (hasToken) "已注册" else "未注册")
        add(if (hasToken) "等待配对码" else "先生成 Token")
        add(deviceName)
        if (showCustomServerUrl) add("自定义服务器")
    }.joinToString(" · ")

    HomeSummaryBar(
        icon = if (hasToken) Icons.Default.Verified else Icons.Default.Smartphone,
        iconTint = MaterialTheme.colorScheme.primary,
        headline = if (hasToken) "快速开始" else "先注册手机",
        detail = detail,
        containerColor = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.52f)
    ) {
        SummaryActionButton(
            icon = Icons.Default.Settings,
            contentDescription = "设置",
            onClick = onOpenSettings
        )
        SummaryActionButton(
            icon = Icons.Default.Smartphone,
            contentDescription = if (hasToken) "重新注册" else "注册",
            onClick = onRegister
        )
        if (isConnected) {
            SummaryActionButton(
                icon = Icons.Default.Refresh,
                contentDescription = "刷新",
                onClick = onRefresh
            )
            SummaryActionButton(
                icon = Icons.Default.Close,
                contentDescription = "断开",
                onClick = onDisconnect
            )
        } else {
            SummaryActionButton(
                icon = Icons.Default.Link,
                contentDescription = if (isConnecting) "连接中" else "连接服务器",
                onClick = onConnect,
                enabled = hasToken && !isConnecting
            )
        }
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
        SummaryActionButton(
            icon = Icons.Default.Settings,
            contentDescription = "设置",
            onClick = onOpenSettings
        )
        if (isConnected) {
            SummaryActionButton(
                icon = Icons.Default.Refresh,
                contentDescription = "刷新",
                onClick = onRefresh
            )
            SummaryActionButton(
                icon = Icons.Default.Close,
                contentDescription = "断开",
                onClick = onDisconnect
            )
        } else {
            SummaryActionButton(
                icon = Icons.Default.Link,
                contentDescription = if (isConnecting) "连接中" else "连接服务器",
                onClick = onConnect,
                enabled = !isConnecting
            )
        }
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
        shape = RoundedCornerShape(14.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Surface(
                modifier = Modifier.size(34.dp),
                shape = RoundedCornerShape(10.dp),
                color = iconTint.copy(alpha = 0.14f)
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = icon,
                        contentDescription = null,
                        tint = iconTint,
                        modifier = Modifier.size(18.dp)
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
        modifier = Modifier.size(32.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            modifier = Modifier.size(18.dp)
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
    Card(
        modifier = Modifier.fillMaxWidth(),
        onClick = onClick,
        shape = RoundedCornerShape(10.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(3.dp)
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = session.title,
                        style = MaterialTheme.typography.titleSmall,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .graphicsLayer { alpha = pulseAlpha }
                            .background(
                                color = stateVisual.color,
                                shape = RoundedCornerShape(999.dp)
                            )
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = stateVisual.label,
                        style = MaterialTheme.typography.labelSmall,
                        color = stateVisual.color
                    )
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
                Text(
                    text = activityText,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = "${session.cols}x${session.rows}",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    if (session.preview.isNotBlank() && session.preview != activityText) {
                        Text(
                            text = session.preview,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
            
            Icon(
                imageVector = Icons.Default.Terminal,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier
                    .padding(start = 10.dp)
                    .size(18.dp)
            )
        }
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
    onToggleFavoriteCommand: (String) -> Unit,
    onSendSpecialKey: (SpecialKey) -> Unit,
    onRequestCloseSession: (String) -> Unit,
    onDebug: (String) -> Unit,
    onClose: () -> Unit
) {
    var input by remember { mutableStateOf("") }
    var specialKeysExpanded by rememberSaveable(session?.sessionId) { mutableStateOf(false) }
    var showCloseSessionDialog by rememberSaveable(session?.sessionId) { mutableStateOf(false) }
    var copyMode by rememberSaveable(session?.sessionId) { mutableStateOf(false) }
    var renderModeName by rememberSaveable(session?.sessionId) { mutableStateOf(TerminalRenderMode.MobileFit.name) }
    var fontScale by rememberSaveable(session?.sessionId) { mutableStateOf(1.0f) }
    var showLayoutControls by rememberSaveable(session?.sessionId) { mutableStateOf(false) }
    var showCommandLibrary by rememberSaveable(session?.sessionId) { mutableStateOf(true) }
    var selectedCommandSectionKey by rememberSaveable(session?.sessionId) {
        mutableStateOf(CommandPanelSection.Favorites.key)
    }
    val focusManager = LocalFocusManager.current
    val renderMode = remember(renderModeName) { TerminalRenderMode.valueOf(renderModeName) }
    val normalizedInput = remember(input) {
        input
            .replace("\r", "\n")
            .lines()
            .map { it.trim() }
            .filter { it.isNotBlank() }
            .joinToString(" && ")
    }
    val currentInputFavorited = remember(normalizedInput, commandLibrary.favorites) {
        normalizedInput.isNotBlank() && commandLibrary.favorites.any { it.command == normalizedInput }
    }
    
    val stateVisual = sessionTaskVisual(session, false)
    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        val terminalMinHeight = if (maxHeight > 0.dp) {
            (maxHeight * 0.42f).coerceAtLeast(220.dp)
        } else {
            220.dp
        }
        LaunchedEffect(maxWidth, maxHeight, terminalMinHeight, specialKeysExpanded, copyMode, renderModeName, fontScale, showLayoutControls) {
            onDebug(
                "TV_LAYOUT max=${maxWidth.value}x${maxHeight.value}dp termMin=${terminalMinHeight.value}dp keysExpanded=$specialKeysExpanded copyMode=$copyMode mode=$renderModeName fontScale=$fontScale layoutExpanded=$showLayoutControls"
            )
        }
        Column(
            modifier = Modifier
                .fillMaxSize()
                .imePadding()
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
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                IconButton(onClick = onClose, modifier = Modifier.size(30.dp)) {
                    Icon(Icons.Default.ArrowBack, contentDescription = "返回", modifier = Modifier.size(18.dp))
                }
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(2.dp)
                ) {
                    Text(
                        text = session?.title ?: "远程终端",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Row(
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
                            style = MaterialTheme.typography.labelSmall
                        )
                        Text(
                            text = stateVisual.label,
                            color = stateVisual.color,
                            style = MaterialTheme.typography.labelSmall
                        )
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                if (session != null) {
                    IconButton(
                        onClick = { showCloseSessionDialog = true },
                        modifier = Modifier.size(30.dp)
                    ) {
                        Icon(Icons.Default.Delete, contentDescription = "关闭终端", modifier = Modifier.size(18.dp))
                    }
                }
                IconButton(onClick = { copyMode = !copyMode }, modifier = Modifier.size(30.dp)) {
                    Icon(
                        Icons.Default.ContentCopy,
                        contentDescription = if (copyMode) "退出复制模式" else "进入复制模式",
                        modifier = Modifier.size(18.dp),
                        tint = if (copyMode) Color(0xFF4CAF50) else MaterialTheme.colorScheme.onSurface
                    )
                }
                IconButton(onClick = { showLayoutControls = !showLayoutControls }, modifier = Modifier.size(30.dp)) {
                    Icon(Icons.Default.Settings, contentDescription = "布局与字号", modifier = Modifier.size(18.dp),
                        tint = if (showLayoutControls) Color(0xFFFF9800) else MaterialTheme.colorScheme.onSurface)
                }
            }
        }
        if (session != null) {
            Text(
                text = session.activity.ifBlank {
                    session.preview.ifBlank {
                        when (stateVisual.state) {
                            "completed" -> "任务已完成"
                            "waiting_input" -> "等待输入"
                            "running" -> "正在处理终端任务"
                            "error" -> "终端任务出错"
                            else -> "等待新的输出"
                        }
                    }
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 2.dp),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
        if (terminalStreamStatus.isNotBlank() && terminalStreamStatus != "实时同步中") {
            Surface(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 8.dp, vertical = 2.dp),
                shape = RoundedCornerShape(10.dp),
                color = if (replayLoading) {
                    MaterialTheme.colorScheme.secondaryContainer
                } else {
                    MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f)
                }
            ) {
                Text(
                    text = terminalStreamStatus,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                    style = MaterialTheme.typography.labelSmall,
                    color = if (replayLoading) {
                        MaterialTheme.colorScheme.onSecondaryContainer
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    }
                )
            }
        }
        if (showLayoutControls) {
            Surface(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 8.dp, vertical = 2.dp)
                    .animateContentSize(),
                shape = RoundedCornerShape(10.dp),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 10.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        TextButton(
                            onClick = { renderModeName = TerminalRenderMode.MobileFit.name },
                            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp)
                        ) {
                            Text(
                                text = "手机适配",
                                color = if (renderMode == TerminalRenderMode.MobileFit) {
                                    MaterialTheme.colorScheme.primary
                                } else {
                                    MaterialTheme.colorScheme.onSurfaceVariant
                                },
                                style = MaterialTheme.typography.labelSmall
                            )
                        }
                        TextButton(
                            onClick = { renderModeName = TerminalRenderMode.DesktopMirror.name },
                            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp)
                        ) {
                            Text(
                                text = "桌面镜像",
                                color = if (renderMode == TerminalRenderMode.DesktopMirror) {
                                    MaterialTheme.colorScheme.primary
                                } else {
                                    MaterialTheme.colorScheme.onSurfaceVariant
                                },
                                style = MaterialTheme.typography.labelSmall
                            )
                        }
                    }
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        TextButton(
                            onClick = { fontScale = (fontScale - 0.1f).coerceIn(0.7f, 1.6f) },
                            contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp)
                        ) {
                            Text("A-", style = MaterialTheme.typography.labelSmall)
                        }
                        Text(
                            text = "${(fontScale * 100).toInt()}%",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        TextButton(
                            onClick = { fontScale = (fontScale + 0.1f).coerceIn(0.7f, 1.6f) },
                            contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp)
                        ) {
                            Text("A+", style = MaterialTheme.typography.labelSmall)
                        }
                    }
                }
            }
        }
        if (copyMode) {
            Surface(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 8.dp, vertical = 2.dp),
                shape = RoundedCornerShape(10.dp),
                color = MaterialTheme.colorScheme.tertiaryContainer
            ) {
                Text(
                    text = "复制模式已开启，可在终端区域长按后框选复制",
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onTertiaryContainer
                )
            }
        }
            Surface(
                modifier = Modifier
                    .weight(1f)
                    .requiredHeightIn(min = terminalMinHeight)
                    .fillMaxWidth()
                    .padding(horizontal = 8.dp, vertical = 4.dp),
                color = Color(0xFF1E1E1E),
                shape = RoundedCornerShape(8.dp)
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
                    onDebug = onDebug,
                    modifier = Modifier.fillMaxSize()
                )
            }
        
            Surface(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 150.dp)
                    .padding(horizontal = 8.dp, vertical = 2.dp)
                    .animateContentSize(),
                shape = RoundedCornerShape(12.dp),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 6.dp, vertical = 4.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = if (specialKeysExpanded) "特殊键 (${ALL_SPECIAL_KEYS.size})" else "常用特殊键",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    TextButton(
                        onClick = { specialKeysExpanded = !specialKeysExpanded },
                        contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp)
                    ) {
                        Text(if (specialKeysExpanded) "收起" else "更多")
                        Icon(
                            imageVector = if (specialKeysExpanded) {
                                Icons.Default.KeyboardArrowUp
                            } else {
                                Icons.Default.KeyboardArrowDown
                            },
                            contentDescription = null,
                            modifier = Modifier.size(16.dp)
                        )
                    }
                }
                    if (specialKeysExpanded) {
                        FlowRow(
                            modifier = Modifier.fillMaxWidth(),
                            maxItemsInEachRow = 4,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            ALL_SPECIAL_KEYS.forEach { (label, key) ->
                                SpecialKeyButton(label) { onSendSpecialKey(key) }
                            }
                        }
                    } else {
                        LazyRow(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            contentPadding = PaddingValues(horizontal = 2.dp)
                        ) {
                            items(PRIMARY_SPECIAL_KEYS) { (label, key) ->
                                SpecialKeyButton(label) { onSendSpecialKey(key) }
                            }
                        }
                    }
                }
            }

            CommandLibraryPanel(
                library = commandLibrary,
                selectedSectionKey = selectedCommandSectionKey,
                expanded = showCommandLibrary,
                onToggleExpanded = { showCommandLibrary = !showCommandLibrary },
                onSectionSelected = { selectedCommandSectionKey = it },
                onCommandSelected = { shortcut -> input = shortcut.command }
            )
            
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 8.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                OutlinedTextField(
                    value = input,
                    onValueChange = { input = it },
                    modifier = Modifier.weight(1f),
                    placeholder = { Text("输入命令，或点上方预设") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text),
                    keyboardActions = KeyboardActions(onDone = {
                        if (input.isNotBlank()) {
                            onSubmitCommand(input)
                            input = ""
                            focusManager.clearFocus()
                        }
                    })
                )
                TextButton(
                    onClick = {
                        if (normalizedInput.isNotBlank()) {
                            onToggleFavoriteCommand(normalizedInput)
                        }
                    },
                    enabled = normalizedInput.isNotBlank()
                ) {
                    Text(if (currentInputFavorited) "已收藏" else "收藏")
                }
                Button(onClick = {
                    onSubmitCommand(input)
                    input = ""
                    focusManager.clearFocus()
                }, enabled = input.isNotBlank()) {
                    Icon(Icons.Default.Send, contentDescription = "发送", modifier = Modifier.size(18.dp))
                }
            }
        }
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

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun CommandLibraryPanel(
    library: CommandLibraryUiState,
    selectedSectionKey: String,
    expanded: Boolean,
    onToggleExpanded: () -> Unit,
    onSectionSelected: (String) -> Unit,
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
                    text = "点一下把命令填入输入框，再点发送",
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
                        !hasToken -> "先注册并完成配对"
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
                        !hasToken -> "先在设置里注册手机，再输入桌面端生成的 6 位配对码。"
                        !isPaired -> "去设置里输入桌面端生成的 6 位配对码，完成一次绑定后这里就不会再提示。"
                        else -> "点击上方连接服务器，随后就能看到桌面端共享的终端。"
                    }
                    is ConnectionState.Connecting -> "请稍等，正在建立安全连接。"
                    is ConnectionState.Connected -> "去桌面端打开一个终端，手机上会自动显示在这里。"
                    is ConnectionState.Error -> "检查服务器地址、设备 Token 和证书后重试。"
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
    val displayedServerUrl = if (isCustomServerUrl(serverUrl)) serverUrl else ""
    
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("手机连接设置") },
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
                        Text("推荐流程", fontWeight = FontWeight.SemiBold)
                        Spacer(modifier = Modifier.height(4.dp))
                        Text("1. 注册手机设备", style = MaterialTheme.typography.bodySmall)
                        Text("2. 输入桌面端 6 位配对码", style = MaterialTheme.typography.bodySmall)
                        Text("3. 点击连接查看桌面终端", style = MaterialTheme.typography.bodySmall)
                    }
                }
                OutlinedTextField(
                    value = displayedServerUrl,
                    onValueChange = {
                        val trimmed = it.trim()
                        onServerUrlChange(if (trimmed.isBlank()) DEFAULT_SERVER_URL else trimmed)
                    },
                    label = { Text("服务器地址") },
                    placeholder = { Text(DEFAULT_SERVER_URL) },
                    modifier = Modifier.fillMaxWidth()
                )
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedTextField(
                    value = deviceName,
                    onValueChange = onDeviceNameChange,
                    label = { Text("手机设备名称") },
                    modifier = Modifier.fillMaxWidth()
                )
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedTextField(
                    value = deviceToken,
                    onValueChange = onDeviceTokenChange,
                    label = { Text("手机设备 Token") },
                    modifier = Modifier.fillMaxWidth()
                )
                Button(
                    onClick = onRegister,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("注册本机")
                }
                OutlinedTextField(
                    value = pairingCode,
                    onValueChange = { pairingCode = it.filter(Char::isDigit).take(6) },
                    label = { Text("桌面配对码") },
                    modifier = Modifier.fillMaxWidth(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number)
                )
                Button(
                    onClick = { onPair(pairingCode) },
                    enabled = pairingCode.length == 6,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("完成配对")
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
                onClick = onConnect,
                enabled = deviceToken.isNotBlank()
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
    onDebug: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    var webView by remember { mutableStateOf<WebView?>(null) }
    var pageReady by remember(sessionId) { mutableStateOf(false) }
    // Track the output that was last fully rendered (for session switch / replay detection)
    var lastFullRendered by remember(sessionId) { mutableStateOf("") }
    var lastFullRenderedVersion by remember(sessionId) { mutableStateOf(0L) }
    val scope = rememberCoroutineScope()

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

    LaunchedEffect(renderMode, fontScale, desktopCols, desktopRows, pageReady, webView) {
        if (!pageReady || webView == null) return@LaunchedEffect
        val modeJs = if (renderMode == TerminalRenderMode.MobileFit) "mobile-fit" else "desktop-mirror"
        webView?.evaluateJavascript(
            "window.termsyncSetRenderMode ? window.termsyncSetRenderMode(\"$modeJs\", ${fontScale}, $desktopCols, $desktopRows) : \"NO_RENDER_MODE\";"
        ) { result ->
            onDebug("WV_RENDER_MODE mode=$modeJs fontScale=$fontScale result=$result")
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
            if (batchedDelta.version <= lastFullRenderedVersion) return@collect
            val b64 = batchedDelta.data.toJsBase64()
            wv.evaluateJavascript(
                "window.termsyncAppendBase64(\"$b64\");",
                null
            )
        }
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
                    isVerticalScrollBarEnabled = false
                    isHorizontalScrollBarEnabled = false
                    loadUrl("file:///android_asset/terminal/terminal.html")
                    webView = this
                }
            },
            update = { view ->
                webView = view
                if (!pageReady) return@AndroidView
                // Full render only when output changes (session switch / replay load).
                // During streaming, _terminalOutput is NOT updated — all data goes through delta flow.
                // So this block only fires on infrequent, "big" changes.
                if (output.isNotEmpty() && (output != lastFullRendered || outputVersion != lastFullRenderedVersion)) {
                    onDebug("WV_FULL_RENDER out.len=${output.length} version=$outputVersion reason=${if (lastFullRendered.isEmpty()) "initial" else "replay"}")
                    lastFullRendered = output
                    lastFullRenderedVersion = outputVersion
                    view.evaluateJavascript(
                        "window.termsyncRenderBase64(\"${output.toJsBase64()}\");"
                    ) { result ->
                        onDebug("WV_RENDER_RESULT: $result")
                    }
                }
            }
        )
    }

    LaunchedEffect(sessionId) {
        if (webView != null && pageReady) {
            scope.launch {
                delay(16)
                webView?.evaluateJavascript("window.termsyncFocus();", null)
            }
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            webView?.destroy()
            webView = null
            pageReady = false
            lastFullRendered = ""
            lastFullRenderedVersion = 0L
        }
    }
}

private fun String.toJsBase64(): String {
    return Base64.encodeToString(toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
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
