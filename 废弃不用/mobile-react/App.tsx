import AsyncStorage from '@react-native-async-storage/async-storage';
import { Ionicons, Octicons } from '@expo/vector-icons';
import * as Clipboard from 'expo-clipboard';
import * as Device from 'expo-device';
import { StatusBar } from 'expo-status-bar';
import React from 'react';
import {
  ActivityIndicator,
  Alert,
  FlatList,
  KeyboardAvoidingView,
  Modal,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  useWindowDimensions,
  View,
} from 'react-native';
import Markdown from 'react-native-markdown-display';
import { SafeAreaProvider, useSafeAreaInsets } from 'react-native-safe-area-context';
import { WebView, type WebViewMessageEvent } from 'react-native-webview';

const DEFAULT_SERVER_URL = 'wss://8.153.163.104:7373/ws';
const STORAGE_KEY = 'tty1.mobileReact.settings.v1';
const COMMAND_LIBRARY_STORAGE_KEY = 'tty1.mobileReact.commands.v1';
const MAX_TRANSCRIPT_CHARS = 40_000;
const RECONNECT_BASE_DELAY_MS = 3_000;
const RECONNECT_MAX_DELAY_MS = 60_000;
const HEARTBEAT_INTERVAL_MS = 30_000;

type ConnectionState = 'disconnected' | 'connecting' | 'connected' | 'error';
type RenderMode = 'mobile-fit' | 'desktop-mirror';
type SendMode = 'message' | 'command';
type CommandCategory = 'ai' | 'git' | 'run' | 'test' | 'high_risk' | 'custom';

type Settings = {
  serverUrl: string;
  deviceToken: string;
  deviceName: string;
  pairedDesktopId: string;
  pairedDesktopName: string;
};

type TerminalSession = {
  sessionId: string;
  ownerId: string;
  title: string;
  cols: number;
  rows: number;
  status: string;
  taskState: string;
  activity: string;
  preview: string;
  lastActivityAt: number;
  output: string;
  outputVersion: number;
  lastOutputChunk: string;
  lastOutputKind: 'append' | 'render';
};

type ReaderBlock = {
  id: string;
  kind: 'user' | 'agent' | 'tool' | 'command' | 'status' | 'diff' | 'code';
  text: string;
};

type LocalUserMessage = {
  id: number;
  sessionId: string;
  text: string;
  outputVersion: number;
};

type WsMessage = {
  type: string;
  session_id?: string;
  payload?: any;
};

type CommandShortcut = {
  id: string;
  title: string;
  command: string;
  category: CommandCategory;
  dangerous?: boolean;
  builtIn?: boolean;
  isFavorite?: boolean;
  useCount?: number;
  lastUsedAt?: number;
  defaultRank?: number;
};

const defaultSettings: Settings = {
  serverUrl: DEFAULT_SERVER_URL,
  deviceToken: '',
  deviceName: resolveDefaultDeviceName(),
  pairedDesktopId: '',
  pairedDesktopName: '',
};

const SPECIAL_KEYS = [
  { label: 'ESC', data: '\u001B' },
  { label: 'TAB', data: '\t' },
  { label: 'Ctrl+C', data: '\u0003' },
  { label: 'Ctrl+D', data: '\u0004' },
  { label: 'Ctrl+Z', data: '\u001A' },
  { label: '↑', data: '\u001B[A' },
  { label: '↓', data: '\u001B[B' },
  { label: '←', data: '\u001B[D' },
  { label: '→', data: '\u001B[C' },
  { label: 'PgUp', data: '\u001B[5~' },
  { label: 'PgDn', data: '\u001B[6~' },
  { label: 'Home', data: '\u001B[H' },
  { label: 'End', data: '\u001B[F' },
];

const DEFAULT_COMMANDS: CommandShortcut[] = [
  { id: 'codex_default', title: 'Codex', command: 'codex', category: 'ai', builtIn: true, defaultRank: 130 },
  { id: 'codex_full_auto', title: 'Codex 自动执行', command: 'codex --full-auto', category: 'ai', builtIn: true, defaultRank: 122 },
  { id: 'claude_default', title: 'Claude', command: 'claude', category: 'ai', builtIn: true, defaultRank: 120 },
  { id: 'claude_dont_ask', title: 'Claude 免确认', command: 'claude --permission-mode dontAsk', category: 'ai', builtIn: true, defaultRank: 116 },
  { id: 'codex_danger', title: 'Codex 最大权限', command: 'codex --dangerously-bypass-approvals-and-sandbox', category: 'high_risk', builtIn: true, dangerous: true, defaultRank: 112 },
  { id: 'claude_danger', title: 'Claude 最大权限', command: 'claude --dangerously-skip-permissions', category: 'high_risk', builtIn: true, dangerous: true, defaultRank: 108 },
  { id: 'git_status', title: 'Git 状态', command: 'git status', category: 'git', builtIn: true, defaultRank: 82 },
  { id: 'git_pull', title: 'Git 拉最新', command: 'git pull --rebase', category: 'git', builtIn: true, defaultRank: 78 },
  { id: 'git_diff', title: 'Git 看改动', command: 'git diff', category: 'git', builtIn: true, defaultRank: 76 },
  { id: 'git_log', title: 'Git 最近提交', command: 'git log --oneline -n 10', category: 'git', builtIn: true, defaultRank: 72 },
  { id: 'pnpm_dev', title: 'PNPM 开发', command: 'pnpm dev', category: 'run', builtIn: true, defaultRank: 70 },
  { id: 'npm_dev', title: 'NPM 开发', command: 'npm run dev', category: 'run', builtIn: true, defaultRank: 68 },
  { id: 'cargo_run', title: 'Cargo 运行', command: 'cargo run', category: 'run', builtIn: true, defaultRank: 66 },
  { id: 'docker_up', title: 'Docker Compose 启动', command: 'docker compose up -d', category: 'run', builtIn: true, defaultRank: 62 },
  { id: 'pytest_q', title: 'Pytest', command: 'pytest -q', category: 'test', builtIn: true, defaultRank: 64 },
  { id: 'cargo_test', title: 'Cargo 测试', command: 'cargo test', category: 'test', builtIn: true, defaultRank: 62 },
  { id: 'pnpm_vitest', title: 'PNPM Vitest', command: 'pnpm vitest', category: 'test', builtIn: true, defaultRank: 60 },
  { id: 'npm_test', title: 'NPM Test', command: 'npm test', category: 'test', builtIn: true, defaultRank: 58 },
];

export default function App() {
  return (
    <SafeAreaProvider>
      <TTY1App />
    </SafeAreaProvider>
  );
}

function TTY1App() {
  const insets = useSafeAreaInsets();
  const { width } = useWindowDimensions();
  const [settings, setSettings] = React.useState<Settings>(defaultSettings);
  const [settingsLoaded, setSettingsLoaded] = React.useState(false);
  const [connectionState, setConnectionState] = React.useState<ConnectionState>('disconnected');
  const [statusMessage, setStatusMessage] = React.useState('正在载入设置...');
  const [sessions, setSessions] = React.useState<TerminalSession[]>([]);
  const [selectedSessionId, setSelectedSessionId] = React.useState<string | null>(null);
  const [showPairing, setShowPairing] = React.useState(false);
  const [renderMode, setRenderMode] = React.useState<RenderMode>('mobile-fit');
  const [commandCatalog, setCommandCatalog] = React.useState<CommandShortcut[]>(DEFAULT_COMMANDS);
  const socketRef = React.useRef<WebSocket | null>(null);
  const settingsRef = React.useRef(settings);
  const manualDisconnectRef = React.useRef(false);
  const reconnectAttemptsRef = React.useRef(0);
  const reconnectTimerRef = React.useRef<ReturnType<typeof setTimeout> | null>(null);
  const heartbeatTimerRef = React.useRef<ReturnType<typeof setInterval> | null>(null);
  const sessionListRetryTimerRef = React.useRef<ReturnType<typeof setTimeout> | null>(null);
  const observedSessionIdsRef = React.useRef(new Set<string>());
  const lastResizeRef = React.useRef(new Map<string, { cols: number; rows: number; at: number }>());
  const autoConnectAttemptedRef = React.useRef(false);
  const socketGenerationRef = React.useRef(0);
  settingsRef.current = settings;

  React.useEffect(() => {
    let mounted = true;
    Promise.all([
      AsyncStorage.getItem(STORAGE_KEY),
      AsyncStorage.getItem(COMMAND_LIBRARY_STORAGE_KEY),
    ])
      .then(([raw, rawCommands]) => {
        if (!mounted) return;
        if (raw) {
          const parsed = JSON.parse(raw) as Partial<Settings>;
          const nextSettings = {
            ...defaultSettings,
            ...parsed,
            serverUrl: normalizeSavedServerUrl(parsed.serverUrl),
            deviceName: parsed.deviceName?.trim() || defaultSettings.deviceName,
          };
          settingsRef.current = nextSettings;
          setSettings(nextSettings);
        }
        if (rawCommands) {
          setCommandCatalog(mergeCommandCatalog(JSON.parse(rawCommands)));
        }
        setStatusMessage('点击连接或输入桌面配对码开始');
        setSettingsLoaded(true);
      })
      .catch((error) => setStatusMessage(`读取设置失败: ${String(error)}`));
    return () => {
      mounted = false;
    };
  }, []);

  React.useEffect(() => () => {
    if (reconnectTimerRef.current) clearTimeout(reconnectTimerRef.current);
    if (heartbeatTimerRef.current) clearInterval(heartbeatTimerRef.current);
    if (sessionListRetryTimerRef.current) clearTimeout(sessionListRetryTimerRef.current);
    socketRef.current?.close();
  }, []);

  const persistSettings = React.useCallback(async (next: Settings) => {
    settingsRef.current = next;
    setSettings(next);
    await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(next));
  }, []);

  const ensureMobileToken = React.useCallback(async (forceRefresh = false) => {
    const current = settingsRef.current;
    if (current.deviceToken && !forceRefresh) return current.deviceToken;
    setStatusMessage('正在准备手机身份...');
    const device = await registerDevice(current.serverUrl, current.deviceName || resolveDefaultDeviceName(), 'mobile');
    await persistSettings({
      ...current,
      deviceToken: device.token,
      deviceName: device.name,
      pairedDesktopId: forceRefresh ? '' : current.pairedDesktopId,
      pairedDesktopName: forceRefresh ? '' : current.pairedDesktopName,
    });
    return device.token;
  }, [persistSettings]);

  const requestSessionList = React.useCallback(() => {
    sendWs(socketRef.current, { type: 'session.list' });
  }, []);

  const clearConnectionTimers = React.useCallback(() => {
    if (heartbeatTimerRef.current) {
      clearInterval(heartbeatTimerRef.current);
      heartbeatTimerRef.current = null;
    }
    if (sessionListRetryTimerRef.current) {
      clearTimeout(sessionListRetryTimerRef.current);
      sessionListRetryTimerRef.current = null;
    }
  }, []);

  const subscribeForPreview = React.useCallback((sessionId: string, force = false) => {
    if (!sessionId) return;
    if (!force && observedSessionIdsRef.current.has(sessionId)) return;
    observedSessionIdsRef.current.add(sessionId);
    sendWs(socketRef.current, { type: 'session.subscribe', session_id: sessionId });
  }, []);

  const scheduleSessionListRetry = React.useCallback((delayMs = 1500) => {
    if (sessionListRetryTimerRef.current) clearTimeout(sessionListRetryTimerRef.current);
    sessionListRetryTimerRef.current = setTimeout(() => {
      requestSessionList();
      sessionListRetryTimerRef.current = null;
    }, delayMs);
  }, [requestSessionList]);

  const connect = React.useCallback(async () => {
    if (connectionState === 'connecting') return;
    try {
      manualDisconnectRef.current = false;
      if (reconnectTimerRef.current) {
        clearTimeout(reconnectTimerRef.current);
        reconnectTimerRef.current = null;
      }
      setConnectionState('connecting');
      setStatusMessage('正在连接桌面终端服务...');
      const token = await ensureMobileToken(false);
      observedSessionIdsRef.current.clear();
      clearConnectionTimers();
      const generation = socketGenerationRef.current + 1;
      socketGenerationRef.current = generation;
      socketRef.current?.close();
      const socket = new WebSocket(settingsRef.current.serverUrl);
      socketRef.current = socket;
      socket.onopen = () => {
        if (socketGenerationRef.current !== generation) return;
        sendWs(socket, {
          type: 'auth',
          timestamp: unixSeconds(),
          payload: { token, device_type: 'mobile' },
        });
      };
      socket.onmessage = (event) => {
        if (socketGenerationRef.current !== generation) return;
        handleWsMessage(String(event.data), {
          setConnectionState,
          setStatusMessage,
          setSessions,
          requestSessionList,
          subscribeForPreview,
          scheduleSessionListRetry,
          onConnected: () => {
            reconnectAttemptsRef.current = 0;
            if (heartbeatTimerRef.current) clearInterval(heartbeatTimerRef.current);
            heartbeatTimerRef.current = setInterval(() => {
              sendWs(socketRef.current, { type: 'heartbeat' });
            }, HEARTBEAT_INTERVAL_MS);
          },
          onSessionClosed: (sessionId) => {
            observedSessionIdsRef.current.delete(sessionId);
            if (selectedSessionId === sessionId) setSelectedSessionId(null);
          },
        });
      };
      socket.onerror = () => {
        if (socketGenerationRef.current !== generation) return;
        setConnectionState('error');
        setStatusMessage('连接失败，请检查服务器地址和网络');
      };
      socket.onclose = () => {
        if (socketGenerationRef.current !== generation) return;
        clearConnectionTimers();
        setConnectionState((prev) => (prev === 'connected' ? 'disconnected' : prev));
        if (manualDisconnectRef.current) {
          setStatusMessage('已断开连接');
          return;
        }
        const attempt = reconnectAttemptsRef.current + 1;
        reconnectAttemptsRef.current = attempt;
        const delay = Math.min(RECONNECT_BASE_DELAY_MS * 2 ** Math.min(attempt - 1, 5), RECONNECT_MAX_DELAY_MS);
        setStatusMessage(`连接已断开，${Math.round(delay / 1000)} 秒后自动重连`);
        reconnectTimerRef.current = setTimeout(() => {
          reconnectTimerRef.current = null;
          void connect();
        }, delay);
      };
    } catch (error) {
      setConnectionState('error');
      setStatusMessage(`连接失败: ${describeError(error)}`);
    }
  }, [clearConnectionTimers, connectionState, ensureMobileToken, requestSessionList, scheduleSessionListRetry, selectedSessionId, subscribeForPreview]);

  React.useEffect(() => {
    if (!settingsLoaded || !settings.deviceToken) return;
    if (autoConnectAttemptedRef.current) return;
    autoConnectAttemptedRef.current = true;
    void connect();
  }, [connect, settings.deviceToken, settingsLoaded]);

  const disconnect = React.useCallback(() => {
    manualDisconnectRef.current = true;
    reconnectAttemptsRef.current = 0;
    if (reconnectTimerRef.current) {
      clearTimeout(reconnectTimerRef.current);
      reconnectTimerRef.current = null;
    }
    socketGenerationRef.current += 1;
    clearConnectionTimers();
    socketRef.current?.close();
    socketRef.current = null;
    setConnectionState('disconnected');
    setStatusMessage('已断开连接');
  }, [clearConnectionTimers]);

  const completePairing = React.useCallback(async (code: string) => {
    const normalizedCode = code.replace(/\D/g, '').slice(0, 6);
    if (normalizedCode.length !== 6) {
      Alert.alert('配对码不完整', '请输入桌面端生成的 6 位配对码。');
      return;
    }
    try {
      const token = await ensureMobileToken(false);
      setStatusMessage('正在完成配对...');
      const result = await completePairingRequest(settingsRef.current.serverUrl, token, normalizedCode);
      await persistSettings({
        ...settingsRef.current,
        pairedDesktopId: result.desktopId,
        pairedDesktopName: result.desktopName,
      });
      setShowPairing(false);
      setStatusMessage(`已绑定桌面: ${result.desktopName}`);
      await connect();
    } catch (error) {
      setStatusMessage(`配对失败: ${describeError(error)}`);
    }
  }, [connect, ensureMobileToken, persistSettings]);

  const selectedSession = sessions.find((session) => session.sessionId === selectedSessionId) ?? null;
  const sortedSessions = React.useMemo(() => sortSessions(sessions), [sessions]);

  const selectSession = React.useCallback((sessionId: string) => {
    setSelectedSessionId(sessionId);
    subscribeForPreview(sessionId, true);
    sendWs(socketRef.current, { type: 'terminal.replay_request', session_id: sessionId });
  }, [subscribeForPreview]);

  const sendInput = React.useCallback((sessionId: string, data: string) => {
    sendWs(socketRef.current, {
      type: 'terminal.input',
      session_id: sessionId,
      payload: { data },
    });
  }, [connectionState]);

  const createRemoteSession = React.useCallback(() => {
    const desktopId = settingsRef.current.pairedDesktopId;
    if (!desktopId) {
      setShowPairing(true);
      return;
    }
    sendWs(socketRef.current, {
      type: 'session.create_request',
      payload: { desktop_id: desktopId, title: 'Termsync Mobile' },
    });
    setStatusMessage('已请求桌面新建终端');
    scheduleSessionListRetry(2500);
  }, [scheduleSessionListRetry]);

  const refreshSelectedSessionReplay = React.useCallback((sessionId: string) => {
    setStatusMessage('正在刷新终端回放...');
    subscribeForPreview(sessionId, true);
    sendWs(socketRef.current, { type: 'terminal.replay_request', session_id: sessionId });
  }, [subscribeForPreview]);

  const closeRemoteSession = React.useCallback((sessionId: string) => {
    sendWs(socketRef.current, { type: 'session.close_request', session_id: sessionId });
    setStatusMessage('已请求桌面关闭终端');
    setSelectedSessionId(null);
    scheduleSessionListRetry(1000);
  }, [scheduleSessionListRetry]);

  const requestResize = React.useCallback((sessionId: string, cols: number, rows: number, force = false) => {
    if (connectionState !== 'connected' || cols < 10 || rows < 4) return;
    const now = Date.now();
    const prev = lastResizeRef.current.get(sessionId);
    if (!force && prev && prev.cols === cols && prev.rows === rows) return;
    if (!force && prev && now - prev.at < 350 && Math.abs(prev.cols - cols) <= 1 && Math.abs(prev.rows - rows) <= 1) return;
    lastResizeRef.current.set(sessionId, { cols, rows, at: now });
    sendWs(socketRef.current, {
      type: 'terminal.resize',
      session_id: sessionId,
      payload: { cols, rows },
    });
  }, []);

  const persistCommandCatalog = React.useCallback(async (next: CommandShortcut[]) => {
    setCommandCatalog(next);
    await AsyncStorage.setItem(COMMAND_LIBRARY_STORAGE_KEY, JSON.stringify(next.filter((item) => !item.builtIn || item.isFavorite || item.useCount)));
  }, []);

  const recordCommandUsage = React.useCallback((command: string) => {
    const normalized = normalizeCommand(command);
    if (!normalized) return;
    const now = Date.now();
    const next = upsertCommandUsage(commandCatalog, normalized, now);
    void persistCommandCatalog(next);
  }, [commandCatalog, persistCommandCatalog]);

  const toggleFavoriteCommand = React.useCallback((command: string) => {
    const normalized = normalizeCommand(command);
    if (!normalized) return;
    void persistCommandCatalog(toggleCommandFavorite(commandCatalog, normalized));
  }, [commandCatalog, persistCommandCatalog]);

  return (
    <View style={styles.root}>
      <StatusBar style="light" />
      {selectedSession ? (
        <SessionScreen
          session={selectedSession}
          renderMode={renderMode}
          commandCatalog={commandCatalog}
          onRenderModeChange={setRenderMode}
          connectionState={connectionState}
          onBack={() => setSelectedSessionId(null)}
          onSendInput={(data) => sendInput(selectedSession.sessionId, data)}
          onRefresh={() => refreshSelectedSessionReplay(selectedSession.sessionId)}
          onCloseSession={() => closeRemoteSession(selectedSession.sessionId)}
          onResize={(cols, rows, force) => requestResize(selectedSession.sessionId, cols, rows, force)}
          onRecordCommand={recordCommandUsage}
          onToggleFavoriteCommand={toggleFavoriteCommand}
        />
      ) : (
        <View style={[styles.safe, { paddingTop: insets.top }]}>
          <HomeHeader
            connectionState={connectionState}
            statusMessage={statusMessage}
            sessionCount={sessions.length}
            onConnect={connect}
            onDisconnect={disconnect}
            onPair={() => setShowPairing(true)}
            onCreateSession={createRemoteSession}
            onRefresh={requestSessionList}
          />
          <SessionList
            sessions={sortedSessions}
            selectedSessionId={selectedSessionId}
            onSelect={selectSession}
            width={width}
          />
        </View>
      )}
      <PairingModal
        visible={showPairing}
        settings={settings}
        statusMessage={statusMessage}
        bottomInset={insets.bottom}
        onClose={() => setShowPairing(false)}
        onSettingsChange={(next) => void persistSettings(next)}
        onPair={completePairing}
        onRefreshIdentity={() => ensureMobileToken(true).catch((error) => setStatusMessage(describeError(error)))}
      />
    </View>
  );
}

function HomeHeader(props: {
  connectionState: ConnectionState;
  statusMessage: string;
  sessionCount: number;
  onConnect: () => void;
  onDisconnect: () => void;
  onPair: () => void;
  onCreateSession: () => void;
  onRefresh: () => void;
}) {
  const connected = props.connectionState === 'connected';
  const connecting = props.connectionState === 'connecting';
  return (
    <View style={styles.homeHeader}>
      <View style={styles.homeTitleRow}>
        <View>
          <Text style={styles.appTitle}>Termsync</Text>
          <View style={styles.statusInline}>
            <StatusDot state={props.connectionState} />
            <Text style={styles.statusLabel}>{connectionLabel(props.connectionState)}</Text>
          </View>
        </View>
        <View style={styles.headerActions}>
          <IconButton name="link" onPress={props.onPair} />
          <IconButton name="add" onPress={props.onCreateSession} disabled={!connected} />
          <IconButton name="refresh" onPress={props.onRefresh} disabled={!connected} />
          <IconButton
            name={connected || connecting ? 'stop-circle' : 'play'}
            onPress={connected || connecting ? props.onDisconnect : props.onConnect}
          />
        </View>
      </View>
      <View style={styles.summaryPanel}>
        <View>
          <Text style={styles.summaryTitle}>{props.sessionCount > 0 ? `${props.sessionCount} 个桌面终端` : '等待桌面终端'}</Text>
          <Text style={styles.summaryText} numberOfLines={2}>{props.statusMessage}</Text>
        </View>
      </View>
    </View>
  );
}

function SessionList(props: {
  sessions: TerminalSession[];
  selectedSessionId: string | null;
  width: number;
  onSelect: (sessionId: string) => void;
}) {
  if (props.sessions.length === 0) {
    return (
      <View style={styles.emptyWrap}>
        <Octicons name="terminal" size={44} color={colors.muted} />
        <Text style={styles.emptyTitle}>还没有可阅读的终端</Text>
        <Text style={styles.emptyText}>连接后，桌面端的 Codex、Claude 或 shell 会话会按活跃程度显示在这里。</Text>
      </View>
    );
  }
  return (
    <FlatList
      data={props.sessions}
      keyExtractor={(item) => item.sessionId}
      contentContainerStyle={styles.sessionListContent}
      renderItem={({ item, index }) => (
        <SessionRow
          session={item}
          selected={item.sessionId === props.selectedSessionId}
          first={index === 0}
          last={index === props.sessions.length - 1}
          onPress={() => props.onSelect(item.sessionId)}
        />
      )}
    />
  );
}

function SessionRow(props: {
  session: TerminalSession;
  selected: boolean;
  first: boolean;
  last: boolean;
  onPress: () => void;
}) {
  const visual = taskVisual(props.session);
  return (
    <Pressable
      onPress={props.onPress}
      style={({ pressed }) => [
        styles.sessionRow,
        props.first && styles.sessionRowFirst,
        props.last && styles.sessionRowLast,
        props.selected && styles.sessionRowSelected,
        pressed && styles.pressed,
      ]}
    >
      <View style={styles.avatar}>
        <Octicons name="terminal" size={22} color={visual.color} />
        <View style={[styles.avatarBadge, { backgroundColor: visual.color }]} />
      </View>
      <View style={styles.sessionContent}>
        <View style={styles.sessionTitleRow}>
          <Text style={styles.sessionTitle} numberOfLines={1}>{props.session.title || 'Terminal'}</Text>
          <Text style={styles.relativeTime}>{formatRelativeTime(props.session.lastActivityAt)}</Text>
        </View>
        <View style={styles.sessionMetaRow}>
          <StatusDot state={visual.state} />
          <Text style={[styles.sessionMeta, { color: visual.color }]}>{visual.label}</Text>
          <Text style={styles.sessionMeta}> {props.session.cols}x{props.session.rows}</Text>
        </View>
        <Text style={styles.previewText} numberOfLines={2}>
          {props.session.activity || props.session.preview || extractPreview(props.session.output) || '等待输出'}
        </Text>
      </View>
    </Pressable>
  );
}

function SessionScreen(props: {
  session: TerminalSession;
  renderMode: RenderMode;
  commandCatalog: CommandShortcut[];
  connectionState: ConnectionState;
  onRenderModeChange: (mode: RenderMode) => void;
  onBack: () => void;
  onSendInput: (data: string) => void;
  onRefresh: () => void;
  onCloseSession: () => void;
  onResize: (cols: number, rows: number, force?: boolean) => void;
  onRecordCommand: (command: string) => void;
  onToggleFavoriteCommand: (command: string) => void;
}) {
  const insets = useSafeAreaInsets();
  const { width, height } = useWindowDimensions();
  const [sendMode, setSendMode] = React.useState<SendMode>('message');
  const [copyMode, setCopyMode] = React.useState(false);
  const [fontScale, setFontScale] = React.useState(1);
  const [layoutOpen, setLayoutOpen] = React.useState(false);
  const [terminalAtBottom, setTerminalAtBottom] = React.useState(true);
  const [scrollToBottomRequest, setScrollToBottomRequest] = React.useState(0);
  const [tuiHintVisible, setTuiHintVisible] = React.useState(false);
  const [localUserMessages, setLocalUserMessages] = React.useState<LocalUserMessage[]>([]);
  const localUserMessageIdRef = React.useRef(0);

  React.useEffect(() => {
    setLocalUserMessages([]);
    localUserMessageIdRef.current = 0;
  }, [props.session.sessionId]);

  React.useEffect(() => {
    const cols = Math.max(40, Math.floor((width - 24) / 7.2));
    const rows = Math.max(12, Math.floor((height - insets.top - insets.bottom - 190) / 17));
    props.onResize(cols, rows);
  }, [height, insets.bottom, insets.top, props, width]);

  const send = React.useCallback((text: string) => {
    if (sendMode === 'message') {
      const prompt = text.trim();
      if (prompt) {
        const id = localUserMessageIdRef.current + 1;
        localUserMessageIdRef.current = id;
        setLocalUserMessages((prev) => [...prev, { id, sessionId: props.session.sessionId, text: prompt, outputVersion: props.session.outputVersion }].slice(-24));
      }
      props.onSendInput(buildTuiSubmitPayload(text));
    } else {
      const command = normalizeCommand(text);
      props.onRecordCommand(command);
      props.onSendInput(`${command}\r`);
    }
  }, [props, sendMode]);

  const confirmClose = React.useCallback(() => {
    Alert.alert('关闭桌面终端', '会请求桌面端关闭当前终端，会话输出也会从列表中移除。', [
      { text: '取消', style: 'cancel' },
      { text: '关闭', style: 'destructive', onPress: props.onCloseSession },
    ]);
  }, [props.onCloseSession]);

  return (
    <View style={[styles.safe, { paddingTop: insets.top }]}>
      <View style={styles.chatHeader}>
        <View style={styles.chatHeaderTop}>
          <View style={styles.chatTitleGroup}>
            <IconButton name="arrow-back" onPress={props.onBack} compact />
            <Text style={styles.chatTitle} numberOfLines={1}>{props.session.title || '远程终端'}</Text>
          </View>
          <View style={styles.headerActions}>
            <IconButton name="copy-outline" onPress={() => setCopyMode((value) => !value)} active={copyMode} compact />
            <IconButton name="refresh" onPress={props.onRefresh} disabled={props.connectionState !== 'connected'} compact />
            <IconButton name="settings-outline" onPress={() => setLayoutOpen(true)} compact />
            <IconButton name="trash-outline" onPress={confirmClose} disabled={props.connectionState !== 'connected'} compact />
          </View>
        </View>
        <View style={styles.chatStatusRow}>
          <StatusDot state={props.connectionState} />
          <Text style={[styles.statusLabel, { color: connectionColor(props.connectionState) }]}>{connectionLabel(props.connectionState)}</Text>
          <StatusDot state={taskVisual(props.session).state} />
          <Text style={[styles.statusLabel, { color: taskVisual(props.session).color }]}>{taskVisual(props.session).label}</Text>
          <Text style={styles.activityLine} numberOfLines={1}>{props.session.activity || props.session.preview || `${props.session.cols}x${props.session.rows}`}</Text>
        </View>
      </View>
      <KeyboardAvoidingView
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
        keyboardVerticalOffset={Platform.OS === 'ios' ? insets.top : 0}
        style={styles.chatBody}
      >
        <View style={styles.terminalStage}>
          <TerminalWebPreview
            session={props.session}
            output={props.session.output}
            outputVersion={props.session.outputVersion}
            lastOutputChunk={props.session.lastOutputChunk}
            lastOutputKind={props.session.lastOutputKind}
            localUserMessages={localUserMessages}
            renderMode={props.renderMode}
            fontScale={fontScale}
            copyMode={copyMode}
            scrollToBottomRequest={scrollToBottomRequest}
            onResize={(cols, rows, force) => props.onResize(cols, rows, force)}
            onScrollAtBottom={setTerminalAtBottom}
            onTuiDetected={() => setTuiHintVisible(true)}
            onReaderCommand={(command) => {
              const normalized = normalizeCommand(command);
              props.onRecordCommand(normalized);
              props.onSendInput(`${normalized}\r`);
            }}
          />
          {copyMode && (
            <View style={styles.terminalOverlay}>
              <Text style={styles.terminalOverlayText}>复制模式已开启</Text>
            </View>
          )}
          {tuiHintVisible && props.renderMode === 'mobile-fit' && (
            <View style={[styles.tuiHint, { right: 8 }]}>
              <Text style={styles.tuiHintText}>检测到 TUI</Text>
              <Pressable
                style={styles.tuiHintButton}
                onPress={() => {
                  props.onRenderModeChange('desktop-mirror');
                  setTuiHintVisible(false);
                }}
              >
                <Text style={styles.tuiHintButtonText}>镜像</Text>
              </Pressable>
              <Pressable style={styles.tuiHintButton} onPress={() => setTuiHintVisible(false)}>
                <Text style={styles.tuiHintButtonText}>忽略</Text>
              </Pressable>
            </View>
          )}
          {!terminalAtBottom && (
            <Pressable style={styles.scrollBottomButton} onPress={() => setScrollToBottomRequest((value) => value + 1)}>
              <Ionicons name="chevron-down" size={24} color={colors.text} />
            </Pressable>
          )}
        </View>
        <Composer
          sendMode={sendMode}
          commandCatalog={props.commandCatalog}
          onSendModeChange={setSendMode}
          onSend={send}
          onRunCommand={(command) => {
            const normalized = normalizeCommand(command);
            props.onRecordCommand(normalized);
            props.onSendInput(`${normalized}\r`);
          }}
          onSendRaw={props.onSendInput}
          onToggleFavoriteCommand={props.onToggleFavoriteCommand}
          bottomInset={insets.bottom}
        />
      </KeyboardAvoidingView>
      <LayoutModal
        visible={layoutOpen}
        renderMode={props.renderMode}
        fontScale={fontScale}
        onClose={() => setLayoutOpen(false)}
        onRenderModeChange={props.onRenderModeChange}
        onFontScaleChange={setFontScale}
      />
    </View>
  );
}

function ReaderList(props: { blocks: ReaderBlock[] }) {
  const data = props.blocks.length > 0 ? props.blocks : [{ id: 'empty', kind: 'status' as const, text: '等待终端输出...' }];
  return (
    <FlatList
      data={data}
      inverted
      keyExtractor={(item) => item.id}
      keyboardShouldPersistTaps="handled"
      maintainVisibleContentPosition={{ minIndexForVisible: 1, autoscrollToTopThreshold: 50 }}
      contentContainerStyle={styles.readerContent}
      renderItem={({ item }) => <ReaderBlockView block={item} />}
    />
  );
}

function ReaderBlockView({ block }: { block: ReaderBlock }) {
  const config = blockVisual(block.kind);
  if (block.kind === 'agent') {
    return (
      <View style={styles.agentMessage}>
        <Markdown style={markdownStyles}>{block.text}</Markdown>
      </View>
    );
  }
  if (block.kind === 'user') {
    return (
      <View style={styles.userMessageWrap}>
        <View style={styles.userMessage}>
          <Text style={styles.userMessageText}>{block.text}</Text>
        </View>
      </View>
    );
  }
  return (
    <View style={[styles.toolBlock, { borderLeftColor: config.color }]}>
      <View style={styles.toolHeader}>
        <Octicons name={config.icon as any} size={15} color={config.color} />
        <Text style={[styles.toolTitle, { color: config.color }]}>{config.label}</Text>
      </View>
      <Text style={block.kind === 'code' || block.kind === 'command' || block.kind === 'diff' ? styles.monoText : styles.toolText}>
        {block.text}
      </Text>
    </View>
  );
}

function TerminalTranscript({ output }: { output: string }) {
  return (
    <ScrollView style={styles.terminalPane} contentContainerStyle={styles.terminalContent}>
      <Text selectable style={styles.terminalText}>{stripAnsi(output) || '等待终端输出...'}</Text>
    </ScrollView>
  );
}

function TerminalWebPreview(props: {
  session: TerminalSession;
  output: string;
  outputVersion: number;
  lastOutputChunk: string;
  lastOutputKind: 'append' | 'render';
  localUserMessages: LocalUserMessage[];
  renderMode: RenderMode;
  fontScale: number;
  copyMode: boolean;
  scrollToBottomRequest: number;
  onResize: (cols: number, rows: number, force?: boolean) => void;
  onScrollAtBottom: (atBottom: boolean) => void;
  onTuiDetected: () => void;
  onReaderCommand: (command: string) => void;
}) {
  const webRef = React.useRef<WebView>(null);
  const [ready, setReady] = React.useState(false);
  const lastAppliedVersionRef = React.useRef(0);
  const lastResizeReportRef = React.useRef({ cols: 0, rows: 0, at: 0 });
  const lastLocalUserMessageIdRef = React.useRef(0);

  const evaluate = React.useCallback((script: string) => {
    webRef.current?.injectJavaScript(`${script};true;`);
  }, []);

  React.useEffect(() => {
    setReady(false);
    lastAppliedVersionRef.current = 0;
    lastLocalUserMessageIdRef.current = 0;
  }, [props.session.sessionId]);

  React.useEffect(() => {
    if (!ready || Platform.OS !== 'android') return;
    evaluate(
      `window.termsyncSetRenderMode && window.termsyncSetRenderMode(${JSON.stringify(props.renderMode)}, ${props.fontScale}, ${props.session.cols || 80}, ${props.session.rows || 24})`
    );
    [0, 120, 400].forEach((delayMs) => {
      setTimeout(() => evaluate(`window.termsyncEnsureLayout && window.termsyncEnsureLayout(${JSON.stringify(`rn.${delayMs}`)})`), delayMs);
    });
  }, [evaluate, props.fontScale, props.renderMode, props.session.cols, props.session.rows, ready]);

  React.useEffect(() => {
    if (!ready || Platform.OS !== 'android') return;
    evaluate(`window.termsyncSetSelectionMode && window.termsyncSetSelectionMode(${props.copyMode ? 'true' : 'false'})`);
  }, [evaluate, props.copyMode, ready]);

  React.useEffect(() => {
    if (!ready || Platform.OS !== 'android' || props.scrollToBottomRequest <= 0) return;
    evaluate('window.termsyncScrollToBottom && window.termsyncScrollToBottom()');
  }, [evaluate, props.scrollToBottomRequest, ready]);

  React.useEffect(() => {
    if (!ready || Platform.OS !== 'android') return;
    const pending = props.localUserMessages
      .filter((message) => message.sessionId === props.session.sessionId && message.id > lastLocalUserMessageIdRef.current)
      .sort((a, b) => a.id - b.id);
    if (!pending.length) return;
    pending.forEach((message) => {
      evaluate(`window.termsyncAddLocalUserMessage && window.termsyncAddLocalUserMessage(${JSON.stringify(message.id)}, ${JSON.stringify(message.text)})`);
      lastLocalUserMessageIdRef.current = Math.max(lastLocalUserMessageIdRef.current, message.id);
    });
  }, [evaluate, props.localUserMessages, props.session.sessionId, ready]);

  React.useEffect(() => {
    if (!ready || Platform.OS !== 'android') return;
    if (props.outputVersion <= lastAppliedVersionRef.current) return;
    if (lastAppliedVersionRef.current === 0 || props.lastOutputKind === 'render') {
      evaluate(`window.termsyncRender && window.termsyncRender(${JSON.stringify(props.output || '')})`);
    } else if (props.lastOutputChunk) {
      evaluate(`window.termsyncAppend && window.termsyncAppend(${JSON.stringify(props.lastOutputChunk)})`);
    }
    lastAppliedVersionRef.current = props.outputVersion;
  }, [evaluate, props.lastOutputChunk, props.lastOutputKind, props.output, props.outputVersion, ready]);

  const onMessage = React.useCallback((event: WebViewMessageEvent) => {
    try {
      const msg = JSON.parse(event.nativeEvent.data);
      if (msg.type === 'size') {
        const cols = Number(msg.cols) || 0;
        const rows = Number(msg.rows) || 0;
        const now = Date.now();
        const last = lastResizeReportRef.current;
        if (cols > 0 && rows > 0 && (cols !== last.cols || rows !== last.rows || now - last.at > 3000)) {
          lastResizeReportRef.current = { cols, rows, at: now };
          props.onResize(cols, rows, false);
        }
      } else if (msg.type === 'scroll') {
        props.onScrollAtBottom(Boolean(msg.atBottom));
      } else if (msg.type === 'tui') {
        props.onTuiDetected();
      } else if (msg.type === 'copy') {
        void Clipboard.setStringAsync(String(msg.text || ''));
      } else if (msg.type === 'command') {
        props.onReaderCommand(String(msg.command || ''));
      }
    } catch {
      // Ignore non-JSON console bridge messages.
    }
  }, [props]);

  if (Platform.OS !== 'android') {
    return <TerminalTranscript output={props.output} />;
  }

  return (
    <WebView
      key={props.session.sessionId}
      ref={webRef}
      originWhitelist={['*']}
      source={{ uri: 'file:///android_asset/terminal/terminal.html' }}
      onLoadEnd={() => setReady(true)}
      onMessage={onMessage}
      javaScriptEnabled
      domStorageEnabled={false}
      allowFileAccess
      allowFileAccessFromFileURLs
      allowUniversalAccessFromFileURLs
      mixedContentMode="always"
      setSupportMultipleWindows={false}
      showsVerticalScrollIndicator={false}
      showsHorizontalScrollIndicator={false}
      style={styles.webTerminal}
    />
  );
}

function Composer(props: {
  sendMode: SendMode;
  commandCatalog: CommandShortcut[];
  bottomInset: number;
  onSendModeChange: (mode: SendMode) => void;
  onSend: (text: string) => void;
  onRunCommand: (command: string) => void;
  onSendRaw: (data: string) => void;
  onToggleFavoriteCommand: (command: string) => void;
}) {
  const inputRef = React.useRef<TextInput>(null);
  const textRef = React.useRef('');
  const [hasText, setHasText] = React.useState(false);
  const [draftLength, setDraftLength] = React.useState(0);
  const [showCommands, setShowCommands] = React.useState(false);
  const [showKeys, setShowKeys] = React.useState(false);
  const [history, setHistory] = React.useState<string[]>([]);
  const commandSections = React.useMemo(() => buildCommandSections(props.commandCatalog), [props.commandCatalog]);

  const commit = React.useCallback(() => {
    const text = textRef.current;
    if (!text.trim()) return;
    props.onSend(text);
    setHistory((prev) => [text, ...prev.filter((item) => item !== text)].slice(0, 6));
    textRef.current = '';
    setHasText(false);
    setDraftLength(0);
    inputRef.current?.clear();
  }, [props]);

  const setDraftText = React.useCallback((text: string) => {
    textRef.current = text;
    setHasText(text.trim().length > 0);
    setDraftLength(text.length);
  }, []);

  return (
    <View style={[styles.composerWrap, { paddingBottom: Math.max(6, props.bottomInset) }]}>
      <View style={styles.composerPanel}>
        <View style={styles.composerStatusRow}>
          <View style={styles.composerStatusLeft}>
            <StatusDot state="connected" />
            <Text style={styles.composerStatusText}>
              {props.sendMode === 'message' ? '消息输入' : '命令执行'}{draftLength > 0 ? ` · ${draftLength}` : ''}
            </Text>
          </View>
          <Pressable
            style={styles.modeChip}
            onPress={() => props.onSendModeChange(props.sendMode === 'message' ? 'command' : 'message')}
          >
            <Ionicons name={props.sendMode === 'message' ? 'chatbubble-ellipses-outline' : 'terminal-outline'} size={13} color={colors.text2} />
            <Text style={styles.modeChipText}>{props.sendMode === 'message' ? '消息' : '命令'}</Text>
          </Pressable>
        </View>
        <TextInput
          ref={inputRef}
          multiline
          placeholder="输入命令或 Codex 提示"
          placeholderTextColor={colors.muted}
          style={styles.input}
          onChangeText={setDraftText}
          onSubmitEditing={commit}
          blurOnSubmit={false}
          returnKeyType="send"
        />
        <View style={styles.composerActionRow}>
          <View style={styles.composerTools}>
            <Pressable style={styles.actionButton} onPress={() => setShowCommands(true)}>
              <Ionicons name="library-outline" size={17} color={colors.text2} />
              <Text style={styles.actionButtonText}>命令</Text>
            </Pressable>
            <Pressable style={[styles.actionButton, hasText && styles.actionButtonActive]} onPress={() => props.onToggleFavoriteCommand(textRef.current)} disabled={!hasText}>
              <Ionicons name={hasText ? 'star' : 'star-outline'} size={17} color={hasText ? colors.warning : colors.text2} />
              <Text style={styles.actionButtonText}>收藏</Text>
            </Pressable>
            <Pressable style={styles.iconActionButton} onPress={() => {
              const next = `${textRef.current}\n`;
              inputRef.current?.setNativeProps({ text: next });
              setDraftText(next);
            }}>
              <Ionicons name="return-down-forward-outline" size={18} color={colors.text2} />
            </Pressable>
            <Pressable style={[styles.iconActionButton, showKeys && styles.actionButtonActive]} onPress={() => setShowKeys((value) => !value)}>
              <Ionicons name="keypad-outline" size={18} color={showKeys ? colors.accent : colors.text2} />
            </Pressable>
          </View>
          <Pressable
            onPress={commit}
            disabled={!hasText}
            style={({ pressed }) => [
              styles.sendButton,
              hasText ? styles.sendButtonActive : styles.sendButtonInactive,
              pressed && hasText && styles.pressed,
            ]}
          >
            <Ionicons name="arrow-up" size={19} color={hasText ? colors.white : colors.muted} />
          </Pressable>
        </View>
        {showKeys && (
          <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.specialKeyRow}>
            {SPECIAL_KEYS.map((item) => (
              <Pressable key={item.label} style={styles.quickKey} onPress={() => props.onSendRaw(item.data)}>
                <Text style={styles.quickKeyText}>{item.label}</Text>
              </Pressable>
            ))}
          </ScrollView>
        )}
        {history.length > 0 && (
          <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.historyRow}>
            {history.map((item) => (
              <Pressable key={item} style={styles.historyChip} onPress={() => {
                inputRef.current?.setNativeProps({ text: item });
                setDraftText(item);
              }}>
                <Text style={styles.historyChipText} numberOfLines={1}>{truncateMiddle(item.replace(/\s+/g, ' '), 32)}</Text>
              </Pressable>
            ))}
          </ScrollView>
        )}
      </View>
      <CommandLibraryModal
        visible={showCommands}
        sections={commandSections}
        onClose={() => setShowCommands(false)}
        onSelect={(command) => {
          setShowCommands(false);
          props.onRunCommand(command);
        }}
      />
    </View>
  );
}

function CommandLibraryModal(props: {
  visible: boolean;
  sections: Array<{ key: string; label: string; commands: CommandShortcut[] }>;
  onClose: () => void;
  onSelect: (command: string) => void;
}) {
  return (
    <Modal visible={props.visible} animationType="slide" transparent onRequestClose={props.onClose}>
      <View style={styles.modalBackdrop}>
        <View style={styles.commandSheet}>
          <View style={styles.sheetHandle} />
          <View style={styles.commandSheetHeader}>
            <Text style={styles.sheetTitle}>命令库</Text>
            <IconButton name="close" onPress={props.onClose} />
          </View>
          <ScrollView contentContainerStyle={styles.commandSections}>
            {props.sections.map((section) => (
              <View key={section.key} style={styles.commandSection}>
                <Text style={styles.commandSectionTitle}>{section.label}</Text>
                <View style={styles.commandGrid}>
                  {section.commands.map((command) => (
                    <Pressable
                      key={command.id}
                      style={({ pressed }) => [
                        styles.commandChip,
                        command.dangerous && styles.commandChipDanger,
                        pressed && styles.pressed,
                      ]}
                      onPress={() => props.onSelect(command.command)}
                    >
                      <Text style={styles.commandChipTitle} numberOfLines={1}>{command.title}</Text>
                      <Text style={styles.commandChipText} numberOfLines={2}>{command.command}</Text>
                    </Pressable>
                  ))}
                </View>
              </View>
            ))}
          </ScrollView>
        </View>
      </View>
    </Modal>
  );
}

function LayoutModal(props: {
  visible: boolean;
  renderMode: RenderMode;
  fontScale: number;
  onClose: () => void;
  onRenderModeChange: (mode: RenderMode) => void;
  onFontScaleChange: (scale: number) => void;
}) {
  return (
    <Modal visible={props.visible} animationType="fade" transparent onRequestClose={props.onClose}>
      <View style={styles.centerBackdrop}>
        <View style={styles.layoutDialog}>
          <Text style={styles.sheetTitle}>布局与字号</Text>
          <View style={styles.layoutModeRow}>
            {(['mobile-fit', 'desktop-mirror'] as RenderMode[]).map((mode) => (
              <Pressable
                key={mode}
                style={[styles.layoutModeButton, props.renderMode === mode && styles.layoutModeButtonActive]}
                onPress={() => props.onRenderModeChange(mode)}
              >
                <Text style={[styles.layoutModeText, props.renderMode === mode && styles.layoutModeTextActive]}>
                  {mode === 'mobile-fit' ? '阅读流' : '桌面镜像'}
                </Text>
              </Pressable>
            ))}
          </View>
          <View style={styles.fontScaleRow}>
            <Pressable style={styles.fontButton} onPress={() => props.onFontScaleChange(clamp(props.fontScale - 0.1, 0.7, 1.6))}>
              <Text style={styles.fontButtonText}>A-</Text>
            </Pressable>
            <Text style={styles.fontScaleText}>{Math.round(props.fontScale * 100)}%</Text>
            <Pressable style={styles.fontButton} onPress={() => props.onFontScaleChange(clamp(props.fontScale + 0.1, 0.7, 1.6))}>
              <Text style={styles.fontButtonText}>A+</Text>
            </Pressable>
          </View>
          <Pressable style={styles.primaryButton} onPress={props.onClose}>
            <Text style={styles.primaryButtonText}>完成</Text>
          </Pressable>
        </View>
      </View>
    </Modal>
  );
}

function PairingModal(props: {
  visible: boolean;
  settings: Settings;
  statusMessage: string;
  bottomInset: number;
  onClose: () => void;
  onSettingsChange: (settings: Settings) => void;
  onPair: (code: string) => void;
  onRefreshIdentity: () => void;
}) {
  const [code, setCode] = React.useState('');
  const [advanced, setAdvanced] = React.useState(false);
  const [draft, setDraft] = React.useState(props.settings);
  React.useEffect(() => setDraft(props.settings), [props.settings, props.visible]);
  return (
    <Modal visible={props.visible} animationType="slide" transparent onRequestClose={props.onClose}>
      <View style={styles.modalBackdrop}>
        <View style={[styles.sheet, { paddingBottom: Math.max(18, props.bottomInset + 12) }]}>
          <View style={styles.sheetHandle} />
          <Text style={styles.sheetTitle}>连接桌面</Text>
          <Text style={styles.sheetText}>在桌面端生成 6 位配对码，手机会自动准备身份并连接。</Text>
          <TextInput
            value={code}
            onChangeText={(text) => setCode(text.replace(/\D/g, '').slice(0, 6))}
            keyboardType="number-pad"
            placeholder="桌面配对码"
            placeholderTextColor={colors.muted}
            style={styles.codeInput}
          />
          <Pressable style={styles.primaryButton} onPress={() => props.onPair(code)}>
            <Text style={styles.primaryButtonText}>完成配对并连接</Text>
          </Pressable>
          <Pressable style={styles.ghostButton} onPress={() => setAdvanced(!advanced)}>
            <Text style={styles.ghostButtonText}>{advanced ? '收起高级设置' : '高级设置'}</Text>
          </Pressable>
          {advanced && (
            <View style={styles.advancedBox}>
              <LabeledInput label="服务器地址" value={draft.serverUrl} onChangeText={(serverUrl) => setDraft({ ...draft, serverUrl })} />
              <LabeledInput label="手机名称" value={draft.deviceName} onChangeText={(deviceName) => setDraft({ ...draft, deviceName })} />
              <LabeledInput label="手机身份 Token" value={draft.deviceToken} onChangeText={(deviceToken) => setDraft({ ...draft, deviceToken })} />
              <View style={styles.advancedActions}>
                <Pressable style={styles.secondaryButton} onPress={() => props.onSettingsChange({ ...draft, serverUrl: normalizeSavedServerUrl(draft.serverUrl) })}>
                  <Text style={styles.secondaryButtonText}>保存设置</Text>
                </Pressable>
                <Pressable style={styles.secondaryButton} onPress={props.onRefreshIdentity}>
                  <Text style={styles.secondaryButtonText}>重置身份</Text>
                </Pressable>
              </View>
            </View>
          )}
          <Text style={styles.modalStatus}>{props.statusMessage}</Text>
          <Pressable style={styles.closeButton} onPress={props.onClose}>
            <Text style={styles.ghostButtonText}>关闭</Text>
          </Pressable>
        </View>
      </View>
    </Modal>
  );
}

function LabeledInput(props: { label: string; value: string; onChangeText: (value: string) => void }) {
  return (
    <View style={styles.labeledInput}>
      <Text style={styles.inputLabel}>{props.label}</Text>
      <TextInput value={props.value} onChangeText={props.onChangeText} style={styles.advancedInput} placeholderTextColor={colors.muted} />
    </View>
  );
}

function IconButton(props: { name: keyof typeof Ionicons.glyphMap; onPress: () => void; disabled?: boolean; active?: boolean; compact?: boolean }) {
  return (
    <Pressable
      onPress={props.onPress}
      disabled={props.disabled}
      style={({ pressed }) => [
        styles.iconButton,
        props.compact && styles.iconButtonCompact,
        props.active && styles.iconButtonActive,
        props.disabled && styles.disabled,
        pressed && !props.disabled && styles.pressed,
      ]}
    >
      <Ionicons name={props.name} size={props.compact ? 18 : 20} color={props.disabled ? colors.muted : props.active ? colors.success : colors.text} />
    </Pressable>
  );
}

function SegmentedPill(props: { value: RenderMode; onChange: (mode: RenderMode) => void }) {
  return (
    <View style={styles.segmented}>
      {(['mobile-fit', 'desktop-mirror'] as RenderMode[]).map((mode) => (
        <Pressable
          key={mode}
          onPress={() => props.onChange(mode)}
          style={[styles.segment, props.value === mode && styles.segmentActive]}
        >
          <Text style={[styles.segmentText, props.value === mode && styles.segmentTextActive]}>{mode === 'mobile-fit' ? '阅读流' : '镜像'}</Text>
        </Pressable>
      ))}
    </View>
  );
}

function StatusDot({ state }: { state: ConnectionState | 'running' | 'waiting' | 'completed' }) {
  const color = state === 'connected' || state === 'waiting' || state === 'completed'
    ? colors.success
    : state === 'connecting' || state === 'running'
      ? colors.accent
      : state === 'error'
        ? colors.danger
        : colors.muted;
  return <View style={[styles.dot, { backgroundColor: color }]} />;
}

function handleWsMessage(
  raw: string,
  handlers: {
    setConnectionState: React.Dispatch<React.SetStateAction<ConnectionState>>;
    setStatusMessage: React.Dispatch<React.SetStateAction<string>>;
    setSessions: React.Dispatch<React.SetStateAction<TerminalSession[]>>;
    requestSessionList: () => void;
    subscribeForPreview: (sessionId: string, force?: boolean) => void;
    scheduleSessionListRetry: (delayMs?: number) => void;
    onConnected: () => void;
    onSessionClosed: (sessionId: string) => void;
  }
) {
  let msg: WsMessage;
  try {
    msg = JSON.parse(raw);
  } catch {
    return;
  }
  if (msg.type === 'auth_response') {
    if (msg.payload?.success) {
      handlers.setConnectionState('connected');
      handlers.setStatusMessage('已连接，正在同步终端列表...');
      handlers.onConnected();
      handlers.requestSessionList();
      handlers.scheduleSessionListRetry();
    } else {
      handlers.setConnectionState('error');
      handlers.setStatusMessage(msg.payload?.message || '认证失败');
    }
    return;
  }
  if (msg.type === 'session.list_res') {
    const list = Array.isArray(msg.payload?.sessions) ? msg.payload.sessions : [];
    handlers.setSessions((prev) => mergeSessionList(prev, list));
    list.forEach((snapshot: any) => {
      const sessionId = String(snapshot.session_id || snapshot.sessionId || '');
      if (sessionId) handlers.subscribeForPreview(sessionId);
    });
    handlers.setStatusMessage(list.length > 0 ? '终端列表已同步' : '桌面端还没有终端');
    if (list.length === 0) handlers.scheduleSessionListRetry(2500);
    return;
  }
  if (msg.type === 'session.state' || msg.type === 'session.create' || msg.type === 'session.update') {
    const payload = msg.payload?.snapshot || msg.payload || {};
    const session = snapshotToSession(payload, msg.session_id);
    handlers.setSessions((prev) => upsertSession(prev, session));
    handlers.subscribeForPreview(session.sessionId);
    return;
  }
  if (msg.type === 'session.close') {
    const sessionId = msg.session_id;
    if (!sessionId) return;
    handlers.onSessionClosed(sessionId);
    handlers.setSessions((prev) => prev.filter((session) => session.sessionId !== sessionId));
    handlers.setStatusMessage('终端已关闭');
    return;
  }
  if (msg.type === 'terminal.output' || msg.type === 'terminal.replay') {
    const sessionId = msg.session_id;
    const data = String(msg.payload?.data ?? '');
    if (!sessionId || !data) return;
    handlers.setSessions((prev) => prev.map((session) => {
      if (session.sessionId !== sessionId) return session;
      const output = msg.type === 'terminal.replay' ? trimOutput(data) : trimOutput(session.output + data);
      return {
        ...session,
        output,
        outputVersion: session.outputVersion + 1,
        lastOutputChunk: data,
        lastOutputKind: msg.type === 'terminal.replay' ? 'render' : 'append',
        preview: extractPreview(output),
        lastActivityAt: Date.now(),
      };
    }));
    return;
  }
  if (msg.type === 'error') {
    handlers.setStatusMessage(`[${msg.payload?.code || 'error'}] ${msg.payload?.message || '服务器错误'}`);
  }
}

function sendWs(socket: WebSocket | null, message: Record<string, any>) {
  if (!socket || socket.readyState !== WebSocket.OPEN) return;
  socket.send(JSON.stringify({ timestamp: unixSeconds(), ...message }));
}

async function registerDevice(serverUrl: string, name: string, type: 'mobile' | 'desktop') {
  const response = await postJson(`${normalizeBaseUrl(serverUrl)}/api/register`, { name, type });
  const device = response.device;
  return {
    id: String(device.id),
    name: String(device.name),
    token: String(device.token),
    type: String(device.type),
  };
}

async function completePairingRequest(serverUrl: string, token: string, code: string) {
  const response = await postJson(`${normalizeBaseUrl(serverUrl)}/api/pairing/complete`, { token, code });
  const pairing = response.pairing;
  return {
    desktopId: String(pairing.desktop_id),
    desktopName: String(pairing.desktop_name),
  };
}

async function postJson(url: string, body: Record<string, unknown>) {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(text || `HTTP ${response.status}`);
  }
  return text ? JSON.parse(text) : {};
}

function snapshotToSession(snapshot: any, fallbackId?: string): TerminalSession {
  const sessionId = String(snapshot.session_id || snapshot.sessionId || fallbackId || '');
  return {
    sessionId,
    ownerId: String(snapshot.owner_id || snapshot.ownerId || ''),
    title: String(snapshot.title || 'Terminal'),
    cols: Number(snapshot.cols || 80),
    rows: Number(snapshot.rows || 24),
    status: String(snapshot.status || 'active'),
    taskState: String(snapshot.task_state || snapshot.taskState || ''),
    activity: String(snapshot.activity || ''),
    preview: String(snapshot.preview || ''),
    lastActivityAt: Date.now(),
    output: '',
    outputVersion: 0,
    lastOutputChunk: '',
    lastOutputKind: 'render',
  };
}

function mergeSessionList(prev: TerminalSession[], snapshots: any[]): TerminalSession[] {
  const map = new Map(prev.map((session) => [session.sessionId, session]));
  for (const raw of snapshots) {
    const next = snapshotToSession(raw);
    const existing = map.get(next.sessionId);
    map.set(next.sessionId, {
      ...next,
      output: existing?.output || '',
      outputVersion: existing?.outputVersion || 0,
      lastOutputChunk: existing?.lastOutputChunk || '',
      lastOutputKind: existing?.lastOutputKind || 'render',
      lastActivityAt: existing?.lastActivityAt || next.lastActivityAt,
    });
  }
  return Array.from(map.values()).filter((session) => session.sessionId);
}

function upsertSession(prev: TerminalSession[], next: TerminalSession) {
  if (!next.sessionId) return prev;
  const found = prev.find((session) => session.sessionId === next.sessionId);
  if (!found) return [next, ...prev];
  return prev.map((session) => session.sessionId === next.sessionId ? {
    ...session,
    ...next,
    output: session.output || next.output,
    outputVersion: session.outputVersion || next.outputVersion,
    lastOutputChunk: session.lastOutputChunk || next.lastOutputChunk,
    lastOutputKind: session.lastOutputKind || next.lastOutputKind,
  } : session);
}

function parseReaderBlocks(output: string): ReaderBlock[] {
  const text = stripAnsi(output).replace(/\r/g, '\n');
  const lines = text.split('\n').map((line) => line.trimEnd());
  const blocks: ReaderBlock[] = [];
  let buffer: string[] = [];
  let kind: ReaderBlock['kind'] = 'agent';

  const flush = () => {
    const content = buffer.join('\n').trim();
    if (!content) {
      buffer = [];
      return;
    }
    blocks.push({ id: `${blocks.length}-${content.length}`, kind, text: content });
    buffer = [];
  };

  for (const line of lines) {
    const trimmed = line.trim();
    const nextKind = classifyLine(trimmed);
    if (!trimmed) {
      if (buffer.length > 0) buffer.push('');
      continue;
    }
    if (nextKind !== kind || isBlockBoundary(trimmed)) {
      flush();
      kind = nextKind;
    }
    buffer.push(line);
  }
  flush();
  return blocks.slice(-160).reverse();
}

function classifyLine(line: string): ReaderBlock['kind'] {
  if (/^(user|you|用户)\s*[:：]/i.test(line) || /^>\s/.test(line)) return 'user';
  if (/^(tool|call|running|执行|运行|bash|shell|cmd|powershell|pwsh)\b/i.test(line)) return 'tool';
  if (/^(\$|>|PS\s|C:\\|[\w.-]+@[\w.-]+[:$])/.test(line)) return 'command';
  if (/^(diff --git|@@ |\+\+\+ |--- |\+|-)/.test(line)) return 'diff';
  if (/^```/.test(line)) return 'code';
  if (/(build successful|finished|completed|done|error|failed|permission|waiting|需要|完成|失败)/i.test(line)) return 'status';
  return 'agent';
}

function isBlockBoundary(line: string) {
  return /^(user|you|assistant|tool|call|running|执行|运行)\s*[:：]/i.test(line) ||
    /^(\$|>|PS\s|diff --git|@@ |```)/.test(line);
}

function stripAnsi(input: string) {
  return input
    .replace(/\u001b\][\s\S]*?(\u0007|\u001b\\)/g, '')
    .replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, '')
    .replace(/\u001b[@-_]/g, '');
}

function extractPreview(output: string) {
  return stripAnsi(output)
    .replace(/\r/g, '\n')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(-2)
    .join(' · ')
    .slice(0, 120);
}

function clamp(value: number, min: number, max: number) {
  return Math.max(min, Math.min(max, value));
}

function truncateMiddle(text: string, maxLength: number) {
  if (text.length <= maxLength) return text;
  const keep = Math.max(2, Math.floor((maxLength - 1) / 2));
  return `${text.slice(0, keep)}…${text.slice(text.length - keep)}`;
}

function normalizeCommand(text: string) {
  return text.replace(/\r/g, '\n').split('\n').map((line) => line.trim()).filter(Boolean).join(' && ');
}

function mergeCommandCatalog(saved: unknown): CommandShortcut[] {
  const byId = new Map(DEFAULT_COMMANDS.map((item) => [item.id, item]));
  if (Array.isArray(saved)) {
    for (const raw of saved) {
      if (!raw || typeof raw !== 'object') continue;
      const item = raw as Partial<CommandShortcut>;
      const command = normalizeCommand(String(item.command || ''));
      if (!command) continue;
      const id = String(item.id || customCommandIdFor(command));
      const existing = byId.get(id);
      byId.set(id, {
        ...(existing || createCustomCommand(command)),
        id,
        title: String(item.title || existing?.title || deriveCommandTitle(command)),
        command,
        category: normalizeCommandCategory(item.category || existing?.category),
        dangerous: Boolean(item.dangerous ?? existing?.dangerous ?? isDangerousCommand(command)),
        builtIn: Boolean(item.builtIn ?? existing?.builtIn),
        isFavorite: Boolean(item.isFavorite ?? existing?.isFavorite),
        useCount: Number(item.useCount || existing?.useCount || 0),
        lastUsedAt: Number(item.lastUsedAt || existing?.lastUsedAt || 0),
        defaultRank: Number(item.defaultRank || existing?.defaultRank || 20),
      });
    }
  }
  return Array.from(byId.values()).sort(commandComparator);
}

function buildCommandSections(catalog: CommandShortcut[]) {
  const normalized = mergeCommandCatalog(catalog);
  const recommended = normalized
    .filter((item) => item.command)
    .sort((a, b) => recommendationScore(b) - recommendationScore(a))
    .slice(0, 6);
  const favorites = normalized.filter((item) => item.isFavorite).sort(commandComparator);
  const recent = normalized.filter((item) => item.lastUsedAt).sort((a, b) => Number(b.lastUsedAt || 0) - Number(a.lastUsedAt || 0)).slice(0, 8);
  const sections: Array<{ key: string; label: string; commands: CommandShortcut[] }> = [
    { key: 'recommended', label: '推荐', commands: recommended },
    { key: 'favorites', label: '收藏', commands: favorites },
    { key: 'recent', label: '最近', commands: recent },
  ];
  const labels: Record<CommandCategory, string> = {
    ai: 'AI 助手',
    git: 'Git',
    run: '运行',
    test: '测试',
    high_risk: '高权限',
    custom: '自定义',
  };
  (['ai', 'git', 'run', 'test', 'high_risk', 'custom'] as CommandCategory[]).forEach((category) => {
    const commands = normalized.filter((item) => item.category === category).sort(commandComparator);
    if (commands.length > 0) sections.push({ key: category, label: labels[category], commands });
  });
  return sections.filter((section) => section.commands.length > 0);
}

function upsertCommandUsage(catalog: CommandShortcut[], command: string, now: number) {
  const normalized = normalizeCommand(command);
  const merged = mergeCommandCatalog(catalog);
  const index = merged.findIndex((item) => item.command === normalized);
  if (index >= 0) {
    const existing = merged[index];
    merged[index] = {
      ...existing,
      useCount: Number(existing.useCount || 0) + 1,
      lastUsedAt: now,
    };
    return merged;
  }
  return [...merged, { ...createCustomCommand(normalized), useCount: 1, lastUsedAt: now }].sort(commandComparator);
}

function toggleCommandFavorite(catalog: CommandShortcut[], command: string) {
  const normalized = normalizeCommand(command);
  const merged = mergeCommandCatalog(catalog);
  const index = merged.findIndex((item) => item.command === normalized);
  if (index >= 0) {
    merged[index] = { ...merged[index], isFavorite: !merged[index].isFavorite };
    return merged;
  }
  return [...merged, { ...createCustomCommand(normalized), isFavorite: true }].sort(commandComparator);
}

function createCustomCommand(command: string): CommandShortcut {
  const normalized = normalizeCommand(command);
  return {
    id: customCommandIdFor(normalized),
    title: deriveCommandTitle(normalized),
    command: normalized,
    category: suggestCommandCategory(normalized),
    dangerous: isDangerousCommand(normalized),
    builtIn: false,
    defaultRank: 20,
  };
}

function customCommandIdFor(command: string) {
  let hash = 0;
  for (let index = 0; index < command.length; index += 1) {
    hash = ((hash << 5) - hash + command.charCodeAt(index)) | 0;
  }
  return `custom_${(hash >>> 0).toString(16)}`;
}

function deriveCommandTitle(command: string) {
  const compact = normalizeCommand(command).replace(/\s+/g, ' ');
  if (!compact) return '自定义命令';
  return compact.length <= 28 ? compact : `${compact.slice(0, 27)}...`;
}

function suggestCommandCategory(command: string): CommandCategory {
  const lower = normalizeCommand(command).toLowerCase();
  if (/^(codex|claude|gemini|chatgpt|openai)(\s|$)/.test(lower)) return 'ai';
  if (/^git(\s|$)/.test(lower)) return 'git';
  if (isDangerousCommand(lower)) return 'high_risk';
  if (/(pytest|vitest|jest|cargo test|go test|npm test|pnpm test)/.test(lower)) return 'test';
  if (/^(npm|pnpm|yarn|bun|cargo|docker|python|uv|make|\.\/)(\s|$)/.test(lower)) return 'run';
  return 'custom';
}

function isDangerousCommand(command: string) {
  const lower = normalizeCommand(command).toLowerCase();
  return [
    '--dangerously',
    '--dangerous',
    'sudo ',
    'su -',
    ' rm -rf',
    'rm -rf ',
    'remove-item -recurse -force',
    'del /f /s /q',
    'rd /s /q',
    'format ',
    'mkfs',
    'dd if=',
    'shutdown',
    'reboot',
    'halt',
    'docker system prune',
    'git clean -fd',
    'git reset --hard',
  ].some((marker) => lower.includes(marker));
}

function normalizeCommandCategory(value?: string): CommandCategory {
  return value === 'ai' || value === 'git' || value === 'run' || value === 'test' || value === 'high_risk' || value === 'custom'
    ? value
    : 'custom';
}

function commandComparator(a: CommandShortcut, b: CommandShortcut) {
  if (Boolean(a.isFavorite) !== Boolean(b.isFavorite)) return a.isFavorite ? -1 : 1;
  if (Number(a.useCount || 0) !== Number(b.useCount || 0)) return Number(b.useCount || 0) - Number(a.useCount || 0);
  if (Number(a.lastUsedAt || 0) !== Number(b.lastUsedAt || 0)) return Number(b.lastUsedAt || 0) - Number(a.lastUsedAt || 0);
  if (Number(a.defaultRank || 0) !== Number(b.defaultRank || 0)) return Number(b.defaultRank || 0) - Number(a.defaultRank || 0);
  return a.title.localeCompare(b.title);
}

function recommendationScore(command: CommandShortcut) {
  const favoriteBoost = command.isFavorite ? 260 : 0;
  const customBoost = command.builtIn ? 0 : 40;
  const usageBoost = command.useCount ? Math.log(command.useCount + 1) * 120 : 0;
  const ageHours = command.lastUsedAt ? Math.max(0, Date.now() - command.lastUsedAt) / 3_600_000 : Infinity;
  const recencyBoost = Number.isFinite(ageHours) ? Math.max(0, 180 - ageHours * 8) : 0;
  const riskPenalty = command.dangerous ? 12 : 0;
  return Number(command.defaultRank || 0) + favoriteBoost + customBoost + usageBoost + recencyBoost - riskPenalty;
}

function buildTuiSubmitPayload(text: string) {
  const normalized = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').replace(/\u001b/g, '');
  return normalized.includes('\n') ? `\u001b[200~${normalized}\u001b[201~\r` : `${normalized}\r`;
}

function sortSessions(sessions: TerminalSession[]) {
  return [...sessions].sort((a, b) => {
    const av = taskVisual(a).rank;
    const bv = taskVisual(b).rank;
    if (av !== bv) return bv - av;
    return b.lastActivityAt - a.lastActivityAt;
  });
}

function taskVisual(session: TerminalSession) {
  const state = `${session.taskState} ${session.status} ${session.activity}`.toLowerCase();
  if (/(waiting|input|permission|需要|确认)/.test(state)) return { state: 'waiting' as const, label: '等待处理', color: colors.warning, rank: 4 };
  if (/(running|busy|处理中|执行|生成)/.test(state)) return { state: 'running' as const, label: '正在运行', color: colors.accent, rank: 3 };
  if (/(done|complete|完成|success)/.test(state)) return { state: 'completed' as const, label: '已完成', color: colors.success, rank: 2 };
  return { state: 'connected' as const, label: session.status || '已连接', color: colors.success, rank: 1 };
}

function connectionColor(state: ConnectionState) {
  return state === 'connected'
    ? colors.success
    : state === 'connecting'
      ? colors.warning
      : state === 'error'
        ? colors.danger
        : colors.muted;
}

function blockVisual(kind: ReaderBlock['kind']) {
  switch (kind) {
    case 'tool': return { label: '工具调用', color: colors.accent, icon: 'tools' };
    case 'command': return { label: '命令', color: colors.warning, icon: 'terminal' };
    case 'diff': return { label: '代码变更', color: colors.success, icon: 'diff' };
    case 'code': return { label: '代码', color: colors.blue, icon: 'code-square' };
    case 'status': return { label: '状态', color: colors.muted, icon: 'info' };
    default: return { label: '输出', color: colors.muted, icon: 'comment' };
  }
}

function normalizeBaseUrl(serverUrl: string) {
  const trimmed = serverUrl.trim();
  if (!trimmed) throw new Error('Server URL is required');
  const base = trimmed.replace(/^wss:\/\//, 'https://').replace(/^ws:\/\//, 'http://');
  const wsIndex = base.indexOf('/ws');
  return (wsIndex >= 0 ? base.slice(0, wsIndex) : base).replace(/\/+$/, '');
}

function normalizeSavedServerUrl(value?: string) {
  const normalized = value?.trim();
  return normalized || DEFAULT_SERVER_URL;
}

function resolveDefaultDeviceName() {
  const model = Device.modelName || Device.deviceName || 'Mobile';
  const brand = Device.brand || '';
  return `${brand} ${model}`.trim() || 'TTY1 Mobile';
}

function formatRelativeTime(timestamp: number) {
  if (!timestamp) return '';
  const seconds = Math.max(0, Math.floor((Date.now() - timestamp) / 1000));
  if (seconds < 60) return '刚刚';
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes} 分钟前`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} 小时前`;
  return `${Math.floor(hours / 24)} 天前`;
}

function connectionLabel(state: ConnectionState) {
  switch (state) {
    case 'connected': return '已连接';
    case 'connecting': return '连接中';
    case 'error': return '连接异常';
    default: return '本地模式';
  }
}

function trimOutput(output: string) {
  return output.length <= MAX_TRANSCRIPT_CHARS ? output : output.slice(-MAX_TRANSCRIPT_CHARS);
}

function unixSeconds() {
  return Math.floor(Date.now() / 1000);
}

function describeError(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

const colors = {
  bg: '#101010',
  surface: '#171717',
  surface2: '#292929',
  surface3: '#2f2f2f',
  terminal: '#111111',
  text: '#f2f2f2',
  text2: '#cac4d0',
  muted: '#8e8e93',
  border: '#333333',
  white: '#ffffff',
  accent: '#0a84ff',
  blue: '#64d2ff',
  success: '#32d74b',
  warning: '#ffd60a',
  danger: '#ff453a',
  user: '#2c2c2e',
};

const markdownStyles = {
  body: { color: colors.text, fontSize: 15, lineHeight: 22 },
  paragraph: { marginTop: 0, marginBottom: 8 },
  code_inline: { color: colors.blue, backgroundColor: colors.surface3, fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace' },
  code_block: { color: colors.text, backgroundColor: colors.surface3, borderRadius: 8, padding: 10, fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace' },
  fence: { color: colors.text, backgroundColor: colors.surface3, borderRadius: 8, padding: 10, fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace' },
} as const;

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.bg },
  safe: { flex: 1, backgroundColor: colors.bg },
  pressed: { opacity: 0.72 },
  disabled: { opacity: 0.42 },
  dot: { width: 7, height: 7, borderRadius: 4 },
  homeHeader: { paddingHorizontal: 10, paddingTop: 6, paddingBottom: 6, backgroundColor: 'rgba(41,43,49,0.55)' },
  homeTitleRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  appTitle: { color: colors.text, fontSize: 16, fontWeight: '700', letterSpacing: 0 },
  statusInline: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  statusLabel: { color: colors.text2, fontSize: 12 },
  headerActions: { flexDirection: 'row', alignItems: 'center', gap: 2 },
  iconButton: { width: 32, height: 32, borderRadius: 16, alignItems: 'center', justifyContent: 'center', backgroundColor: 'transparent' },
  iconButtonCompact: { width: 32, height: 32, borderRadius: 16 },
  iconButtonActive: { backgroundColor: 'rgba(82,210,115,0.14)' },
  summaryPanel: { marginTop: 8, borderRadius: 8, backgroundColor: 'rgba(76,87,112,0.30)', paddingHorizontal: 10, paddingVertical: 8 },
  summaryTitle: { color: colors.text, fontSize: 14, fontWeight: '700' },
  summaryText: { color: colors.text2, fontSize: 12, lineHeight: 16, marginTop: 2 },
  emptyWrap: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 34 },
  emptyTitle: { color: colors.text, fontSize: 18, fontWeight: '700', marginTop: 16 },
  emptyText: { color: colors.text2, fontSize: 14, lineHeight: 20, textAlign: 'center', marginTop: 8 },
  sessionListContent: { paddingHorizontal: 10, paddingTop: 8, paddingBottom: 28, gap: 8 },
  sessionRow: { minHeight: 104, flexDirection: 'row', alignItems: 'center', paddingHorizontal: 12, paddingVertical: 10, backgroundColor: colors.surface, borderRadius: 8 },
  sessionRowFirst: {},
  sessionRowLast: {},
  sessionRowSelected: { backgroundColor: colors.surface2 },
  avatar: { width: 36, height: 36, borderRadius: 8, backgroundColor: colors.surface3, alignItems: 'center', justifyContent: 'center', position: 'relative' },
  avatarBadge: { position: 'absolute', right: -2, bottom: -2, width: 14, height: 14, borderRadius: 7, borderWidth: 2, borderColor: colors.surface },
  sessionContent: { flex: 1, marginLeft: 10, minWidth: 0 },
  sessionTitleRow: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  sessionTitle: { color: colors.text, fontSize: 15, fontWeight: '700', flex: 1 },
  relativeTime: { color: colors.muted, fontSize: 11 },
  sessionMetaRow: { flexDirection: 'row', alignItems: 'center', gap: 5, marginTop: 4 },
  sessionMeta: { color: colors.text2, fontSize: 12 },
  previewText: { color: colors.muted, fontSize: 12, lineHeight: 17, marginTop: 6 },
  chatHeader: { paddingHorizontal: 8, paddingTop: 4, paddingBottom: 3, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.border, backgroundColor: colors.bg },
  chatHeaderTop: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  chatTitleGroup: { flex: 1, minWidth: 0, flexDirection: 'row', alignItems: 'center', gap: 6 },
  chatStatusRow: { flexDirection: 'row', alignItems: 'center', gap: 6, paddingLeft: 38, minHeight: 18 },
  chatHeaderCenter: { flex: 1, minWidth: 0 },
  chatTitle: { color: colors.text, fontSize: 14, fontWeight: '700', flex: 1 },
  activityLine: { color: colors.muted, fontSize: 11, flex: 1 },
  segmented: { flexDirection: 'row', backgroundColor: colors.surface, borderRadius: 18, padding: 3 },
  segment: { paddingHorizontal: 10, paddingVertical: 5, borderRadius: 14 },
  segmentActive: { backgroundColor: colors.surface3 },
  segmentText: { color: colors.muted, fontSize: 12, fontWeight: '700' },
  segmentTextActive: { color: colors.text },
  chatBody: { flex: 1 },
  terminalStage: { flex: 1, backgroundColor: '#1c1b1f' },
  webTerminal: { flex: 1, backgroundColor: colors.terminal },
  terminalOverlay: { position: 'absolute', top: 8, left: 8, backgroundColor: 'rgba(41,43,49,0.92)', borderRadius: 8, paddingHorizontal: 10, paddingVertical: 6 },
  terminalOverlayText: { color: colors.text2, fontSize: 12 },
  tuiHint: { position: 'absolute', top: 8, flexDirection: 'row', alignItems: 'center', gap: 4, backgroundColor: 'rgba(41,41,41,0.96)', borderRadius: 8, paddingLeft: 10, paddingRight: 4, paddingVertical: 4 },
  tuiHintText: { color: colors.text, fontSize: 12 },
  tuiHintButton: { height: 26, justifyContent: 'center', paddingHorizontal: 6 },
  tuiHintButtonText: { color: colors.accent, fontSize: 12, fontWeight: '700' },
  scrollBottomButton: { position: 'absolute', right: 12, bottom: 12, width: 42, height: 42, borderRadius: 21, alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(10,132,255,0.22)', borderWidth: 1, borderColor: 'rgba(10,132,255,0.30)' },
  readerContent: { paddingHorizontal: 8, paddingTop: 14, paddingBottom: 12 },
  agentMessage: { marginHorizontal: 8, marginBottom: 12, borderRadius: 14 },
  userMessageWrap: { alignItems: 'flex-end', marginHorizontal: 8, marginBottom: 12 },
  userMessage: { maxWidth: '92%', backgroundColor: colors.user, borderRadius: 14, paddingHorizontal: 12, paddingVertical: 8 },
  userMessageText: { color: colors.text, fontSize: 15, lineHeight: 21 },
  toolBlock: { marginHorizontal: 8, marginBottom: 10, padding: 12, borderRadius: 10, borderLeftWidth: 3, backgroundColor: colors.surface },
  toolHeader: { flexDirection: 'row', alignItems: 'center', gap: 7, marginBottom: 8 },
  toolTitle: { fontSize: 12, fontWeight: '800' },
  toolText: { color: colors.text2, fontSize: 14, lineHeight: 20 },
  monoText: { color: colors.text, fontSize: 12, lineHeight: 18, fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace' },
  terminalPane: { flex: 1, backgroundColor: colors.terminal },
  terminalContent: { padding: 12 },
  terminalText: { color: '#dbe1ea', fontSize: 12, lineHeight: 17, fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace' },
  composerWrap: { paddingHorizontal: 8, paddingTop: 8, backgroundColor: colors.bg },
  composerPanel: { backgroundColor: '#1c1c1e', borderRadius: Platform.OS === 'android' ? 20 : 16, paddingHorizontal: 8, paddingTop: 8, paddingBottom: 8, overflow: 'hidden' },
  composerStatusRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 8, paddingBottom: 4, minHeight: 20 },
  composerStatusLeft: { flexDirection: 'row', alignItems: 'center', gap: 6, flex: 1, minWidth: 0 },
  composerStatusText: { color: colors.text2, fontSize: 11 },
  composerActionRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingTop: 4 },
  composerTools: { flexDirection: 'row', alignItems: 'center', gap: 8, flex: 1, minWidth: 0 },
  modeChip: { height: 28, borderRadius: 14, backgroundColor: colors.surface2, paddingHorizontal: 9, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 5 },
  modeChipText: { color: colors.text2, fontSize: 12, fontWeight: '600' },
  inputRow: { flexDirection: 'row', alignItems: 'flex-end', gap: 6, marginTop: 6 },
  input: { minHeight: 42, maxHeight: 132, paddingHorizontal: 8, paddingVertical: 6, color: colors.text, fontSize: 15, lineHeight: 20, textAlignVertical: 'top', backgroundColor: 'transparent' },
  sendButton: { width: 32, height: 32, borderRadius: 16, alignItems: 'center', justifyContent: 'center', marginLeft: 8 },
  sendButtonActive: { backgroundColor: colors.accent },
  sendButtonInactive: { backgroundColor: colors.surface2 },
  actionButton: { height: 32, borderRadius: Platform.OS === 'android' ? 20 : 16, paddingHorizontal: 8, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 5 },
  actionButtonActive: { backgroundColor: colors.surface2 },
  actionButtonText: { color: colors.text2, fontSize: 12, fontWeight: '600' },
  iconActionButton: { width: 32, height: 32, borderRadius: 16, alignItems: 'center', justifyContent: 'center' },
  quickRow: { flexDirection: 'row', gap: 6, overflow: 'hidden' },
  quickRowSecondary: { flexDirection: 'row', gap: 6, marginTop: 6, overflow: 'hidden' },
  specialKeyRow: { flexDirection: 'row', gap: 6, paddingTop: 8, overflow: 'hidden' },
  quickKey: { height: 30, minWidth: 42, borderRadius: 15, backgroundColor: colors.surface2, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 10 },
  quickKeySelected: { backgroundColor: 'rgba(10,132,255,0.18)' },
  quickKeyText: { color: colors.text2, fontSize: 12, fontWeight: '600' },
  historyRow: { flexDirection: 'row', gap: 6, marginTop: 6 },
  historyChip: { height: 28, maxWidth: 190, borderRadius: 14, backgroundColor: colors.surface2, justifyContent: 'center', paddingHorizontal: 10 },
  historyChipText: { color: colors.muted, fontSize: 11 },
  commandSheet: { maxHeight: '82%', backgroundColor: colors.surface, borderTopLeftRadius: 12, borderTopRightRadius: 12, paddingHorizontal: 16, paddingTop: 10, paddingBottom: 18 },
  commandSheetHeader: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  commandSections: { paddingTop: 8, paddingBottom: 12, gap: 16 },
  commandSection: { gap: 8 },
  commandSectionTitle: { color: colors.text2, fontSize: 12, fontWeight: '800' },
  commandGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  commandChip: { width: '48%', minHeight: 74, borderRadius: 12, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.bg, paddingHorizontal: 10, paddingVertical: 9 },
  commandChipDanger: { borderColor: colors.danger, backgroundColor: '#2a1f24' },
  commandChipTitle: { color: colors.text, fontSize: 13, fontWeight: '800' },
  commandChipText: { color: colors.muted, fontSize: 11, lineHeight: 15, marginTop: 4 },
  modalBackdrop: { flex: 1, backgroundColor: 'rgba(0,0,0,0.52)', justifyContent: 'flex-end' },
  centerBackdrop: { flex: 1, backgroundColor: 'rgba(0,0,0,0.52)', alignItems: 'center', justifyContent: 'center', paddingHorizontal: 18 },
  layoutDialog: { width: '100%', maxWidth: 420, borderRadius: 12, backgroundColor: colors.surface, padding: 16 },
  layoutModeRow: { flexDirection: 'row', gap: 8, marginTop: 14 },
  layoutModeButton: { flex: 1, height: 42, borderRadius: 8, borderWidth: 1, borderColor: colors.border, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.bg },
  layoutModeButtonActive: { borderColor: colors.accent, backgroundColor: 'rgba(110,168,255,0.16)' },
  layoutModeText: { color: colors.text2, fontSize: 13, fontWeight: '700' },
  layoutModeTextActive: { color: colors.text },
  fontScaleRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginTop: 14 },
  fontButton: { width: 76, height: 38, borderRadius: 8, backgroundColor: colors.surface3, alignItems: 'center', justifyContent: 'center' },
  fontButtonText: { color: colors.text, fontSize: 14, fontWeight: '800' },
  fontScaleText: { color: colors.text2, fontSize: 16, fontWeight: '700' },
  sheet: { backgroundColor: colors.surface, borderTopLeftRadius: 24, borderTopRightRadius: 24, paddingHorizontal: 18, paddingTop: 10 },
  sheetHandle: { alignSelf: 'center', width: 42, height: 4, borderRadius: 2, backgroundColor: colors.border, marginBottom: 14 },
  sheetTitle: { color: colors.text, fontSize: 22, fontWeight: '800' },
  sheetText: { color: colors.text2, fontSize: 14, lineHeight: 20, marginTop: 8 },
  codeInput: { marginTop: 16, height: 54, borderRadius: 14, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.bg, color: colors.text, fontSize: 24, fontWeight: '800', textAlign: 'center', letterSpacing: 6 },
  primaryButton: { height: 46, borderRadius: 14, backgroundColor: colors.accent, alignItems: 'center', justifyContent: 'center', marginTop: 12 },
  primaryButtonText: { color: colors.white, fontSize: 15, fontWeight: '800' },
  ghostButton: { height: 42, alignItems: 'center', justifyContent: 'center' },
  ghostButtonText: { color: colors.text2, fontSize: 14, fontWeight: '700' },
  closeButton: { height: 38, alignItems: 'center', justifyContent: 'center' },
  advancedBox: { borderRadius: 14, borderWidth: 1, borderColor: colors.border, padding: 12, backgroundColor: colors.bg, gap: 10 },
  advancedActions: { flexDirection: 'row', gap: 8 },
  secondaryButton: { flex: 1, height: 38, borderRadius: 12, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.surface3 },
  secondaryButtonText: { color: colors.text, fontWeight: '700' },
  labeledInput: { gap: 5 },
  inputLabel: { color: colors.text2, fontSize: 12 },
  advancedInput: { height: 40, borderRadius: 10, backgroundColor: colors.surface, color: colors.text, paddingHorizontal: 10 },
  modalStatus: { color: colors.muted, fontSize: 12, lineHeight: 17, marginTop: 10 },
});
