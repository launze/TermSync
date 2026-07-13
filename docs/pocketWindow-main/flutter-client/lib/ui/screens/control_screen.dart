import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pocketwindow/services/control_service.dart';
import 'package:pocketwindow/services/network_route_resolver.dart';
import 'package:pocketwindow/services/public_direct_client.dart';
import 'package:pocketwindow/services/server_endpoint_resolver.dart';
import 'package:pocketwindow/services/signaling_service.dart';
import 'package:pocketwindow/ui/screens/home_screen.dart';
import 'package:pocketwindow/ui/screens/window_selector_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:collection/collection.dart';

part 'control_screen_models.dart';
part 'control_screen_cursor.dart';
part 'control_screen_widgets.dart';

enum InputMode {
  browse,
  direct,
  touchpad,
  textOnly,
}
enum _KeyboardPage {
  letters,
  symbols,
}

enum _KeyboardModifier {
  ctrl,
  alt,
  shift,
}

class ControlScreen extends StatefulWidget {
  final String roomId;
  final String deviceId;
  final String localServerUrl;
  final String fallbackServerUrl;
  final bool initialIsLocalNetwork;
  final String deviceLocalIp;
  final List<String> deviceLocalIps;
  final int deviceLanProbePort;
  final int deviceLanDirectPort;
  final String? publicDirectHost;
  final int publicDirectPort;
  final String clientId;
  final String clientName;

  const ControlScreen({
    super.key,
    required this.roomId,
    required this.deviceId,
    required this.localServerUrl,
    required this.fallbackServerUrl,
    this.initialIsLocalNetwork = false,
    required this.deviceLocalIp,
    this.deviceLocalIps = const [],
    this.deviceLanProbePort = 0,
    this.deviceLanDirectPort = 0,
    this.publicDirectHost,
    this.publicDirectPort = 0,
    required this.clientId,
    required this.clientName,
  });

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen>
    with WidgetsBindingObserver {
  static const double _minScale = 1.0;
  static const double _maxScale = 4.0;
  static const double _touchpadSensitivity = 3.6;
  static const double _terminalScrollVelocitySlow = 0.10;
  static const double _terminalScrollVelocityMedium = 0.32;
  static const double _terminalScrollVelocityFast = 0.75;
  static const double _terminalScrollThresholdPrecise = 10.0;
  static const double _terminalScrollThresholdSlow = 8.0;
  static const double _terminalScrollThresholdMedium = 5.0;
  static const double _terminalScrollThresholdFast = 3.0;
  static const double _terminalScrollThresholdFling = 2.0;
  static const double _terminalScrollMaxCarryThresholds = 4.0;
  static const int _terminalScrollWheelUnit = 28;
  static const int _terminalScrollBoostKeepAliveMs = 350;
  static const double _bottomButtonHeight = 38.0;
  static const Size _mouseBallSize = Size(44, 44);
  static const Size _mousePanelSize = Size(172, 118);
  static const double _keyboardPanelMaxHeight = 320.0;
  static const int _vkShift = 0x10;
  static const int _vkControl = 0x11;
  static const int _vkAlt = 0x12;
  static const int _vkSpace = 0x20;
  static const int _vkEnd = 0x23;
  static const int _vkHome = 0x24;
  static const int _vkLeft = 0x25;
  static const int _vkUp = 0x26;
  static const int _vkRight = 0x27;
  static const int _vkDown = 0x28;
  static const int _vkOem1 = 0xBA;
  static const int _vkOemPlus = 0xBB;
  static const int _vkOemComma = 0xBC;
  static const int _vkOemMinus = 0xBD;
  static const int _vkOemPeriod = 0xBE;
  static const int _vkOem2 = 0xBF;
  static const int _vkOem3 = 0xC0;
  static const int _vkOem4 = 0xDB;
  static const int _vkOem5 = 0xDC;
  static const int _vkOem6 = 0xDD;
  static const int _vkOem7 = 0xDE;
  static const String _qcTitle = '\u5feb\u6377\u547d\u4ee4';
  static const String _qcEmpty =
      '\u8fd8\u6ca1\u6709\u9884\u8bbe\u547d\u4ee4\uff0c\u5148\u5728\u4e0b\u65b9\u65b0\u589e\u3002';
  static const String _qcAddLabel = '\u65b0\u589e\u547d\u4ee4';
  static const String _qcAddHint =
      '\u4f8b\u5982\uff1acodex / cloud-code / opencode';
  static const String _qcSavePreset = '\u4fdd\u5b58\u9884\u8bbe';
  static const String _qcNameTitle = '\u547d\u4ee4\u540d\u79f0';
  static const String _qcNameHint = '\u4f8b\u5982\uff1a\u6253\u5f00 Codex';
  static const String _qcBuiltinTitle = 'Codex';
  static const String _qcCustomTitle = '自定义命令';
  static const String _quickCommandsPrefsKey = 'control.quick_commands';
  static const String _sendHistoryPrefsKey = 'control.send_history';
  static const List<int> _windowScalePercentOptions = [
    30,
    40,
    50,
    60,
    70,
    80,
    90,
    100,
  ];
  static const int _defaultWindowScalePercent = 50;

  final TransformationController _transformationController =
      TransformationController();
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();
  List<QuickCommandForTest> _quickCommands = const [];
  List<String> _sendHistory = const [];
  ControlService? _cachedControlService;

  bool _didFitWindow = false;
  bool _showOverlay = true;
  int _lastMoveTsMs = 0;
  bool _draggingDirectMouse = false;
  Timer? _scrollBoostRestoreTimer;
  Timer? _visualExpectationTimer;
  Timer? _handshakeRecoveryTimer;
  Timer? _autoSelectWindowTimer;
  Timer? _autoSubmitTimer;
  Timer? _repeatDeleteTimer;
  Timer? _pendingPauseTimer;
  Timer? _resumeRetryTimer;
  // Watchdog: when the signaling ws drops while the app is in the foreground
  // we must reconnect automatically. Without this, a server-side detach
  // (e.g. ACK timeout) leaves the phone idle indefinitely until the user
  // manually switches away and back.
  bool _signalingAutoReconnectArmed = false;
  // Watchdog: prove the Dart UI isolate is alive each second. Combined with
  // the platform-channel reverse ping registered in MainActivity, we can
  // distinguish three failure modes:
  //   1) Dart Timers stop firing -> microtask queue starvation / event loop
  //      blocked by an awaiting future inside our own code.
  //   2) postFrameCallback stops firing while Timer keeps firing -> rendering
  //      pipeline stuck.
  //   3) Both stop firing AND the native ping no longer reaches Dart ->
  //      Android UI thread itself is jammed (e.g. method-channel deadlock).
  Timer? _isolateHeartbeatTimer;
  int _isolateHeartbeatTick = 0;
  int _lastFrameCallbackTsMs = 0;
  int _lastNativePingTsMs = 0;
  int _resumeRetryAttempt = 0;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  InputMode _inputMode = InputMode.browse;
  Size? _lastPreviewLayoutSize;
  Size? _stableFitViewportSize;
  bool _fitViewportPersisted = false;
  bool _pausedByLifecycle = false;
  bool _reconnecting = false;
  int _backgroundPauseGeneration = 0;
  int _resumeReconnectGeneration = 0;
  int _visualExpectationGeneration = 0;
  int _visualExpectationStartedAtMs = 0;
  DateTime? _visualExpectationBaselineFrameAt;
  bool _visualExpectationRestartRequested = false;
  int _handshakeStuckSinceMs = 0;
  bool _showVideoStuckHint = false;
  bool _networkRouteRefreshInFlight = false;
  bool _autoSelectWindowInFlight = false;
  bool _autoSelectWindowDone = false;
  late final String _connectionDiagId;
  final Set<String> _onceLoggedKeys = <String>{};
  AppLifecycleState? _lastObservedLifecycleState;
  int _textSendSeq = 0;
  int? _lastSelectedHwnd;
  String? _lastSelectedTitle;
  bool _prefsLoaded = false;
  bool _isLocalNetworkConnection = false;
  bool _usingLocalNetworkPreset = false;
  bool _mousePanelExpanded = false;
  Offset _mousePanelOffset = const Offset(12, 180);
  bool _keyboardVisible = false;
  bool _autoSubmitText = false;
  double? _keyboardPanelTop;
  String _appVersion = '';
  bool _connectionFailed = false;
  String _connectionErrorMessage = '';
  String _connectionStage = '';
  bool _captureSelectionMode = false;
  bool _initialFitRequested = false;
  int _windowScalePercent = _defaultWindowScalePercent;
  late String _activeRoomId;
  late String _activeDeviceLocalIp;
  late List<String> _activeDeviceLocalIps;
  late int _activeDeviceLanProbePort;
  late int _activeDeviceLanDirectPort;
  Offset? _captureDragStart;
  Rect? _captureSelectionRect;
  _CaptureEditMode _captureEditMode = _CaptureEditMode.none;
  Offset? _captureEditAnchor;
  Rect? _captureEditInitialRect;
  ScreenshotCaptureResult? _capturePreview;
  bool _capturingScreenshot = false;
  _KeyboardPage _keyboardPage = _KeyboardPage.letters;
  final Set<_KeyboardModifier> _keyboardModifiers = <_KeyboardModifier>{};
  StreamProfile _preferredStreamProfile = StreamProfile.smoothHd;
  double _preferredQualityScale = 1.0;
  double _preferredResolutionScale = 1.0;
  double _preferredDynamicFpsLimit = 20.0;
  double _preferredStaticFpsLimit = 2.0;
  double _preferredScrollVideoScale = 0.62;
  int _preferredScrollVideoBitrateKbps = 1800;
  double _preferredScrollVideoFps = 15.0;
  int _preferredScrollVideoCrf = 35;
  int _preferredScrollVideoVbvMultiplier = 3;
  String _preferredScrollVideoPixelFormat = 'yuv420p';
  String _preferredScrollVideoPreset = 'veryfast';
  int _preferredScrollRestoreDelayMs = 250;
  final Map<StreamProfile, _ScrollVideoTuning> _scrollVideoTunings =
      <StreamProfile, _ScrollVideoTuning>{
    StreamProfile.hybrid: const _ScrollVideoTuning(
      scale: 0.70,
      bitrateKbps: 4000,
      fps: 24.0,
      crf: 26,
      vbvMultiplier: 3,
      pixelFormat: 'yuv420p',
      preset: 'veryfast',
      restoreDelayMs: 250,
    ),
    StreamProfile.smoothHd: const _ScrollVideoTuning(
      scale: 0.85,
      bitrateKbps: 10000,
      fps: 40.0,
      crf: 22,
      vbvMultiplier: 4,
      pixelFormat: 'yuv420p',
      preset: 'veryfast',
      restoreDelayMs: 250,
    ),
    StreamProfile.lan: const _ScrollVideoTuning(
      scale: 1.0,
      bitrateKbps: 60000,
      fps: 60.0,
      crf: 18,
      vbvMultiplier: 6,
      pixelFormat: 'yuv420p',
      preset: 'veryfast',
      restoreDelayMs: 250,
    ),
  };
  bool _scrollBoostActive = false;
  double _terminalScrollAccumDy = 0.0;
  int _lastTerminalScrollSampleTsMs = 0;
  int _lastTerminalScrollEmitTsMs = 0;
  int _lastScrollBoostKeepAliveTsMs = 0;
  bool _terminalScrollGesturePrimed = false;
  String? _terminalScrollGestureId;
  int _terminalScrollWheelSeq = 0;
  double _terminalScrollTotalDy = 0.0;
  int _terminalScrollTouchUpdates = 0;
  int? _rawScrollPointerId;
  Offset? _rawScrollLastPosition;
  String _rawScrollSurface = '';
  bool _rawScrollRecognized = false;

  bool get _showTuningControls => false;

  @override
  void initState() {
    super.initState();
    _activeRoomId = widget.roomId;
    _activeDeviceLocalIp = widget.deviceLocalIp;
    _activeDeviceLocalIps = List<String>.from(widget.deviceLocalIps);
    _activeDeviceLanProbePort = widget.deviceLanProbePort;
    _activeDeviceLanDirectPort = widget.deviceLanDirectPort;
    _connectionDiagId =
        'conn-${DateTime.now().millisecondsSinceEpoch}-${widget.roomId}';
    _isLocalNetworkConnection = widget.initialIsLocalNetwork;
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _appVersion = '${info.version}+${info.buildNumber}');
    });
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((_) {
      _scheduleConnectivityReconnect();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _restorePreferences();
      await _persistBackgroundRecoveryPending(false);
      _scheduleAutoSelectInitialWindow();
      _startConnection();
    });
    _startIsolateHeartbeat();
  }

  void _startIsolateHeartbeat() {
    _isolateHeartbeatTimer?.cancel();
    _isolateHeartbeatTick = 0;
    const heartbeatChannel =
        MethodChannel('pocketwindow/isolate_heartbeat');
    heartbeatChannel.setMethodCallHandler((call) async {
      if (call.method == 'native_ping') {
        _lastNativePingTsMs = DateTime.now().millisecondsSinceEpoch;
      }
      return null;
    });
    // Tag native heartbeat with the current Dart-known lifecycle. Best-effort.
    heartbeatChannel.invokeMethod('setLifecycle', {'state': 'resumed'});
    _isolateHeartbeatTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _isolateHeartbeatTick++;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _lastFrameCallbackTsMs = DateTime.now().millisecondsSinceEpoch;
      });
      // Persist heartbeat on the native side so a frozen network or a frozen
      // UI thread cannot swallow it. Worst case the Dart isolate itself is
      // dead and this Timer never fires - we'll see the gap in the file.
      final payload =
          '{"ts_ms":$nowMs,"tick":$_isolateHeartbeatTick,'
          '"last_frame_age_ms":${_lastFrameCallbackTsMs == 0 ? -1 : nowMs - _lastFrameCallbackTsMs},'
          '"last_native_ping_age_ms":${_lastNativePingTsMs == 0 ? -1 : nowMs - _lastNativePingTsMs},'
          '"reconnecting":$_reconnecting,'
          '"app_lifecycle":"${_lastObservedLifecycleState?.name ?? "null"}",'
          '"diag_id":"$_connectionDiagId"}';
      heartbeatChannel
          .invokeMethod('writeDartHeartbeat', {'line': payload})
          .catchError((_) {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controlService = context.read<ControlService>();
    final signaling = context.read<SignalingService>();
    if (_cachedControlService == null) {
      _cachedControlService = controlService;
      controlService.addListener(_handleVideoHandshakeWatchdog);
      controlService.setConnectionDiagId(_connectionDiagId);
      controlService.sendScrollDiagnostic({
        'event': 'connection_diag_started',
        'diag_id': _connectionDiagId,
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'room_id': _activeRoomId,
        'initial_is_local_network': widget.initialIsLocalNetwork,
        'selected_hwnd': controlService.selectedHwnd,
        'h264_available': controlService.usingH264Video,
        'h264_negotiating': controlService.h264VideoStream.negotiating,
        'handshake_progress': controlService.videoHandshakeProgress,
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        controlService.sendScrollDiagnostic({
          'event': 'connection_diag_start_video_probe',
          'diag_id': _connectionDiagId,
          'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
          'selected_hwnd': controlService.selectedHwnd,
        });
        controlService.startDirectTransportProbe();
      });
    }
    if (!_signalingAutoReconnectArmed) {
      _signalingAutoReconnectArmed = true;
      signaling.addListener(() => _onSignalingStatusChanged(signaling));
    }
  }

  void _onSignalingStatusChanged(SignalingService signaling) {
    if (!mounted) return;
    if (signaling.status != ConnectionStatus.idle) return;
    if (_reconnecting) return;
    if (_lastObservedLifecycleState == AppLifecycleState.paused) return;
    final controlService = _cachedControlService;
    if (controlService == null || !controlService.connected) return;
    controlService.sendScrollDiagnostic({
      'event': 'signaling_auto_reconnect_triggered',
      'diag_id': _connectionDiagId,
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
      'signaling_status': signaling.status.name,
      'control_connected': controlService.connected,
      'app_lifecycle': _lastObservedLifecycleState?.name ?? 'null',
    });
    unawaited(_recoverConnectionLikeFreshOpen(
      trigger: 'signaling-drop-auto',
      videoRestoreReason: 'signaling-drop-auto-reconnect',
    ));
  }

  @override
  void dispose() {
    _resumeReconnectGeneration += 1;
    _backgroundPauseGeneration += 1;
    _reconnecting = false;
    WidgetsBinding.instance.removeObserver(this);
    _scrollBoostRestoreTimer?.cancel();
    _visualExpectationTimer?.cancel();
    _handshakeRecoveryTimer?.cancel();
    _autoSelectWindowTimer?.cancel();
    _autoSubmitTimer?.cancel();
    _repeatDeleteTimer?.cancel();
    _pendingPauseTimer?.cancel();
    _resumeRetryTimer?.cancel();
    _isolateHeartbeatTimer?.cancel();
    _isolateHeartbeatTimer = null;
    _connectivitySubscription?.cancel();
    _textController.dispose();
    _textFocusNode.dispose();
    WakelockPlus.disable();
    _cachedControlService?.removeListener(_handleVideoHandshakeWatchdog);
    _cachedControlService?.stopDirectTransportProbe();
    _transformationController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_lastObservedLifecycleState != state) {
      final previous = _lastObservedLifecycleState;
      _lastObservedLifecycleState = state;
      final controlService = _cachedControlService;
      if (controlService != null) {
        controlService.sendScrollDiagnostic({
          'event': 'lifecycle_state_transition',
          'diag_id': _connectionDiagId,
          'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
          'from': previous?.name ?? 'null',
          'to': state.name,
          'paused_by_lifecycle': _pausedByLifecycle,
          'reconnecting': _reconnecting,
        });
      }
    }
    switch (state) {
      case AppLifecycleState.paused:
        // True background: commit pause immediately so we don't miss the
        // chance to persist the recovery flag before the OS suspends us.
        _pendingPauseTimer?.cancel();
        _pendingPauseTimer = null;
        _handleBackgroundPause();
        break;
      case AppLifecycleState.hidden:
        // Transient hidden states (notification shade pull, multitasking
        // overview, brief overlays) frequently flip between hidden and
        // resumed within a few hundred milliseconds. Tearing the signaling
        // connection down for those is what produces the "frozen UI after
        // switching apps" bug. Defer the full pause until we've observed
        // hidden long enough that it's likely a real backgrounding.
        _pendingPauseTimer?.cancel();
        _pendingPauseTimer = Timer(const Duration(milliseconds: 1500), () {
          if (!mounted) return;
          _pendingPauseTimer = null;
          _handleBackgroundPause();
        });
        break;
      case AppLifecycleState.resumed:
        _pendingPauseTimer?.cancel();
        _pendingPauseTimer = null;
        _handleForegroundResume();
        break;
      case AppLifecycleState.detached:
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_connectionFailed) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline,
                    color: Color(0xFFFCA5A5), size: 52),
                const SizedBox(height: 20),
                const Text(
                  '连接失败',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Text(
                  _connectionErrorMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white60, fontSize: 14),
                ),
                const SizedBox(height: 28),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('返回主界面'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white38),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 28, vertical: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final isBrowseMode = _inputMode == InputMode.browse;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _disconnectAndExit();
      },
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 44,
          titleSpacing: 0,
          title: const SizedBox.shrink(),
          actionsPadding: const EdgeInsets.only(right: 2),
          actions: [
            TextButton(
              onPressed: _handleManualRecoveryPressed,
              style: _topActionButtonStyle(),
              child: const Text('恢复'),
            ),
            PopupMenuButton<int>(
              tooltip: '窗口比例',
              padding: EdgeInsets.zero,
              initialValue: _windowScalePercent,
              onSelected: _handleWindowScaleChanged,
              itemBuilder: (context) => _windowScalePercentOptions
                  .map(
                    (percent) => PopupMenuItem<int>(
                      value: percent,
                      child: Text('窗口 $percent%'),
                    ),
                  )
                  .toList(growable: false),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                child: Text(
                  '窗口 $_windowScalePercent%',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
            PopupMenuButton<InputMode>(
              tooltip: '切换模式',
              padding: EdgeInsets.zero,
              initialValue: _inputMode,
              onSelected: (mode) {
                _handleModeChanged(mode);
                _persistPreferences();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: InputMode.browse, child: Text('浏览')),
                PopupMenuItem(value: InputMode.direct, child: Text('直控')),
                PopupMenuItem(value: InputMode.touchpad, child: Text('鼠标')),
                PopupMenuItem(value: InputMode.textOnly, child: Text('纯输入')),
              ],
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                child: Text('模式', style: TextStyle(fontSize: 13)),
              ),
            ),
            Consumer<ControlService>(
              builder: (context, controlService, child) {
                return PopupMenuButton<StreamProfile>(
                  tooltip: '切换画质',
                  padding: EdgeInsets.zero,
                  initialValue: controlService.streamProfile,
                  onSelected: (profile) {
                    _preferredStreamProfile = profile;
                    _usingLocalNetworkPreset = profile == StreamProfile.lan;
                    _applyConnectionStreamSettings(
                      controlService,
                      isLocalNetwork: _isLocalNetworkConnection,
                    );
                    _persistPreferences();
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                        value: StreamProfile.hybrid, child: Text('混合模式')),
                    const PopupMenuItem(
                        value: StreamProfile.smoothHd, child: Text('高清流畅模式')),
                    PopupMenuItem(
                      value: StreamProfile.lan,
                      enabled: _isLocalNetworkConnection,
                      child: Text(
                        '局域网模式',
                        style: TextStyle(
                          color: _isLocalNetworkConnection ? null : Colors.grey,
                        ),
                      ),
                    ),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                    child: Text('画质', style: TextStyle(fontSize: 13)),
                  ),
                );
              },
            ),
            if (_showTuningControls)
              TextButton(
                style: _topActionButtonStyle(),
                onPressed: _openBitrateSheet,
                child: const Text('码率'),
              ),
            if (_showTuningControls)
              TextButton(
                style: _topActionButtonStyle(),
                onPressed: _openFpsSheet,
                child: const Text('帧率'),
              ),
            IconButton(
              tooltip: '滚动调试',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              onPressed: _openScrollVideoTuningSheet,
              icon: const Icon(Icons.tune, size: 20),
            ),
            TextButton(
              style: _topActionButtonStyle(),
              onPressed: () {
                setState(() {
                  _showOverlay = !_showOverlay;
                });
                _persistPreferences();
              },
              child: Text(_showOverlay ? '隐藏' : '显示'),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: Consumer<ControlService>(
                    builder: (context, controlService, child) {
                      if (_inputMode == InputMode.textOnly) {
                        return _buildTextOnlySurface(controlService);
                      }
                      final hasDirectVideo =
                          controlService.directTransport?.hasRemoteVideo ==
                              true;
                      if (controlService.currentFrame == null &&
                          !controlService.usingH264Video &&
                          !hasDirectVideo) {
                        if (_connectionStage.isNotEmpty) {
                          return _buildConnectionProgress();
                        }
                        if (controlService.videoHandshakeProgress >= 0) {
                          return LayoutBuilder(
                            builder: (context, constraints) {
                              _updatePreviewLayoutSize(
                                Size(
                                  constraints.maxWidth,
                                  constraints.maxHeight,
                                ),
                              );
                              _maybeFitInitialWindow(controlService);
                              return _buildVideoHandshakeProgress(
                                controlService,
                              );
                            },
                          );
                        }
                        return Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text(
                              '等待远端画面...',
                              style: TextStyle(color: Colors.white70),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '房间号：$_activeRoomId',
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 12),
                            ),
                          ],
                        );
                      }

                      return LayoutBuilder(
                        builder: (context, constraints) {
                          _updatePreviewLayoutSize(
                            Size(constraints.maxWidth, constraints.maxHeight),
                          );
                          _maybeFitInitialWindow(controlService);
                          final remoteW = controlService.videoFrameWidth;
                          final remoteH = controlService.videoFrameHeight;
                          final frame = _buildFrame(controlService);

                          Widget content;
                          if (isBrowseMode) {
                            content = _buildBrowseViewer(
                              controlService: controlService,
                              frame: frame,
                              remoteW: remoteW,
                              remoteH: remoteH,
                              viewportW: constraints.maxWidth,
                              viewportH: constraints.maxHeight,
                            );
                          } else if (_inputMode == InputMode.direct) {
                            content = _buildDirectMouseSurface(
                              controlService: controlService,
                              frame: frame,
                              containerW: constraints.maxWidth,
                              containerH: constraints.maxHeight,
                              remoteW: remoteW,
                              remoteH: remoteH,
                            );
                          } else {
                            content = _buildTouchpadSurface(
                              controlService: controlService,
                              frame: frame,
                            );
                          }

                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              content,
                              if (_showOverlay)
                                Positioned(
                                  top: 12,
                                  left: 12,
                                  right: 12,
                                  child: _OverlayInfo(
                                    leftText:
                                        _leftOverlayTextV2(controlService),
                                    rightText: _rightOverlayTextReadable(
                                        controlService),
                                  ),
                                ),
                              if (!isBrowseMode)
                                Positioned(
                                  top: _showOverlay ? 108 : 12,
                                  right: 12,
                                  child: _ModeBadge(
                                      label: _badgeTextV2(_inputMode)),
                                ),
                              if (_inputMode == InputMode.touchpad)
                                _buildMouseModeOverlay(controlService),
                              if (_keyboardVisible)
                                _buildKeyboardOverlay(controlService),
                              if (_captureSelectionMode)
                                _buildCaptureSelectionOverlay(controlService),
                              if (_capturePreview != null)
                                _buildCapturePreviewOverlay(),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
              _buildBottomBarV2(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFrame(ControlService controlService) {
    final h264TextureId = controlService.h264VideoStream.textureId;
    final hasH264Video = controlService.usingH264Video && h264TextureId != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasH264Video)
          Texture(textureId: h264TextureId, key: ValueKey(h264TextureId))
        else
          Image.memory(
            controlService.currentFrame!,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, stackTrace) {
              return const Text(
                '画面解码失败',
                style: TextStyle(color: Colors.white),
              );
            },
          ),
        if (controlService.cursorVisible &&
            controlService.cursorX != null &&
            controlService.cursorY != null &&
            controlService.remoteWidth != null &&
            controlService.remoteHeight != null)
          Positioned.fill(
            child: IgnorePointer(
              child: _RemoteCursorOverlayV2(
                normalizedX: controlService.cursorX!,
                normalizedY: controlService.cursorY!,
                remoteWidth: controlService.remoteWidth!,
                remoteHeight: controlService.remoteHeight!,
                cursorImageBytes: controlService.cursorImageBytes,
                cursorImageWidth: controlService.cursorImageWidth,
                cursorImageHeight: controlService.cursorImageHeight,
                hotspotX: controlService.cursorHotspotX,
                hotspotY: controlService.cursorHotspotY,
              ),
            ),
          ),
        if (_appVersion.isNotEmpty)
          Positioned(
            left: 4,
            top: 4,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Text(
                  _appVersion,
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildConnectionProgress() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '正在连接',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _connectionStage,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: const LinearProgressIndicator(
                  minHeight: 6,
                  backgroundColor: Colors.white12,
                  color: Color(0xFF7DD3FC),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '房间：${widget.roomId}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoHandshakeProgress(ControlService controlService) {
    final progress = controlService.videoHandshakeProgress.clamp(0, 100);
    final codec =
        controlService.videoHandshakeCodec == 'h265' ? 'H265' : 'H264';
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '正在连接 $codec 视频通道',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                controlService.videoHandshakeStage,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              if (controlService.handshakeStageDetail.isNotEmpty &&
                  controlService.handshakeStageDetail !=
                      controlService.videoHandshakeStage) ...[
                const SizedBox(height: 4),
                Text(
                  controlService.handshakeStageDetail,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 12),
                ),
              ],
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: progress / 100.0,
                  minHeight: 6,
                  backgroundColor: Colors.white12,
                  color: const Color(0xFF7DD3FC),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '$progress%',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 6),
              if (controlService.handshakeProgressTime.isNotEmpty)
                Text(
                  '等待时间：${controlService.handshakeProgressTime}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              const SizedBox(height: 2),
              Text(
                '已收到消息：${controlService.handshakeReceivedTypes.join('、')}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
              const SizedBox(height: 6),
              Text(
                '正在连接窗口：${controlService.windowTitle ?? _lastSelectedTitle ?? '自动选择中'}',
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white60, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text(
                '房间：$_activeRoomId',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
              if (_showVideoStuckHint) ...[
                const SizedBox(height: 12),
                const Text(
                  '视频通道未响应，可以点下方按钮返回主界面重新连接',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFFFBBF24), fontSize: 13),
                ),
              ],
              if (progress >= 82 || _showVideoStuckHint) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _disconnectAndExit,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                  ),
                  child: const Text('断开并返回主界面', style: TextStyle(fontSize: 13)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBrowseViewer({
    required ControlService controlService,
    required Widget frame,
    required int? remoteW,
    required int? remoteH,
    required double viewportW,
    required double viewportH,
  }) {
    if (remoteW == null || remoteH == null || remoteW <= 0 || remoteH <= 0) {
      return Center(child: frame);
    }

    final contentSize = _contentSize(
      viewportW: viewportW,
      viewportH: viewportH,
      remoteW: remoteW.toDouble(),
      remoteH: remoteH.toDouble(),
    );

    return _buildRawScrollPointerLayer(
      controlService: controlService,
      surface: 'browse_raw',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: _resetBrowseTransform,
        onVerticalDragStart: (_) {
          _startTerminalScrollGesture(controlService, 'browse');
        },
        onVerticalDragUpdate: (details) {
          if (_rawScrollPointerId != null) return;
          final now = DateTime.now().millisecondsSinceEpoch;
          final dtMs = _lastTerminalScrollSampleTsMs == 0
              ? 16
              : (now - _lastTerminalScrollSampleTsMs).clamp(1, 1000);
          _lastTerminalScrollSampleTsMs = now;
          final velocity = details.delta.dy.abs() / dtMs;
          _emitAcceleratedTerminalScroll(
            controlService,
            details.delta.dy,
            velocity,
            dtMs,
            now,
          );
        },
        onVerticalDragEnd: (_) => _handleTerminalScrollEnd(),
        onVerticalDragCancel: _handleTerminalScrollEnd,
        child: InteractiveViewer(
          transformationController: _transformationController,
          alignment: Alignment.center,
          minScale: _minScale,
          maxScale: _maxScale,
          panEnabled: false,
          scaleEnabled: !_didFitWindow,
          boundaryMargin: const EdgeInsets.all(240),
          clipBehavior: Clip.none,
          constrained: false,
          child: SizedBox(
            width: contentSize.width,
            height: contentSize.height,
            child: FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: remoteW.toDouble(),
                height: remoteH.toDouble(),
                child: frame,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDirectMouseSurface({
    required ControlService controlService,
    required Widget frame,
    required double containerW,
    required double containerH,
    required int? remoteW,
    required int? remoteH,
  }) {
    return _buildRawScrollPointerLayer(
      controlService: controlService,
      surface: 'direct_raw',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          if (_draggingDirectMouse) return;
          final point = _mapToRemote(
            local: details.localPosition,
            containerW: containerW,
            containerH: containerH,
            remoteW: remoteW,
            remoteH: remoteH,
          );
          if (point != null) {
            controlService.debugClientClick(
              source: 'direct_tap',
              localX: details.localPosition.dx,
              localY: details.localPosition.dy,
              containerW: containerW,
              containerH: containerH,
              remoteW: remoteW ?? 0,
              remoteH: remoteH ?? 0,
              mappedX: point.$1,
              mappedY: point.$2,
              selectedHwnd: controlService.selectedHwnd,
              button: 'left',
            );
            controlService.mouseClick(point.$1, point.$2, 'left');
          }
        },
        onPanStart: (details) {
          _draggingDirectMouse = true;
          _startTerminalScrollGesture(controlService, 'direct');
          final point = _mapToRemote(
            local: details.localPosition,
            containerW: containerW,
            containerH: containerH,
            remoteW: remoteW,
            remoteH: remoteH,
          );
          if (point != null) {
            controlService.mouseMove(point.$1, point.$2);
          }
        },
        onPanUpdate: (details) {
          final now = DateTime.now().millisecondsSinceEpoch;
          final dtMs = _lastTerminalScrollSampleTsMs == 0
              ? 16
              : (now - _lastTerminalScrollSampleTsMs).clamp(1, 1000);
          _lastTerminalScrollSampleTsMs = now;

          final absDx = details.delta.dx.abs();
          final absDy = details.delta.dy.abs();
          final isScrollGesture = absDy > absDx * 0.75 && absDy >= 0.5;
          if (isScrollGesture && _rawScrollPointerId == null) {
            final velocity = absDy / dtMs;
            _emitAcceleratedTerminalScroll(
              controlService,
              details.delta.dy,
              velocity,
              dtMs,
              now,
            );
            return;
          }
          if (_rawScrollRecognized) return;

          if (now - _lastMoveTsMs < 16) return;
          _lastMoveTsMs = now;

          final point = _mapToRemote(
            local: details.localPosition,
            containerW: containerW,
            containerH: containerH,
            remoteW: remoteW,
            remoteH: remoteH,
          );
          if (point != null) {
            controlService.mouseMove(point.$1, point.$2);
          }
        },
        onPanEnd: (_) {
          _draggingDirectMouse = false;
          _handleTerminalScrollEnd();
        },
        onPanCancel: () {
          _draggingDirectMouse = false;
          _handleTerminalScrollEnd();
        },
        child: frame,
      ),
    );
  }

  Widget _buildTouchpadSurface({
    required ControlService controlService,
    required Widget frame,
  }) {
    return _buildRawScrollPointerLayer(
      controlService: controlService,
      surface: 'touchpad_raw',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          controlService.mouseClickCurrent();
        },
        onDoubleTap: () {
          controlService.mouseClickCurrent();
        },
        onLongPress: () {
          controlService.mouseClickCurrent('right');
        },
        onPanStart: (_) {
          _startTerminalScrollGesture(controlService, 'touchpad');
          controlService.mouseMoveRelative(0, 0);
        },
        onPanUpdate: (details) {
          final now = DateTime.now().millisecondsSinceEpoch;
          final dtMs = _lastTerminalScrollSampleTsMs == 0
              ? 16
              : (now - _lastTerminalScrollSampleTsMs).clamp(1, 1000);
          _lastTerminalScrollSampleTsMs = now;

          final absDx = details.delta.dx.abs();
          final absDy = details.delta.dy.abs();
          final isScrollGesture = absDy > absDx * 0.75 && absDy >= 0.5;
          if (isScrollGesture && _rawScrollPointerId == null) {
            final velocity = absDy / dtMs;
            _emitAcceleratedTerminalScroll(
              controlService,
              details.delta.dy,
              velocity,
              dtMs,
              now,
            );
            return;
          }
          if (_rawScrollRecognized) return;

          if (now - _lastMoveTsMs < 16) return;
          _lastMoveTsMs = now;
          final dx = (details.delta.dx * _touchpadSensitivity).round();
          final dy = (details.delta.dy * _touchpadSensitivity).round();
          if (dx == 0 && dy == 0) return;
          controlService.mouseMoveRelative(dx, dy);
        },
        onPanEnd: (_) => _handleTerminalScrollEnd(),
        onPanCancel: _handleTerminalScrollEnd,
        child: frame,
      ),
    );
  }

  Widget _buildTextOnlySurface(ControlService controlService) {
    return Container(
      color: const Color(0xFF101114),
      padding: const EdgeInsets.all(16),
      alignment: Alignment.topCenter,
      child: TextField(
        controller: _textController,
        focusNode: _textFocusNode,
        autofocus: true,
        minLines: 8,
        maxLines: null,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        style: const TextStyle(color: Colors.white, fontSize: 18, height: 1.45),
        cursorColor: Colors.white,
        decoration: InputDecoration(
          hintText: '在这里输入或使用手机系统语音输入',
          hintStyle: const TextStyle(color: Colors.white38),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.08),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.42)),
          ),
        ),
        onChanged: (_) => _handleTextInputChanged(),
      ),
    );
  }

  Widget _buildMouseModeOverlay(ControlService controlService) {
    final viewport = _lastPreviewLayoutSize ?? const Size(0, 0);
    final panelSize = _mousePanelExpanded ? _mousePanelSize : _mouseBallSize;
    final offset =
        _clampMousePanelOffset(_mousePanelOffset, viewport, panelSize);
    if (offset != _mousePanelOffset) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _mousePanelOffset = offset;
        });
      });
    }

    return Positioned(
      left: offset.dx,
      top: offset.dy,
      child: _mousePanelExpanded
          ? _buildExpandedMousePanel(controlService, viewport)
          : _buildCollapsedMouseBall(viewport),
    );
  }

  Widget _buildCollapsedMouseBall(Size viewport) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() {
          _mousePanelExpanded = true;
        });
      },
      onPanUpdate: (details) {
        _moveMousePanel(details.delta, viewport, _mouseBallSize);
      },
      child: Container(
        width: _mouseBallSize.width,
        height: _mouseBallSize.height,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          shape: BoxShape.circle,
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.82), width: 1.1),
          boxShadow: const [
            BoxShadow(
              color: Color(0x55000000),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: const Text(
          '鼠标',
          style: TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildExpandedMousePanel(
      ControlService controlService, Size viewport) {
    return Container(
      width: _mousePanelSize.width,
      height: _mousePanelSize.height,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.20)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 14,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: Column(
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '鼠标模式',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _mousePanelExpanded = false;
                    });
                  },
                  child: Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Text(
                      '×',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: _MousePanelButton(
                      label: '左键',
                      onTap: () {
                        controlService.debugClientClick(
                          source: 'mouse_panel_left',
                          localX: _mousePanelOffset.dx,
                          localY: _mousePanelOffset.dy,
                          containerW: viewport.width,
                          containerH: viewport.height,
                          remoteW: controlService.remoteWidth ?? 0,
                          remoteH: controlService.remoteHeight ?? 0,
                          mappedX: -1,
                          mappedY: -1,
                          selectedHwnd: controlService.selectedHwnd,
                          button: 'left',
                        );
                        controlService.mouseClickCurrent();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MousePanelButton(
                      label: '右键',
                      onTap: () {
                        controlService.debugClientClick(
                          source: 'mouse_panel_right',
                          localX: _mousePanelOffset.dx,
                          localY: _mousePanelOffset.dy,
                          containerW: viewport.width,
                          containerH: viewport.height,
                          remoteW: controlService.remoteWidth ?? 0,
                          remoteH: controlService.remoteHeight ?? 0,
                          mappedX: -1,
                          mappedY: -1,
                          selectedHwnd: controlService.selectedHwnd,
                          button: 'right',
                        );
                        controlService.mouseClickCurrent('right');
                      },
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (details) {
                _moveMousePanel(details.delta, viewport, _mousePanelSize);
              },
              child: Container(
                height: 34,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.16)),
                ),
                alignment: Alignment.center,
                child: const Text(
                  '拖动面板',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 11.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeyboardOverlay(ControlService controlService) {
    final viewport = _lastPreviewLayoutSize ?? const Size(0, 0);
    if (viewport.width <= 0 || viewport.height <= 0) {
      return const SizedBox.shrink();
    }
    final width = viewport.width;
    final height = _resolvedKeyboardHeight(viewport);
    final top = _resolvedKeyboardTop(viewport);

    return Positioned(
      left: 0,
      top: top,
      child: _KeyboardOverlayPanel(
        width: width,
        height: height,
        page: _keyboardPage,
        modifiers: _keyboardModifiers,
        onPageChanged: (page) {
          setState(() {
            _keyboardPage = page;
          });
        },
        onDragUpdate: (delta) {
          setState(() {
            _keyboardPanelTop = _clampKeyboardTop((top + delta.dy), viewport);
          });
        },
        onKeyPressed: (definition) =>
            _handleVirtualKeyPressed(controlService, definition),
        onModifierPressed: (modifier) {
          setState(() {
            if (_keyboardModifiers.contains(modifier)) {
              _keyboardModifiers.remove(modifier);
            } else {
              _keyboardModifiers.add(modifier);
            }
          });
        },
      ),
    );
  }

  void _moveMousePanel(Offset delta, Size viewport, Size panelSize) {
    setState(() {
      _mousePanelOffset = _clampMousePanelOffset(
        _mousePanelOffset + delta,
        viewport,
        panelSize,
      );
    });
  }

  Offset _clampMousePanelOffset(Offset offset, Size viewport, Size panelSize) {
    if (viewport.width <= 0 || viewport.height <= 0) {
      return offset;
    }
    final maxX = math.max(0.0, viewport.width - panelSize.width - 8);
    final maxY = math.max(0.0, viewport.height - panelSize.height - 8);
    return Offset(
      offset.dx.clamp(8.0, maxX),
      offset.dy.clamp(8.0, maxY),
    );
  }

  void _toggleKeyboardOverlay() {
    setState(() {
      _keyboardVisible = !_keyboardVisible;
      if (_keyboardVisible) {
        _keyboardPanelTop = null;
      }
    });
  }

  void _toggleCaptureSelectionMode() {
    if (_capturingScreenshot) {
      return;
    }
    setState(() {
      if (_captureSelectionMode) {
        _captureSelectionMode = false;
        _resetCaptureSelectionRect();
      } else {
        _capturePreview = null;
        _captureSelectionMode = true;
        _resetCaptureSelectionRect();
        _keyboardVisible = false;
        _mousePanelExpanded = false;
      }
    });
  }

  Future<void> _confirmCaptureSelection(ControlService controlService) async {
    final viewport = _lastPreviewLayoutSize;
    final remoteW = controlService.remoteWidth;
    final remoteH = controlService.remoteHeight;
    final selectionRect = _captureSelectionRect;
    if (viewport == null ||
        viewport.width <= 0 ||
        viewport.height <= 0 ||
        remoteW == null ||
        remoteH == null ||
        selectionRect == null) {
      return;
    }

    final startPoint = _mapToRemote(
      local: selectionRect.topLeft,
      containerW: viewport.width,
      containerH: viewport.height,
      remoteW: remoteW,
      remoteH: remoteH,
    );
    final endPoint = _mapToRemote(
      local: selectionRect.bottomRight,
      containerW: viewport.width,
      containerH: viewport.height,
      remoteW: remoteW,
      remoteH: remoteH,
    );
    if (startPoint == null || endPoint == null) {
      return;
    }

    final captureLeft = math.min(startPoint.$1, endPoint.$1);
    final captureTop = math.min(startPoint.$2, endPoint.$2);
    final captureWidth =
        math.max(1, (math.max(startPoint.$1, endPoint.$1) - captureLeft) + 1);
    final captureHeight =
        math.max(1, (math.max(startPoint.$2, endPoint.$2) - captureTop) + 1);

    setState(() {
      _capturingScreenshot = true;
    });
    try {
      final result = await controlService.captureScreenshotRegion(
        left: captureLeft,
        top: captureTop,
        width: captureWidth,
        height: captureHeight,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _captureSelectionMode = false;
        _captureDragStart = null;
        _captureSelectionRect = null;
        _captureEditMode = _CaptureEditMode.none;
        _captureEditAnchor = null;
        _captureEditInitialRect = null;
        _capturePreview = result;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('截图失败：$e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _capturingScreenshot = false;
        });
      }
    }
  }

  double _resolvedKeyboardTop(Size viewport) {
    final panelHeight = _resolvedKeyboardHeight(viewport);
    final defaultTop = ((viewport.height - panelHeight) / 2) - 24;
    return _clampKeyboardTop(_keyboardPanelTop ?? defaultTop, viewport);
  }

  double _clampKeyboardTop(double top, Size viewport) {
    final panelHeight = _resolvedKeyboardHeight(viewport);
    final minTop = _showOverlay ? 116.0 : 16.0;
    final maxTop = math.max(minTop, viewport.height - panelHeight - 74.0);
    return top.clamp(minTop, maxTop);
  }

  double _resolvedKeyboardHeight(Size viewport) {
    return math.min(
        _keyboardPanelMaxHeight, math.max(252.0, viewport.height * 0.50));
  }

  Rect? _normalizedCaptureRect(Rect? rect) {
    if (rect == null) return null;
    final normalized = Rect.fromLTRB(
      math.min(rect.left, rect.right),
      math.min(rect.top, rect.bottom),
      math.max(rect.left, rect.right),
      math.max(rect.top, rect.bottom),
    );
    if (normalized.width < 8 || normalized.height < 8) {
      return null;
    }
    return normalized;
  }

  Rect _clampCaptureRect(Rect rect, Size viewport) {
    return Rect.fromLTRB(
      rect.left.clamp(0.0, viewport.width),
      rect.top.clamp(0.0, viewport.height),
      rect.right.clamp(0.0, viewport.width),
      rect.bottom.clamp(0.0, viewport.height),
    );
  }

  void _resetCaptureSelectionRect() {
    _captureDragStart = null;
    _captureSelectionRect = null;
    _captureEditMode = _CaptureEditMode.none;
    _captureEditAnchor = null;
    _captureEditInitialRect = null;
  }

  _CaptureEditMode _detectCaptureHandle(Rect rect, Offset point) {
    const radius = 22.0;
    bool near(Offset target) => (point - target).distance <= radius;
    if (near(rect.topLeft)) return _CaptureEditMode.resizeTopLeft;
    if (near(rect.topRight)) return _CaptureEditMode.resizeTopRight;
    if (near(rect.bottomLeft)) return _CaptureEditMode.resizeBottomLeft;
    if (near(rect.bottomRight)) return _CaptureEditMode.resizeBottomRight;
    return _CaptureEditMode.none;
  }

  Rect _clampMovedRect(Rect rect, Size viewport) {
    final dx = rect.left < 0
        ? -rect.left
        : rect.right > viewport.width
            ? viewport.width - rect.right
            : 0.0;
    final dy = rect.top < 0
        ? -rect.top
        : rect.bottom > viewport.height
            ? viewport.height - rect.bottom
            : 0.0;
    return rect.shift(Offset(dx, dy));
  }

  Rect _resizeCaptureRect(
    Rect initial,
    Offset point,
    _CaptureEditMode mode,
    Size viewport,
  ) {
    const minSize = 24.0;
    double left = initial.left;
    double top = initial.top;
    double right = initial.right;
    double bottom = initial.bottom;

    switch (mode) {
      case _CaptureEditMode.resizeTopLeft:
        left = point.dx.clamp(0.0, right - minSize);
        top = point.dy.clamp(0.0, bottom - minSize);
        break;
      case _CaptureEditMode.resizeTopRight:
        right = point.dx.clamp(left + minSize, viewport.width);
        top = point.dy.clamp(0.0, bottom - minSize);
        break;
      case _CaptureEditMode.resizeBottomLeft:
        left = point.dx.clamp(0.0, right - minSize);
        bottom = point.dy.clamp(top + minSize, viewport.height);
        break;
      case _CaptureEditMode.resizeBottomRight:
        right = point.dx.clamp(left + minSize, viewport.width);
        bottom = point.dy.clamp(top + minSize, viewport.height);
        break;
      case _CaptureEditMode.none:
      case _CaptureEditMode.create:
      case _CaptureEditMode.move:
        break;
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  void _handleCapturePanStart(DragStartDetails details, Size viewport) {
    final position = details.localPosition;
    final existingRect = _captureSelectionRect;
    if (existingRect != null) {
      final handle = _detectCaptureHandle(existingRect, position);
      if (handle != _CaptureEditMode.none) {
        setState(() {
          _captureEditMode = handle;
          _captureEditAnchor = position;
          _captureEditInitialRect = existingRect;
        });
        return;
      }
      if (existingRect.contains(position)) {
        setState(() {
          _captureEditMode = _CaptureEditMode.move;
          _captureEditAnchor = position;
          _captureEditInitialRect = existingRect;
        });
        return;
      }
    }

    setState(() {
      _captureEditMode = _CaptureEditMode.create;
      _captureDragStart = position;
      _captureSelectionRect = Rect.fromPoints(position, position);
      _captureEditAnchor = null;
      _captureEditInitialRect = null;
    });
  }

  void _handleCapturePanUpdate(DragUpdateDetails details, Size viewport) {
    switch (_captureEditMode) {
      case _CaptureEditMode.none:
        return;
      case _CaptureEditMode.create:
        final start = _captureDragStart;
        if (start == null) return;
        final current = details.localPosition;
        setState(() {
          _captureSelectionRect = _clampCaptureRect(
            Rect.fromPoints(start, current),
            viewport,
          );
        });
        return;
      case _CaptureEditMode.move:
        final anchor = _captureEditAnchor;
        final initial = _captureEditInitialRect;
        if (anchor == null || initial == null) return;
        final delta = details.localPosition - anchor;
        setState(() {
          _captureSelectionRect =
              _clampMovedRect(initial.shift(delta), viewport);
        });
        return;
      case _CaptureEditMode.resizeTopLeft:
      case _CaptureEditMode.resizeTopRight:
      case _CaptureEditMode.resizeBottomLeft:
      case _CaptureEditMode.resizeBottomRight:
        final initial = _captureEditInitialRect;
        if (initial == null) return;
        setState(() {
          _captureSelectionRect = _resizeCaptureRect(
            initial,
            details.localPosition,
            _captureEditMode,
            viewport,
          );
        });
        return;
    }
  }

  void _handleCapturePanEnd() {
    setState(() {
      _captureSelectionRect = _normalizedCaptureRect(_captureSelectionRect);
      _captureEditMode = _CaptureEditMode.none;
      _captureEditAnchor = null;
      _captureEditInitialRect = null;
      _captureDragStart = null;
    });
  }

  Widget _buildCaptureSelectionOverlay(ControlService controlService) {
    final remoteW = controlService.remoteWidth;
    final remoteH = controlService.remoteHeight;
    final hasSelection = _captureSelectionRect != null;
    return Positioned.fill(
      child: Material(
        color: Colors.black.withValues(alpha: 0.20),
        child: Stack(
          children: [
            LayoutBuilder(
              builder: (context, constraints) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (details) => _handleCapturePanStart(
                  details,
                  Size(constraints.maxWidth, constraints.maxHeight),
                ),
                onPanUpdate: (details) => _handleCapturePanUpdate(
                  details,
                  Size(constraints.maxWidth, constraints.maxHeight),
                ),
                onPanEnd: (_) => _handleCapturePanEnd(),
                onPanCancel: _handleCapturePanEnd,
                child: CustomPaint(
                  painter:
                      _CaptureSelectionPainter(rect: _captureSelectionRect),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            if (hasSelection)
              Positioned(
                top: 12,
                right: 12,
                child: FilledButton.tonal(
                  onPressed: _capturingScreenshot
                      ? null
                      : () => setState(_resetCaptureSelectionRect),
                  child: const Text('重选'),
                ),
              ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 16,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.78),
                  borderRadius: BorderRadius.circular(14),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.20)),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '拖动框选并继续调整截图区域',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hasSelection && remoteW != null && remoteH != null
                            ? '拖动框内可移动，拖四角可改大小，点确定后电脑端会按原始清晰度截图'
                            : '先在远程画面上拖出一个矩形区域',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _capturingScreenshot
                                  ? null
                                  : _toggleCaptureSelectionMode,
                              child: const Text('取消'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton(
                              onPressed: (!_capturingScreenshot && hasSelection)
                                  ? () =>
                                      _confirmCaptureSelection(controlService)
                                  : null,
                              child:
                                  Text(_capturingScreenshot ? '处理中...' : '确定'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCapturePreviewOverlay() {
    final preview = _capturePreview;
    if (preview == null) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: Material(
        color: Colors.black.withValues(alpha: 0.72),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            child: Column(
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '高清截图',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _capturePreview = null;
                        });
                      },
                      child: const Text('关闭'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  preview.imageWidth > 0 && preview.imageHeight > 0
                      ? '${preview.imageWidth} x ${preview.imageHeight}'
                      : preview.fileName,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InteractiveViewer(
                      minScale: 1,
                      maxScale: 6,
                      child: Center(
                        child: Image.memory(
                          preview.imageBytes,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.high,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '现在可以直接用手机系统的扫屏/OCR识别这张图上的文字',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _handleVirtualKeyPressed(
      ControlService controlService, _VirtualKeyDefinition definition) {
    final mergedModifiers = <_KeyboardModifier>{
      ..._keyboardModifiers,
      ...definition.modifiers,
    };
    final modifierCodes = mergedModifiers
        .map(_virtualKeyCodeForModifier)
        .whereType<int>()
        .toList(growable: false);
    if (modifierCodes.isNotEmpty) {
      controlService.keyCombo(modifierCodes, definition.keyCode);
      setState(() {
        _keyboardModifiers.clear();
      });
      return;
    }
    controlService.keyPress(definition.keyCode);
  }

  int? _virtualKeyCodeForModifier(_KeyboardModifier modifier) {
    return switch (modifier) {
      _KeyboardModifier.ctrl => _vkControl,
      _KeyboardModifier.alt => _vkAlt,
      _KeyboardModifier.shift => _vkShift,
    };
  }

  Future<void> _openBitrateSheet() async {
    final controlService = context.read<ControlService>();
    double localQuality = controlService.qualityScale;
    double localResolution = controlService.resolutionScale;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('码率强度 ${(localQuality * 100).round()}%'),
                  Slider(
                    value: localQuality,
                    min: 0.15,
                    max: 1.0,
                    divisions: 17,
                    label: '${(localQuality * 100).round()}%',
                    onChanged: (value) {
                      setModalState(() {
                        localQuality = value;
                      });
                    },
                    onChangeEnd: (value) {
                      _preferredQualityScale = value;
                      _preferredResolutionScale = localResolution;
                      _preferredDynamicFpsLimit =
                          controlService.dynamicFpsLimit;
                      _preferredStaticFpsLimit = controlService.staticFpsLimit;
                      _usingLocalNetworkPreset = false;
                      controlService.setStreamTuning(
                        qualityScale: value,
                        resolutionScale: localResolution,
                        dynamicFpsLimit: controlService.dynamicFpsLimit,
                        staticFpsLimit: controlService.staticFpsLimit,
                      );
                      _persistPreferences();
                    },
                  ),
                  const SizedBox(height: 8),
                  Text('混合模式活动分辨率 ${(localResolution * 100).round()}%'),
                  Slider(
                    value: localResolution,
                    min: 0.20,
                    max: 1.0,
                    divisions: 16,
                    label: '${(localResolution * 100).round()}%',
                    onChanged: (value) {
                      setModalState(() {
                        localResolution = value;
                      });
                    },
                    onChangeEnd: (value) {
                      _preferredQualityScale = localQuality;
                      _preferredResolutionScale = value;
                      _preferredDynamicFpsLimit =
                          controlService.dynamicFpsLimit;
                      _preferredStaticFpsLimit = controlService.staticFpsLimit;
                      _usingLocalNetworkPreset = false;
                      controlService.setStreamTuning(
                        qualityScale: localQuality,
                        resolutionScale: value,
                        dynamicFpsLimit: controlService.dynamicFpsLimit,
                        staticFpsLimit: controlService.staticFpsLimit,
                      );
                      _persistPreferences();
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openFpsSheet() async {
    final controlService = context.read<ControlService>();
    double localDynamic = controlService.dynamicFpsLimit;
    double localStatic = controlService.staticFpsLimit;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('活动态目标帧率 ${localDynamic.toStringAsFixed(1)} FPS'),
                  Slider(
                    value: localDynamic,
                    min: 1,
                    max: 30,
                    divisions: 29,
                    label: localDynamic.toStringAsFixed(0),
                    onChanged: (value) {
                      setModalState(() {
                        localDynamic = value;
                      });
                    },
                    onChangeEnd: (value) {
                      _preferredQualityScale = controlService.qualityScale;
                      _preferredResolutionScale =
                          controlService.resolutionScale;
                      _preferredDynamicFpsLimit = value;
                      _preferredStaticFpsLimit = localStatic;
                      _usingLocalNetworkPreset = false;
                      controlService.setStreamTuning(
                        qualityScale: controlService.qualityScale,
                        resolutionScale: controlService.resolutionScale,
                        dynamicFpsLimit: value,
                        staticFpsLimit: localStatic,
                      );
                      _persistPreferences();
                    },
                  ),
                  Text('静止态保底刷新 ${localStatic.toStringAsFixed(1)} FPS'),
                  Slider(
                    value: localStatic,
                    min: 1,
                    max: 10,
                    divisions: 9,
                    label: localStatic.toStringAsFixed(0),
                    onChanged: (value) {
                      setModalState(() {
                        localStatic = value;
                      });
                    },
                    onChangeEnd: (value) {
                      _preferredQualityScale = controlService.qualityScale;
                      _preferredResolutionScale =
                          controlService.resolutionScale;
                      _preferredDynamicFpsLimit = localDynamic;
                      _preferredStaticFpsLimit = value;
                      _usingLocalNetworkPreset = false;
                      controlService.setStreamTuning(
                        qualityScale: controlService.qualityScale,
                        resolutionScale: controlService.resolutionScale,
                        dynamicFpsLimit: localDynamic,
                        staticFpsLimit: value,
                      );
                      _persistPreferences();
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openScrollVideoTuningSheet() async {
    final controlService = context.read<ControlService>();
    final profile = _preferredStreamProfile;
    final initialTuning = _scrollVideoTuningFor(profile);
    double localScale = initialTuning.scale;
    int localBitrate = initialTuning.bitrateKbps;
    double localFps = initialTuning.fps;
    int localCrf = initialTuning.crf;
    int localVbvMultiplier = initialTuning.vbvMultiplier;
    String localPixelFormat = initialTuning.pixelFormat;
    String localPreset = initialTuning.preset;
    int localRestoreDelayMs = initialTuning.restoreDelayMs;

    void apply() {
      _scrollVideoTunings[profile] = _ScrollVideoTuning(
        scale: localScale,
        bitrateKbps: localBitrate,
        fps: localFps,
        crf: localCrf,
        vbvMultiplier: localVbvMultiplier,
        pixelFormat: localPixelFormat,
        preset: localPreset,
        restoreDelayMs: localRestoreDelayMs,
      );
      _syncPreferredScrollVideoTuning(profile);
      controlService.setScrollVideoTuning(
        scale: localScale,
        bitrateKbps: localBitrate,
        fps: localFps,
        crf: localCrf,
        vbvMultiplier: localVbvMultiplier,
        pixelFormat: localPixelFormat,
        preset: localPreset,
      );
      _persistPreferences();
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            Widget sliderRow({
              required String title,
              required String valueText,
              required double value,
              required double min,
              required double max,
              required int divisions,
              required ValueChanged<double> onChanged,
              required ValueChanged<double> onChangeEnd,
            }) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(title)),
                      Text(valueText),
                    ],
                  ),
                  Slider(
                    value: value,
                    min: min,
                    max: max,
                    divisions: divisions,
                    label: valueText,
                    onChanged: onChanged,
                    onChangeEnd: onChangeEnd,
                  ),
                ],
              );
            }

            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '滚动视频调试',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    sliderRow(
                      title: '滚动分辨率比例',
                      valueText: '${(localScale * 100).round()}%',
                      value: localScale,
                      min: 0.30,
                      max: 1.0,
                      divisions: 70,
                      onChanged: (value) {
                        setModalState(() => localScale = value);
                      },
                      onChangeEnd: (_) => apply(),
                    ),
                    sliderRow(
                      title: '滚动码率上限',
                      valueText: '$localBitrate kbps',
                      value: localBitrate.toDouble(),
                      min: 128,
                      max: profile == StreamProfile.lan ? 60000 : 12000,
                      divisions: profile == StreamProfile.lan ? 374 : 297,
                      onChanged: (value) {
                        setModalState(() {
                          localBitrate = (value / 40).round() * 40;
                        });
                      },
                      onChangeEnd: (_) => apply(),
                    ),
                    sliderRow(
                      title: '滚动目标帧率',
                      valueText: '${localFps.toStringAsFixed(0)} FPS',
                      value: localFps,
                      min: 5,
                      max: 60,
                      divisions: 55,
                      onChanged: (value) {
                        setModalState(() => localFps = value);
                      },
                      onChangeEnd: (_) => apply(),
                    ),
                    sliderRow(
                      title: '滚动 CRF',
                      valueText:
                          localCrf == 0 ? '0 near lossless' : '$localCrf',
                      value: localCrf.toDouble(),
                      min: 0,
                      max: 38,
                      divisions: 38,
                      onChanged: (value) {
                        setModalState(() => localCrf = value.round());
                      },
                      onChangeEnd: (_) => apply(),
                    ),
                    sliderRow(
                      title: 'VBV buffer x',
                      valueText: '${localVbvMultiplier}x',
                      value: localVbvMultiplier.toDouble(),
                      min: 2,
                      max: 8,
                      divisions: 6,
                      onChanged: (value) {
                        setModalState(() {
                          localVbvMultiplier = value.round();
                        });
                      },
                      onChangeEnd: (_) => apply(),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue:
                          localPixelFormat == 'yuv444p' ? 'yuv444p' : 'yuv420p',
                      decoration: const InputDecoration(
                        labelText: 'Pixel format',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'yuv420p',
                          child: Text('yuv420p'),
                        ),
                        DropdownMenuItem(
                          value: 'yuv444p',
                          child: Text('yuv444p test'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setModalState(() => localPixelFormat = value);
                        apply();
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: {
                        'ultrafast',
                        'superfast',
                        'veryfast',
                        'faster',
                        'fast',
                      }.contains(localPreset)
                          ? localPreset
                          : 'veryfast',
                      decoration: const InputDecoration(
                        labelText: 'Encoder preset',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'ultrafast',
                          child: Text('ultrafast'),
                        ),
                        DropdownMenuItem(
                          value: 'superfast',
                          child: Text('superfast'),
                        ),
                        DropdownMenuItem(
                          value: 'veryfast',
                          child: Text('veryfast'),
                        ),
                        DropdownMenuItem(
                          value: 'faster',
                          child: Text('faster'),
                        ),
                        DropdownMenuItem(
                          value: 'fast',
                          child: Text('fast'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setModalState(() => localPreset = value);
                        apply();
                      },
                    ),
                    const SizedBox(height: 12),
                    sliderRow(
                      title: '停止后恢复延迟',
                      valueText: '$localRestoreDelayMs ms',
                      value: localRestoreDelayMs.toDouble(),
                      min: 100,
                      max: 1200,
                      divisions: 22,
                      onChanged: (value) {
                        setModalState(() {
                          localRestoreDelayMs = (value / 50).round() * 50;
                        });
                      },
                      onChangeEnd: (_) => apply(),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () {
                            final defaults = _defaultScrollVideoTuning(profile);
                            setModalState(() {
                              localScale = defaults.scale;
                              localBitrate = defaults.bitrateKbps;
                              localFps = defaults.fps;
                              localCrf = defaults.crf;
                              localVbvMultiplier = defaults.vbvMultiplier;
                              localPixelFormat = defaults.pixelFormat;
                              localPreset = defaults.preset;
                              localRestoreDelayMs = defaults.restoreDelayMs;
                            });
                            apply();
                          },
                          child: const Text('恢复默认'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _sendText() {
    _autoSubmitTimer?.cancel();
    final text = _textController.text;
    if (text.trim().isEmpty) return;
    _sendTextValue(text);
    _textController.clear();
    if (_inputMode != InputMode.textOnly) {
      _textFocusNode.unfocus();
    }
  }

  void _sendTextValue(String text) {
    if (text.trim().isEmpty) return;
    final controlService = context.read<ControlService>();
    final diagId =
        'text-${DateTime.now().millisecondsSinceEpoch}-${++_textSendSeq}';
    controlService.sendScrollDiagnostic({
      'event': 'text_send_requested',
      'diag_id': diagId,
      'connection_diag_id': _connectionDiagId,
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
      'text_length': text.length,
      'input_mode': _inputMode.name,
      'stream_profile': controlService.streamProfile.name,
      'selected_hwnd': controlService.selectedHwnd,
      'h264_available': controlService.usingH264Video,
      'h264_negotiating': controlService.h264VideoStream.negotiating,
      'last_frame_at_ms': controlService.lastFrameAt?.millisecondsSinceEpoch,
      'last_h264_frame_at_ms': controlService
          .h264VideoStream.lastRenderedFrameAt?.millisecondsSinceEpoch,
      'handshake_progress': controlService.videoHandshakeProgress,
    });
    controlService.pasteText(text, diagId: diagId);
    _expectVisualChange(
      controlService,
      sent: true,
      nowMs: DateTime.now().millisecondsSinceEpoch,
      reason: 'text_send:$diagId',
    );
    _rememberSentText(text);
  }

  Future<void> _rememberSentText(String text) async {
    final normalized = text.trim();
    if (normalized.isEmpty) return;
    final next = <String>[
      normalized,
      ..._sendHistory.where((item) => item.trim() != normalized),
    ].take(50).toList(growable: false);
    if (mounted) {
      setState(() {
        _sendHistory = next;
      });
    } else {
      _sendHistory = next;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_sendHistoryPrefsKey, next);
  }

  Future<void> _openSendHistorySheet() async {
    if (_sendHistory.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('\u6682\u65e0\u53d1\u9001\u5386\u53f2')),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: _sendHistory.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final text = _sendHistory[index];
              return ListTile(
                dense: true,
                title: Text(
                  text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.send, size: 18),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _sendTextValue(text);
                },
              );
            },
          ),
        );
      },
    );
  }

  void _handleTextInputChanged() {
    _autoSubmitTimer?.cancel();
    if (!_autoSubmitText || _inputMode != InputMode.textOnly) {
      return;
    }
    _autoSubmitTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !_autoSubmitText || _inputMode != InputMode.textOnly) {
        return;
      }
      _sendText();
    });
  }

  Future<void> _disconnectAndExit() async {
    final controlService = context.read<ControlService>();
    if (_didFitWindow &&
        controlService.selectedHwnd != null &&
        controlService.selectedHwnd != -1) {
      controlService.restoreWindow();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      _didFitWindow = false;
    }
    controlService.disconnect();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (route) => false,
    );
  }

  String _lanDirectServerUrl(
      String primaryIp, List<String> candidateIps, int port) {
    if (port <= 0) return '';
    final candidates = <String>[primaryIp, ...candidateIps];
    for (final item in candidates) {
      final value = item.trim();
      if (value.isNotEmpty) return 'ws://$value:$port';
    }
    return '';
  }

  Future<void> _startConnection() async {
    setState(() {
      _connectionFailed = false;
      _connectionStage = '正在解析服务器地址...';
    });
    try {
      await _connectWithTimeout();
    } catch (e) {
      if (mounted) {
        setState(() {
          _connectionFailed = true;
          _connectionErrorMessage = e.toString();
          _connectionStage = '';
        });
      }
    }
  }

  Future<void> _connectWithTimeout() async {
    await Future.any([
      _doConnectSteps(),
      Future.delayed(const Duration(seconds: 30),
          () => throw Exception('连接超时，请检查网络后重试')),
    ]);
  }

  Future<void> _doConnectSteps() async {
    final signaling = context.read<SignalingService>();
    final control = context.read<ControlService>();
    final resolvedEndpoint = await ServerEndpointResolver.resolveEndpoint(
      localServerUrl: widget.localServerUrl,
      fallbackServerUrl: widget.fallbackServerUrl,
    );

    setState(() => _connectionStage = '正在检测网络环境...');
    final initialIsLocalNetwork =
        await NetworkRouteResolver.isSameLocalNetwork(
      resolvedServerUrl: resolvedEndpoint.serverUrl,
      deviceLocalIp: widget.deviceLocalIp,
      expectedDeviceId: widget.deviceId,
      deviceLocalIps: widget.deviceLocalIps,
      deviceLanProbePort: widget.deviceLanProbePort,
      forceRefresh: true,
    );

    final lanDirectCandidateUrl = _lanDirectServerUrl(
        widget.deviceLocalIp, widget.deviceLocalIps,
        widget.deviceLanDirectPort);
    final lanDirectUrl = initialIsLocalNetwork ? lanDirectCandidateUrl : '';

    final publicDirectHost = widget.publicDirectHost?.trim() ?? '';
    final publicDirectPort = widget.publicDirectPort;
    String? publicDirectUrlFromInfo;
    if (!initialIsLocalNetwork && publicDirectHost.isNotEmpty && publicDirectPort > 0) {
      publicDirectUrlFromInfo = 'ws://$publicDirectHost:$publicDirectPort';
    }
    final publicDirectAttempt = await PublicDirectClient.tryPrepare(
      expectedDeviceId: widget.deviceId,
    );
    final effectivePublicDirect = publicDirectAttempt != null
        ? publicDirectAttempt
        : (publicDirectUrlFromInfo != null
            ? PublicDirectAttempt(
                serverUrl: publicDirectUrlFromInfo,
                totpCode: '',
                totpNonce: '',
                config: PublicDirectConfig(
                  host: publicDirectHost,
                  port: publicDirectPort,
                  deviceId: widget.deviceId,
                  totpSecret: '',
                ),
              )
            : null);

    setState(() {
      _isLocalNetworkConnection = initialIsLocalNetwork;
      _connectionStage = '正在连接信令服务器...';
    });

    if (effectivePublicDirect != null) {
      signaling.serverUrl = effectivePublicDirect.serverUrl;
    } else {
      signaling.serverUrl =
          lanDirectUrl.isNotEmpty ? lanDirectUrl : resolvedEndpoint.serverUrl;
    }
    signaling.roomId = widget.roomId;
    signaling.clientId = widget.clientId;
    signaling.clientName = widget.clientName;
    signaling.deviceId = widget.deviceId;
    if (effectivePublicDirect != null) {
      signaling.setPublicDirectAuth(
        totpCode: effectivePublicDirect.totpCode,
        totpNonce: effectivePublicDirect.totpNonce,
      );
    } else {
      signaling.clearPublicDirectAuth();
    }
    control.setSignalingService(signaling);

    try {
      await signaling.connect();
    } catch (_) {
      // Cascade: public-direct → LAN-direct → signaling relay.
      if (effectivePublicDirect != null) {
        signaling.disconnect();
        signaling.clearPublicDirectAuth();
        final fallbackUrl = lanDirectUrl.isNotEmpty
            ? lanDirectUrl
            : resolvedEndpoint.serverUrl;
        signaling.serverUrl = fallbackUrl;
        signaling.roomId = widget.roomId;
        signaling.clientId = widget.clientId;
        signaling.clientName = widget.clientName;
        signaling.deviceId = widget.deviceId;
        try {
          await signaling.connect();
        } catch (_) {
          if (lanDirectUrl.isEmpty || fallbackUrl == resolvedEndpoint.serverUrl) {
            rethrow;
          }
          signaling.disconnect();
          signaling.serverUrl = resolvedEndpoint.serverUrl;
          signaling.roomId = widget.roomId;
          signaling.clientId = widget.clientId;
          signaling.clientName = widget.clientName;
          signaling.deviceId = widget.deviceId;
          await signaling.connect();
        }
      } else {
        if (lanDirectUrl.isEmpty) rethrow;
        signaling.disconnect();
        signaling.serverUrl = resolvedEndpoint.serverUrl;
        signaling.roomId = widget.roomId;
        signaling.clientId = widget.clientId;
        signaling.clientName = widget.clientName;
        signaling.deviceId = widget.deviceId;
        await signaling.connect();
      }
    }

    control.setConnected(true, roomId: widget.roomId);

    setState(() {
      _connectionStage = '';
    });
  }

  Future<void> _selectWindow() async {
    final signaling = context.read<SignalingService>();
    final controlService = context.read<ControlService>();
    final shouldRefitWindow =
        _didFitWindow || controlService.selectedHwnd == null;
    final selected = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => WindowSelectorScreen(
          roomId: _activeRoomId,
          signaling: signaling,
          controlService: controlService,
        ),
      ),
    );

    if (!mounted || selected == null) return;
    final hwnd = selected['hwnd'];
    final title = selected['title']?.toString();
    if (hwnd is int) {
      controlService.setWindow(hwnd);
      _resetBrowseTransform();
      setState(() {
        _didFitWindow = false;
        _lastSelectedHwnd = hwnd;
        _lastSelectedTitle = title;
      });
      _handleModeChanged(_inputMode);
      _persistPreferences();
      if (shouldRefitWindow) {
        _refitWindowAfterSelection();
      }
    }
  }

  Future<void> _refitWindowAfterSelection() async {
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted || _didFitWindow) return;
    _fitWindowToPhone(auto: true);
  }

  void _updatePreviewLayoutSize(Size size) {
    _lastPreviewLayoutSize = size;
    if (size.width <= 0 || size.height <= 0) return;
    if (!_keyboardInsetsActive()) {
      final stable = _stableFitViewportSize;
      if (stable == null ||
          size.width * size.height >= stable.width * stable.height) {
        _stableFitViewportSize = size;
        _cachedControlService?.sendScrollDiagnostic({
          'event': 'stable_fit_viewport_updated',
          'diag_id': _connectionDiagId,
          'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
          'width': size.width,
          'height': size.height,
          'keyboard_active': false,
        });
      }
    }
  }

  bool _keyboardInsetsActive() {
    final mediaQuery = MediaQuery.maybeOf(context);
    return (mediaQuery?.viewInsets.bottom ?? 0) > 0;
  }

  void _maybeFitInitialWindow(ControlService controlService) {
    if (_initialFitRequested ||
        _didFitWindow ||
        controlService.selectedHwnd == null ||
        controlService.selectedHwnd == -1 ||
        _stableFitViewportSize == null) {
      return;
    }
    _initialFitRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (!mounted || _didFitWindow) return;
      _fitWindowToPhone(auto: true);
    });
  }

  void _handleWindowScaleChanged(int percent) {
    final normalized = percent.clamp(30, 100).toInt();
    setState(() {
      _windowScalePercent = normalized;
    });
    _persistPreferences();
    final controlService = context.read<ControlService>();
    if (controlService.selectedHwnd != null &&
        controlService.selectedHwnd != -1) {
      _fitWindowToPhone(auto: true);
    }
  }

  void _fitWindowToPhone({bool auto = false}) {
    final controlService = context.read<ControlService>();
    if (controlService.selectedHwnd == null ||
        controlService.selectedHwnd == -1) {
      controlService.setStatus('桌面模式不支持窗口全屏适配');
      return;
    }

    if (!auto && _didFitWindow) {
      controlService.restoreWindow();
      _resetBrowseTransform();
      setState(() {
        _didFitWindow = false;
        _fitViewportPersisted = false;
      });
      _persistPreferences();
      return;
    }

    final viewportSize = _stableFitViewportSize ?? _lastPreviewLayoutSize;
    if (viewportSize == null ||
        viewportSize.width <= 0 ||
        viewportSize.height <= 0) {
      controlService.setStatus('无法获取手机预览区域尺寸');
      return;
    }
    final pixelRatio = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    final physicalViewportSize = Size(
      viewportSize.width * pixelRatio,
      viewportSize.height * pixelRatio,
    );

    controlService.setStatus(
      '窗口 $_windowScalePercent% ${physicalViewportSize.width.round()}x${physicalViewportSize.height.round()}',
    );
    controlService.fitWindowToViewport(
      viewportWidth: physicalViewportSize.width,
      viewportHeight: physicalViewportSize.height,
      padding: 0,
      windowScalePercent: _windowScalePercent,
    );
    controlService.sendScrollDiagnostic({
      'event': 'fit_window_to_phone_sent',
      'diag_id': _connectionDiagId,
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
      'width': physicalViewportSize.width,
      'height': physicalViewportSize.height,
      'logical_width': viewportSize.width,
      'logical_height': viewportSize.height,
      'device_pixel_ratio': pixelRatio,
      'window_scale_percent': _windowScalePercent,
      'auto': auto,
      'keyboard_active': _keyboardInsetsActive(),
      'fit_persisted_before': _fitViewportPersisted,
    });
    _resetBrowseTransform();
    setState(() {
      _didFitWindow = true;
      _fitViewportPersisted = true;
    });
    _persistPreferences();
  }

  void _deleteRemoteText() {
    context.read<ControlService>().deleteLastChar();
  }

  void _startRepeatingDelete() {
    _repeatDeleteTimer?.cancel();
    _deleteRemoteText();
    _repeatDeleteTimer = Timer.periodic(const Duration(milliseconds: 45), (_) {
      if (!mounted) {
        return;
      }
      _deleteRemoteText();
    });
  }

  void _stopRepeatingDelete() {
    _repeatDeleteTimer?.cancel();
    _repeatDeleteTimer = null;
  }

  void _handleModeChanged(InputMode mode) {
    _autoSubmitTimer?.cancel();
    _stopRepeatingDelete();
    setState(() {
      _inputMode = mode;
      if (mode != InputMode.touchpad) {
        _mousePanelExpanded = false;
      }
    });
    context.read<ControlService>().setVideoPaused(mode == InputMode.textOnly);
    if (mode == InputMode.touchpad) {
      context.read<ControlService>().centerCursor();
    } else {
      _deactivateScrollBoost();
    }
    _terminalScrollGesturePrimed = false;
  }

  void _scheduleAutoSelectInitialWindow() {
    if (!mounted || _autoSelectWindowDone || _autoSelectWindowInFlight) return;
    _autoSelectWindowTimer?.cancel();
    _autoSelectWindowTimer = Timer(const Duration(milliseconds: 450), () {
      unawaited(_autoSelectInitialWindowIfNeeded());
    });
  }

  Future<void> _autoSelectInitialWindowIfNeeded() async {
    if (!mounted || _autoSelectWindowDone || _autoSelectWindowInFlight) return;
    final controlService = context.read<ControlService>();
    if (controlService.selectedHwnd != null || _lastSelectedHwnd != null) {
      _autoSelectWindowDone = true;
      controlService.sendScrollDiagnostic({
        'event': 'initial_window_auto_select_skipped',
        'diag_id': _connectionDiagId,
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'selected_hwnd': controlService.selectedHwnd,
        'last_selected_hwnd': _lastSelectedHwnd,
      });
      return;
    }
    final signaling = context.read<SignalingService>();
    if (!signaling.isConnected) return;

    _autoSelectWindowInFlight = true;
    controlService.sendScrollDiagnostic({
      'event': 'initial_window_auto_select_start',
      'diag_id': _connectionDiagId,
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
      'signaling_connected': signaling.isConnected,
    });
    final previousHandler = signaling.onWindowsList;
    final completer = Completer<List<dynamic>>();

    void handleWindowsList(Map<String, dynamic> data) {
      final list = data['windows'];
      if (list is List && !completer.isCompleted) {
        completer.complete(list);
      }
      previousHandler?.call(data);
    }

    signaling.onWindowsList = handleWindowsList;
    signaling.requestWindowsList();

    try {
      final list = await completer.future.timeout(const Duration(seconds: 4));
      if (!mounted) return;
      controlService.sendScrollDiagnostic({
        'event': 'initial_window_auto_select_list',
        'diag_id': _connectionDiagId,
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'window_count': list.length,
      });
      final selected = list.cast<dynamic>().firstWhere(
        (item) {
          if (item is! Map) return false;
          final hwnd = item['hwnd'];
          final title = item['title']?.toString().trim() ?? '';
          return hwnd is int && hwnd != 0 && title.isNotEmpty;
        },
        orElse: () => null,
      );
      if (selected is! Map) return;
      final hwnd = selected['hwnd'];
      final title = selected['title']?.toString();
      if (hwnd is! int) return;

      controlService.setWindow(hwnd);
      _resetBrowseTransform();
      setState(() {
        _lastSelectedHwnd = hwnd;
        _lastSelectedTitle = title;
        _didFitWindow = false;
        _autoSelectWindowDone = true;
      });
      _handleModeChanged(_inputMode);
      _persistPreferences();
      _refitWindowAfterSelection();
      controlService.sendScrollDiagnostic({
        'event': 'initial_window_auto_selected',
        'diag_id': _connectionDiagId,
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'hwnd': hwnd,
        'title': title ?? '',
      });
    } catch (e) {
      controlService.sendScrollDiagnostic({
        'event': 'initial_window_auto_select_failed',
        'diag_id': _connectionDiagId,
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'error': e.toString(),
      });
    } finally {
      if (identical(signaling.onWindowsList, handleWindowsList)) {
        signaling.onWindowsList = previousHandler;
      }
      _autoSelectWindowInFlight = false;
    }
  }

  void _activateScrollBoost(ControlService controlService) {
    _scrollBoostRestoreTimer?.cancel();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_scrollBoostActive &&
        nowMs - _lastScrollBoostKeepAliveTsMs <
            _terminalScrollBoostKeepAliveMs) {
      return;
    }
    _scrollBoostActive = true;
    _lastScrollBoostKeepAliveTsMs = nowMs;
    controlService.setScrollMode(true);
  }

  void _scheduleScrollBoostRestore() {
    _scrollBoostRestoreTimer?.cancel();
    if (!_scrollBoostActive) {
      return;
    }
    _scrollBoostRestoreTimer = Timer(
      Duration(milliseconds: _preferredScrollRestoreDelayMs),
      () {
        _deactivateScrollBoost();
      },
    );
  }

  void _deactivateScrollBoost() {
    _scrollBoostRestoreTimer?.cancel();
    _scrollBoostRestoreTimer = null;
    if (!_scrollBoostActive || !mounted) {
      return;
    }
    _scrollBoostActive = false;
    _lastScrollBoostKeepAliveTsMs = 0;
    context.read<ControlService>().setScrollMode(false);
  }

  void _startTerminalScrollGesture(
    ControlService controlService,
    String surface,
  ) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _terminalScrollGestureId = 'scroll-$nowMs';
    _terminalScrollWheelSeq = 0;
    _terminalScrollTotalDy = 0.0;
    _terminalScrollTouchUpdates = 0;
    _terminalScrollAccumDy = 0.0;
    _lastTerminalScrollSampleTsMs = nowMs;
    _lastTerminalScrollEmitTsMs = 0;
    _terminalScrollGesturePrimed = false;
    controlService.sendScrollDiagnostic({
      'event': 'gesture_start',
      'gesture_id': _terminalScrollGestureId,
      'client_ts_ms': nowMs,
      'surface': surface,
      'input_mode': _inputMode.name,
    });
  }

  Widget _buildRawScrollPointerLayer({
    required ControlService controlService,
    required String surface,
    required Widget child,
  }) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (_rawScrollPointerId != null) return;
        _rawScrollPointerId = event.pointer;
        _rawScrollLastPosition = event.position;
        _rawScrollSurface = surface;
        _rawScrollRecognized = false;
        _startTerminalScrollGesture(controlService, surface);
        _activateScrollBoost(controlService);
        controlService.sendScrollDiagnostic({
          'event': 'raw_pointer_down',
          'gesture_id': _terminalScrollGestureId,
          'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
          'surface': surface,
          'pointer': event.pointer,
        });
      },
      onPointerMove: (event) {
        if (_rawScrollPointerId != event.pointer) return;
        final previous = _rawScrollLastPosition;
        _rawScrollLastPosition = event.position;
        if (previous == null) return;

        final delta = event.position - previous;
        final absDx = delta.dx.abs();
        final absDy = delta.dy.abs();
        final isScrollGesture = absDy > absDx * 0.55 && absDy >= 0.35;
        if (!isScrollGesture) return;
        _rawScrollRecognized = true;

        final now = DateTime.now().millisecondsSinceEpoch;
        final dtMs = _lastTerminalScrollSampleTsMs == 0
            ? 8
            : (now - _lastTerminalScrollSampleTsMs).clamp(1, 1000);
        _lastTerminalScrollSampleTsMs = now;
        final velocity = math.max(absDy / dtMs, _terminalScrollVelocityMedium);
        _emitAcceleratedTerminalScroll(
          controlService,
          delta.dy,
          velocity,
          dtMs,
          now,
        );
      },
      onPointerUp: (event) {
        if (_rawScrollPointerId != event.pointer) return;
        controlService.sendScrollDiagnostic({
          'event': 'raw_pointer_up',
          'gesture_id': _terminalScrollGestureId,
          'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
          'surface': _rawScrollSurface,
          'pointer': event.pointer,
        });
        _rawScrollPointerId = null;
        _rawScrollLastPosition = null;
        _rawScrollSurface = '';
        _rawScrollRecognized = false;
        _handleTerminalScrollEnd();
      },
      onPointerCancel: (event) {
        if (_rawScrollPointerId != event.pointer) return;
        controlService.sendScrollDiagnostic({
          'event': 'raw_pointer_cancel',
          'gesture_id': _terminalScrollGestureId,
          'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
          'surface': _rawScrollSurface,
          'pointer': event.pointer,
        });
        _rawScrollPointerId = null;
        _rawScrollLastPosition = null;
        _rawScrollSurface = '';
        _rawScrollRecognized = false;
        _handleTerminalScrollEnd();
      },
      child: child,
    );
  }

  void _sendScrollTouchDiagnostic(
    ControlService controlService,
    double deltaY,
    double velocity,
    int dtMs,
    int nowMs,
  ) {
    _terminalScrollTouchUpdates += 1;
    _terminalScrollTotalDy += deltaY;
    controlService.sendScrollDiagnostic({
      'event': 'touch_update',
      'gesture_id': _terminalScrollGestureId,
      'client_ts_ms': nowMs,
      'delta_y': deltaY,
      'velocity': velocity,
      'dt_ms': dtMs,
      'touch_updates': _terminalScrollTouchUpdates,
      'total_delta_y': _terminalScrollTotalDy,
    });
  }

  void _sendScrollNoWheelDiagnostic(
    ControlService controlService,
    double deltaY,
    double velocity,
    int dtMs,
    int nowMs,
    String reason, {
    double? threshold,
    int? intervalMs,
  }) {
    controlService.sendScrollDiagnostic({
      'event': 'touch_update_no_wheel',
      'gesture_id': _terminalScrollGestureId,
      'client_ts_ms': nowMs,
      'delta_y': deltaY,
      'velocity': velocity,
      'dt_ms': dtMs,
      'reason': reason,
      'threshold': threshold,
      'interval_ms': intervalMs,
      'since_last_emit_ms': _lastTerminalScrollEmitTsMs == 0
          ? null
          : nowMs - _lastTerminalScrollEmitTsMs,
      'accum_delta_y': _terminalScrollAccumDy,
      'touch_updates': _terminalScrollTouchUpdates,
      'wheel_count': _terminalScrollWheelSeq,
      'total_delta_y': _terminalScrollTotalDy,
    });
  }

  void _sendDiagnosticMouseWheel(
    ControlService controlService,
    int delta,
    double deltaY,
    double velocity,
    int nowMs,
    String reason,
  ) {
    _terminalScrollWheelSeq += 1;
    final wheelId =
        '${_terminalScrollGestureId ?? 'scroll'}-w$_terminalScrollWheelSeq';
    final diagnostic = {
      'event': 'wheel_sent',
      'gesture_id': _terminalScrollGestureId,
      'wheel_id': wheelId,
      'client_ts_ms': nowMs,
      'delta': delta,
      'wheel_delta': delta * _terminalScrollWheelUnit,
      'delta_y': deltaY,
      'velocity': velocity,
      'reason': reason,
      'wheel_seq': _terminalScrollWheelSeq,
      'touch_updates': _terminalScrollTouchUpdates,
      'total_delta_y': _terminalScrollTotalDy,
    };
    controlService.sendScrollDiagnostic({
      ...diagnostic,
      'event': 'wheel_send_attempt',
    });
    controlService.sendScrollDiagnostic(diagnostic);
    final sent = controlService.mouseWheel(
      delta,
      wheelDelta: delta * _terminalScrollWheelUnit,
      diagnostic: diagnostic,
    );
    if (!sent) {
      controlService.sendScrollDiagnostic({
        ...diagnostic,
        'event': 'wheel_send_skipped',
        'reason': 'control_send_failed',
      });
    }
    _expectVisualChange(
      controlService,
      sent: sent,
      nowMs: nowMs,
      reason: 'wheel_scroll',
    );
  }

  void _expectVisualChange(
    ControlService controlService, {
    required bool sent,
    required int nowMs,
    required String reason,
  }) {
    if (!mounted) return;
    if (!sent) {
      controlService.sendScrollDiagnostic({
        'event': 'visual_expectation_send_failed',
        'client_ts_ms': nowMs,
        'reason': reason,
      });
      return;
    }
    _visualExpectationTimer?.cancel();
    _visualExpectationGeneration += 1;
    _visualExpectationStartedAtMs = nowMs;
    _visualExpectationBaselineFrameAt =
        controlService.h264VideoStream.lastRenderedFrameAt ??
            controlService.lastFrameAt;
    _visualExpectationRestartRequested = false;
    controlService.sendScrollDiagnostic({
      'event': 'visual_expectation_started',
      'client_ts_ms': nowMs,
      'reason': reason,
      'baseline_frame_at_ms':
          _visualExpectationBaselineFrameAt?.millisecondsSinceEpoch,
    });
    _scheduleVisualExpectationCheck(
      controlService,
      _visualExpectationGeneration,
    );
  }

  void _scheduleVisualExpectationCheck(
    ControlService controlService,
    int generation,
  ) {
    _visualExpectationTimer?.cancel();
    _visualExpectationTimer = Timer(const Duration(milliseconds: 500), () {
      _checkVisualExpectation(controlService, generation);
    });
  }

  void _checkVisualExpectation(
    ControlService controlService,
    int generation,
  ) {
    if (!mounted || generation != _visualExpectationGeneration) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final latestFrameAt = controlService.h264VideoStream.lastRenderedFrameAt ??
        controlService.lastFrameAt;
    final baseline = _visualExpectationBaselineFrameAt;
    final hasNewFrame = latestFrameAt != null &&
        (baseline == null || latestFrameAt.isAfter(baseline));
    if (hasNewFrame) {
      controlService.sendScrollDiagnostic({
        'event': 'visual_expectation_satisfied',
        'client_ts_ms': nowMs,
        'elapsed_ms': nowMs - _visualExpectationStartedAtMs,
        'latest_frame_at_ms': latestFrameAt.millisecondsSinceEpoch,
      });
      return;
    }

    final elapsedMs = nowMs - _visualExpectationStartedAtMs;
    if (elapsedMs >= 5000) {
      controlService.sendScrollDiagnostic({
        'event': 'visual_expectation_timeout',
        'client_ts_ms': nowMs,
        'elapsed_ms': elapsedMs,
        'baseline_frame_at_ms': baseline?.millisecondsSinceEpoch,
        'latest_frame_at_ms': latestFrameAt?.millisecondsSinceEpoch,
      });
      return;
    }

    if (elapsedMs >= 2000 && !_visualExpectationRestartRequested) {
      _visualExpectationRestartRequested = true;
      final sent = controlService.requestVideoRestart(
        reason: 'visual-expectation-timeout',
      );
      controlService.sendScrollDiagnostic({
        'event': 'visual_expectation_video_restart',
        'client_ts_ms': nowMs,
        'elapsed_ms': elapsedMs,
        'sent': sent,
        'baseline_frame_at_ms': baseline?.millisecondsSinceEpoch,
        'latest_frame_at_ms': latestFrameAt?.millisecondsSinceEpoch,
      });
    }

    _scheduleVisualExpectationCheck(controlService, generation);
  }

  double _terminalScrollThresholdForVelocity(double velocity) {
    return velocity >= _terminalScrollVelocityFast * 1.65
        ? _terminalScrollThresholdFling
        : velocity >= _terminalScrollVelocityFast
            ? _terminalScrollThresholdFast
            : velocity >= _terminalScrollVelocityMedium
                ? _terminalScrollThresholdMedium
                : velocity >= _terminalScrollVelocitySlow
                    ? _terminalScrollThresholdSlow
                    : _terminalScrollThresholdPrecise;
  }

  int _terminalScrollMaxStepsForVelocity(double velocity) {
    if (velocity >= _terminalScrollVelocityFast * 1.65) {
      return 8;
    }
    if (velocity >= _terminalScrollVelocityFast) {
      return 5;
    }
    if (velocity >= _terminalScrollVelocityMedium) {
      return 3;
    }
    if (velocity >= _terminalScrollVelocitySlow) {
      return 2;
    }
    return 1;
  }

  void _clampTerminalScrollCarry(double threshold) {
    final maxCarry = threshold * _terminalScrollMaxCarryThresholds;
    if (_terminalScrollAccumDy.abs() > maxCarry) {
      _terminalScrollAccumDy = _terminalScrollAccumDy.sign * maxCarry;
    }
  }

  bool _flushTerminalScrollAccum(
    ControlService controlService, {
    required double deltaY,
    required double velocity,
    required int dtMs,
    required int nowMs,
    required String reason,
    required bool force,
  }) {
    final threshold = _terminalScrollThresholdForVelocity(velocity);
    if (_terminalScrollAccumDy.abs() < threshold) {
      if (!force) {
        _sendScrollNoWheelDiagnostic(
          controlService,
          deltaY,
          velocity,
          dtMs,
          nowMs,
          'below_threshold',
          threshold: threshold,
        );
      }
      return false;
    }

    final direction = _terminalScrollAccumDy < 0 ? -1 : 1;
    final rawSteps = force
        ? math.max(1, (_terminalScrollAccumDy.abs() / threshold).ceil())
        : (_terminalScrollAccumDy.abs() / threshold).floor();
    final maxSteps = _terminalScrollMaxStepsForVelocity(velocity);
    final wheelMagnitude = rawSteps.clamp(1, maxSteps);
    _lastTerminalScrollEmitTsMs = nowMs;
    final consumed = math.min(
      _terminalScrollAccumDy.abs(),
      threshold * wheelMagnitude,
    );
    _terminalScrollAccumDy -= direction * consumed;
    if (_terminalScrollAccumDy.abs() < 0.5 ||
        _terminalScrollAccumDy.sign != direction) {
      _terminalScrollAccumDy = 0.0;
    } else {
      _clampTerminalScrollCarry(threshold);
    }
    _sendDiagnosticMouseWheel(
      controlService,
      direction * wheelMagnitude,
      deltaY,
      velocity,
      nowMs,
      reason,
    );
    return true;
  }

  void _emitAcceleratedTerminalScroll(
    ControlService controlService,
    double deltaY,
    double velocity,
    int dtMs,
    int nowMs,
  ) {
    _activateScrollBoost(controlService);
    _terminalScrollAccumDy += deltaY;
    _sendScrollTouchDiagnostic(controlService, deltaY, velocity, dtMs, nowMs);
    if (!_terminalScrollGesturePrimed && deltaY.abs() >= 1.0) {
      _terminalScrollGesturePrimed = true;
      _flushTerminalScrollAccum(
        controlService,
        deltaY: deltaY,
        velocity: math.max(velocity, _terminalScrollVelocityMedium),
        dtMs: dtMs,
        nowMs: nowMs,
        reason: 'first_update',
        force: true,
      );
      return;
    }

    final activeVelocity = _terminalScrollGesturePrimed
        ? math.max(velocity, _terminalScrollVelocityMedium)
        : velocity;
    _flushTerminalScrollAccum(
      controlService,
      deltaY: deltaY,
      velocity: activeVelocity,
      dtMs: dtMs,
      nowMs: nowMs,
      reason: 'responsive_update',
      force: _terminalScrollGesturePrimed,
    );
  }

  void _handleTerminalScrollEnd() {
    final controlService = context.read<ControlService>();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_terminalScrollGestureId != null && _terminalScrollAccumDy != 0.0) {
      _flushTerminalScrollAccum(
        controlService,
        deltaY: _terminalScrollAccumDy,
        velocity: _terminalScrollVelocityMedium,
        dtMs: 16,
        nowMs: nowMs,
        reason: 'gesture_end_flush',
        force: true,
      );
    }
    if (_terminalScrollGestureId != null) {
      controlService.sendScrollDiagnostic({
        'event': 'gesture_end',
        'gesture_id': _terminalScrollGestureId,
        'client_ts_ms': nowMs,
        'touch_updates': _terminalScrollTouchUpdates,
        'wheel_count': _terminalScrollWheelSeq,
        'total_delta_y': _terminalScrollTotalDy,
      });
    }
    _terminalScrollAccumDy = 0.0;
    _lastTerminalScrollSampleTsMs = 0;
    _lastTerminalScrollEmitTsMs = 0;
    _terminalScrollGesturePrimed = false;
    _terminalScrollGestureId = null;
    _terminalScrollWheelSeq = 0;
    _terminalScrollTotalDy = 0.0;
    _terminalScrollTouchUpdates = 0;
    _scheduleScrollBoostRestore();
  }

  ButtonStyle _topActionButtonStyle() {
    return TextButton.styleFrom(
      minimumSize: const Size(30, 30),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
      visualDensity: VisualDensity.compact,
      textStyle: const TextStyle(fontSize: 13, height: 1.0),
    );
  }

  Future<void> _handleBackgroundPause() async {
    if (!mounted) return;
    // CRITICAL: if a recovery is in flight, leave it alone. Touching
    // _backgroundPauseGeneration / disconnecting signaling here would race
    // with _performFullReconnect (it awaits persistence and short delays
    // that would otherwise be torn down by a stale pause callback firing
    // mid-recovery, leaving the UI frozen on "已连接" with no frames).
    if (_reconnecting) {
      final controlService = _cachedControlService;
      if (controlService != null) {
        _logOnce(
          controlService,
          'pause_skipped_during_reconnect',
          {
            'event': 'background_pause_skipped',
            'stage': 'entry_during_reconnect',
            'reconnecting': true,
          },
        );
      }
      return;
    }
    final pauseGeneration = ++_backgroundPauseGeneration;
    await _persistBackgroundRecoveryPending(true);
    if (!mounted || pauseGeneration != _backgroundPauseGeneration) {
      final controlService = _cachedControlService;
      if (controlService != null) {
        _logOnce(
          controlService,
          'pause_aborted_after_persist:gen$pauseGeneration',
          {
            'event': 'background_pause_aborted',
            'stage': 'after_persist',
            'pause_generation': pauseGeneration,
            'current_generation': _backgroundPauseGeneration,
            'mounted': mounted,
          },
        );
      }
      return;
    }
    if (_pausedByLifecycle || _reconnecting) {
      final controlService = _cachedControlService;
      if (controlService != null) {
        _logOnce(
          controlService,
          'pause_aborted_already_paused_or_reconnecting:gen$pauseGeneration',
          {
            'event': 'background_pause_aborted',
            'stage': 'already_paused_or_reconnecting',
            'pause_generation': pauseGeneration,
            'paused_by_lifecycle': _pausedByLifecycle,
            'reconnecting': _reconnecting,
          },
        );
      }
      return;
    }
    _pausedByLifecycle = true;
    _resumeReconnectGeneration += 1;
    final controlService = context.read<ControlService>();
    final signaling = context.read<SignalingService>();
    _lastSelectedHwnd ??= controlService.selectedHwnd;
    _lastSelectedTitle ??= controlService.windowTitle;
    controlService.sendScrollDiagnostic({
      'event': 'lifecycle_background_pause',
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
      'signaling_status': signaling.status.name,
      'selected_hwnd': _lastSelectedHwnd,
    });
    if (!mounted || pauseGeneration != _backgroundPauseGeneration) {
      _logOnce(
        controlService,
        'pause_aborted_after_probe_pause:gen$pauseGeneration',
        {
          'event': 'background_pause_aborted',
          'stage': 'after_probe_pause',
          'pause_generation': pauseGeneration,
          'current_generation': _backgroundPauseGeneration,
          'mounted': mounted,
        },
      );
      return;
    }
    // Keep the signaling ws alive while backgrounded. Previously we
    // disconnected here, which meant every foreground resume required a full
    // reconnect (DNS + HTTP probe + ws connect + H264 decoder restart), and
    // the reconnect path itself could stall the UI. Leaving ws alive means:
    //   - Quick resumes need zero reconnect work; frames start flowing again
    //     as soon as the Dart event loop resumes.
    //   - If the server drops us (ACK timeout), _onSignalingStatusChanged
    //     detects status->idle and triggers an automatic reconnect.
    //   - If Android freezes the process, everything stops together and
    //     resumes together — no stale half-state.
    await controlService.pauseDirectTransportProbe();
    if (!mounted || pauseGeneration != _backgroundPauseGeneration) {
      _logOnce(
        controlService,
        'pause_aborted_after_transport_pause:gen$pauseGeneration',
        {
          'event': 'background_pause_aborted',
          'stage': 'after_transport_pause',
          'pause_generation': pauseGeneration,
          'current_generation': _backgroundPauseGeneration,
          'mounted': mounted,
        },
      );
      return;
    }
    controlService.setStatus('已切到后台');
  }

  Future<bool> _refreshNetworkRoute({bool forceRefresh = false}) async {
    if (!mounted || _networkRouteRefreshInFlight) {
      return _isLocalNetworkConnection;
    }
    _networkRouteRefreshInFlight = true;
    try {
      final resolvedEndpoint = await ServerEndpointResolver.resolveEndpoint(
        localServerUrl: widget.localServerUrl,
        fallbackServerUrl: widget.fallbackServerUrl,
      );
      final isLocalNetwork = await NetworkRouteResolver.isSameLocalNetwork(
        resolvedServerUrl: resolvedEndpoint.serverUrl,
        deviceLocalIp: widget.deviceLocalIp,
        expectedDeviceId: widget.deviceId,
        deviceLocalIps: widget.deviceLocalIps,
        deviceLanProbePort: widget.deviceLanProbePort,
        forceRefresh: forceRefresh,
      );
      if (!mounted) return _isLocalNetworkConnection;
      final changed = _isLocalNetworkConnection != isLocalNetwork;
      if (changed) {
        setState(() {
          _isLocalNetworkConnection = isLocalNetwork;
          if (!isLocalNetwork && _preferredStreamProfile == StreamProfile.lan) {
            _preferredStreamProfile = StreamProfile.smoothHd;
            _usingLocalNetworkPreset = false;
          }
        });
        final controlService = context.read<ControlService>();
        _applyConnectionStreamSettings(
          controlService,
          isLocalNetwork: isLocalNetwork,
        );
        _persistPreferences();
      }
      context.read<ControlService>().sendScrollDiagnostic({
        'event': 'network_route_refreshed',
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'is_local_network': isLocalNetwork,
        'force_refresh': forceRefresh,
        'changed': changed,
      });

      // If the active signaling endpoint no longer matches the detected
      // network direction (e.g. user moved from 5G to the same Wi-Fi as the
      // desktop), trigger a full reconnect so the data path migrates between
      // signal-relay and LAN-direct (port 58082) without requiring a manual
      // intervention. The reconnect itself is throttled by _reconnecting and
      // by `_recoverConnectionLikeFreshOpen`'s own guards.
      if (mounted) {
        final signaling = context.read<SignalingService>();
        if (signaling.isConnected) {
          final usingLanDirect = signaling.isLanDirectConnection;
          final shouldUseLanDirect =
              isLocalNetwork && _activeDeviceLanDirectPort > 0;
          if (usingLanDirect != shouldUseLanDirect && !_reconnecting) {
            context.read<ControlService>().sendScrollDiagnostic({
              'event': 'network_route_endpoint_realign',
              'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
              'is_local_network': isLocalNetwork,
              'using_lan_direct': usingLanDirect,
              'should_use_lan_direct': shouldUseLanDirect,
              'force_refresh': forceRefresh,
            });
            unawaited(_recoverConnectionLikeFreshOpen(
              trigger: 'network-route-realign',
              videoRestoreReason: 'network-route-realign',
            ));
          }
        }
      }
      return isLocalNetwork;
    } catch (e) {
      if (mounted) {
        context.read<ControlService>().sendScrollDiagnostic({
          'event': 'network_route_refresh_failed',
          'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
          'force_refresh': forceRefresh,
          'error': e.toString(),
        });
      }
      return _isLocalNetworkConnection;
    } finally {
      _networkRouteRefreshInFlight = false;
    }
  }

  void _scheduleConnectivityReconnect() {
    unawaited(_refreshNetworkRoute(forceRefresh: true));
  }

  String _activeLanDirectServerUrl() {
    if (_activeDeviceLanDirectPort <= 0) return '';
    final candidates = <String>[
      _activeDeviceLocalIp,
      ..._activeDeviceLocalIps,
    ];
    for (final item in candidates) {
      final value = item.trim();
      if (value.isNotEmpty) {
        return 'ws://$value:$_activeDeviceLanDirectPort';
      }
    }
    return '';
  }

  Future<void> _handleForegroundResume() async {
    _pausedByLifecycle = false;
    _backgroundPauseGeneration += 1;
    _resumeRetryTimer?.cancel();
    _resumeRetryTimer = null;
    _resumeRetryAttempt = 0;
    final controlService = _cachedControlService;
    final signaling = context.read<SignalingService>();
    final wsAlive = signaling.status == ConnectionStatus.connected;
    final controlOk = controlService != null && controlService.connected;
    final visualFresh = controlService != null &&
        _hasFreshVisualFrame(
          controlService,
          DateTime.now().millisecondsSinceEpoch,
        );
    if (wsAlive && controlOk && visualFresh) {
      controlService.sendScrollDiagnostic({
        'event': 'lifecycle_foreground_fast_resume',
        'diag_id': _connectionDiagId,
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'last_visual_frame_at_ms':
            controlService.lastVisualFrameAt?.millisecondsSinceEpoch,
        'h264_available': controlService.usingH264Video,
        'h264_negotiating': controlService.h264VideoStream.negotiating,
      });
      controlService.startDirectTransportProbe();
      controlService.requestVideoRestart(
        reason: 'foreground-fast-resume',
        forceH264: true,
      );
      return;
    }
    controlService?.sendScrollDiagnostic({
      'event': 'lifecycle_foreground_full_reconnect_required',
      'diag_id': _connectionDiagId,
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
      'ws_alive': wsAlive,
      'control_connected': controlOk,
      'visual_fresh': visualFresh,
      'last_visual_frame_at_ms':
          controlService.lastVisualFrameAt?.millisecondsSinceEpoch,
      'h264_available': controlService.usingH264Video,
      'h264_negotiating': controlService.h264VideoStream.negotiating,
    });
    await _recoverPendingBackgroundSession('foreground');
  }

  /// Probe whether the signaling endpoint is actually reachable right now,
  /// without trusting [SignalingService.isConnected]. Android may silently
  /// kill the underlying socket while the app is backgrounded; the Dart side
  /// still reports `connected` until it tries to send. A short HTTP probe to
  /// the same host gives us ground truth.
  Future<bool> _probeSignalingAlive(SignalingService signaling) async {
    final url = signaling.serverUrl.trim();
    if (url.isEmpty) return false;
    try {
      final probe = SignalingService(serverUrl: url);
      await probe.fetchAgents().timeout(const Duration(seconds: 3));
      return true;
    } catch (_) {
      return false;
    }
  }

  void _handleVideoHandshakeWatchdog() {
    if (!mounted || _reconnecting || _inputMode == InputMode.textOnly) return;
    final controlService = _cachedControlService;
    if (controlService == null || !controlService.connected) return;
    if (controlService.usingH264Video) {
      _handshakeStuckSinceMs = 0;
      _showVideoStuckHint = false;
      _handshakeRecoveryTimer?.cancel();
      _handshakeRecoveryTimer = null;
      return;
    }
    final progress = controlService.videoHandshakeProgress;
    final waitingVideo = progress >= 82 ||
        controlService.h264VideoStream.negotiating ||
        controlService.h264VideoStream.failed;
    if (!waitingVideo) {
      _handshakeStuckSinceMs = 0;
      _showVideoStuckHint = false;
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _handshakeStuckSinceMs =
        _handshakeStuckSinceMs == 0 ? nowMs : _handshakeStuckSinceMs;
    if (nowMs - _handshakeStuckSinceMs < 15000) {
      return;
    }
    if (_showVideoStuckHint) return;
    _showVideoStuckHint = true;
    controlService.sendScrollDiagnostic({
      'event': 'video_handshake_watchdog_hint',
      'diag_id': _connectionDiagId,
      'client_ts_ms': nowMs,
      'progress': progress,
      'h264_negotiating': controlService.h264VideoStream.negotiating,
      'h264_failed': controlService.h264VideoStream.failed,
      'selected_hwnd': _lastSelectedHwnd ?? controlService.selectedHwnd,
      'last_visual_frame_at_ms':
          controlService.lastVisualFrameAt?.millisecondsSinceEpoch,
    });
    if (mounted) setState(() {});
  }

  Future<void> _recoverPendingBackgroundSession(String trigger) async {
    final pending = await _readBackgroundRecoveryPending();
    if (!mounted) return;
    final controlService = context.read<ControlService>();
    final signaling = context.read<SignalingService>();

    // Decide whether a recovery is required using three independent signals
    // so a missing flag (e.g. a pause that was interrupted before persisting)
    // never strands us in a frozen UI:
    //   1. Persisted pending flag (the "happy path").
    //   2. Signaling state machine no longer reports connected.
    //   3. ControlService thinks we're disconnected (covers the case where
    //      we're showing the disconnected status to the user).
    //   4. Signaling claims connected but a fresh HTTP probe fails (the
    //      Android socket was silently killed while backgrounded).
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final stateNotConnected = signaling.status != ConnectionStatus.connected;
    final controlNotConnected = !controlService.connected;
    final visualStale = !_hasFreshVisualFrame(controlService, nowMs);
    bool socketDead = false;
    if (!stateNotConnected && !controlNotConnected) {
      socketDead = !await _probeSignalingAlive(signaling);
      if (!mounted) return;
    }
    final shouldRecover =
        stateNotConnected || controlNotConnected || socketDead || visualStale;

    controlService.sendScrollDiagnostic({
      'event': 'background_recovery_gate',
      'diag_id': _connectionDiagId,
      'client_ts_ms': nowMs,
      'trigger': trigger,
      'pending': pending,
      'state_not_connected': stateNotConnected,
      'control_not_connected': controlNotConnected,
      'socket_dead': socketDead,
      'visual_stale': visualStale,
      'last_visual_frame_at_ms':
          controlService.lastVisualFrameAt?.millisecondsSinceEpoch,
      'h264_available': controlService.usingH264Video,
      'h264_negotiating': controlService.h264VideoStream.negotiating,
      'should_recover': shouldRecover,
      'paused_by_lifecycle': _pausedByLifecycle,
      'selected_hwnd': _lastSelectedHwnd ?? controlService.selectedHwnd,
    });

    if (pending && !shouldRecover) {
      _logOnce(
        controlService,
        'recovery_skipped_pending_only:$trigger',
        {
          'event': 'recovery_skipped_pending_only',
          'trigger': trigger,
          'signaling_status': signaling.status.name,
          'control_connected': controlService.connected,
        },
      );
      unawaited(_persistBackgroundRecoveryPending(false));
    }

    if (!shouldRecover) return;
    await _recoverConnectionLikeFreshOpen(
      trigger: trigger,
      videoRestoreReason: '$trigger-background-full-reconnect',
    );
  }

  /// Backoff schedule (seconds) for [_scheduleResumeRetry]. Stops after the
  /// last entry; the user can still hit the manual recovery button.
  static const List<int> _resumeRetryBackoffSeconds = <int>[3, 8, 20, 45, 90];

  void _scheduleResumeRetry(String previousError) {
    if (!mounted) return;
    if (_resumeRetryAttempt >= _resumeRetryBackoffSeconds.length) {
      final controlService = _cachedControlService;
      controlService?.setStatus('恢复连接失败：$previousError，请按手动恢复');
      controlService?.sendScrollDiagnostic({
        'event': 'lifecycle_resume_retry_exhausted',
        'diag_id': _connectionDiagId,
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'attempts': _resumeRetryAttempt,
        'last_error': previousError,
      });
      return;
    }
    final delay =
        Duration(seconds: _resumeRetryBackoffSeconds[_resumeRetryAttempt]);
    _resumeRetryAttempt += 1;
    final attempt = _resumeRetryAttempt;
    _resumeRetryTimer?.cancel();
    final controlService = _cachedControlService;
    controlService?.setStatus(
        '恢复失败，${delay.inSeconds} 秒后重试（第 $attempt 次）：$previousError');
    controlService?.sendScrollDiagnostic({
      'event': 'lifecycle_resume_retry_scheduled',
      'diag_id': _connectionDiagId,
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
      'attempt': attempt,
      'delay_seconds': delay.inSeconds,
      'previous_error': previousError,
    });
    _resumeRetryTimer = Timer(delay, () async {
      if (!mounted) return;
      _resumeRetryTimer = null;
      if (_reconnecting) {
        // A different code path is already reconnecting; piggyback on it.
        return;
      }
      try {
        await _recoverConnectionLikeFreshOpen(
          trigger: 'resume-watchdog-$attempt',
          videoRestoreReason: 'resume-watchdog-$attempt',
        );
        // Successful run resets attempt count via the catch/no-throw path.
      } catch (_) {
        // _recoverConnectionLikeFreshOpen already swallows its own errors and
        // schedules the next retry; nothing else to do here.
      }
    });
  }

  Future<void> _handleManualRecoveryPressed() async {
    if (!mounted || _reconnecting) return;
    // User-initiated recovery preempts any pending watchdog so we don't
    // collide with our own retry attempt.
    _resumeRetryTimer?.cancel();
    _resumeRetryTimer = null;
    _resumeRetryAttempt = 0;
    final controlService = context.read<ControlService>();
    final signaling = context.read<SignalingService>();
    controlService.sendScrollDiagnostic({
      'event': 'manual_recovery_pressed',
      'diag_id': _connectionDiagId,
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
      'room_id': _activeRoomId,
      'device_id': widget.deviceId,
      'signaling_status': signaling.status.name,
      'signaling_connected': signaling.isConnected,
      'connected': controlService.connected,
      'status_message': controlService.statusMessage,
      'selected_hwnd': _lastSelectedHwnd ?? controlService.selectedHwnd,
      'selected_title': _lastSelectedTitle ?? controlService.windowTitle,
      'stream_profile': controlService.streamProfile.name,
      'is_local_network': _isLocalNetworkConnection,
      'h264_available': controlService.usingH264Video,
      'h264_negotiating': controlService.h264VideoStream.negotiating,
      'h264_failed': controlService.h264VideoStream.failed,
      'video_transport': controlService.videoTransportLabel,
      'handshake_progress': controlService.videoHandshakeProgress,
      'last_frame_at_ms': controlService.lastFrameAt?.millisecondsSinceEpoch,
      'last_visual_frame_at_ms':
          controlService.lastVisualFrameAt?.millisecondsSinceEpoch,
      'last_h264_frame_at_ms': controlService
          .h264VideoStream.lastRenderedFrameAt?.millisecondsSinceEpoch,
      'has_image_frame': controlService.currentFrame != null,
      'video_width': controlService.videoFrameWidth,
      'video_height': controlService.videoFrameHeight,
    });
    await _persistBackgroundRecoveryPending(true);
    await _recoverConnectionLikeFreshOpen(
      trigger: 'manual-button',
      videoRestoreReason: 'manual-button-full-reconnect',
    );
  }

  Future<void> _recoverConnectionLikeFreshOpen({
    required String trigger,
    required String videoRestoreReason,
  }) async {
    if (!mounted || _reconnecting) return;
    final signaling = context.read<SignalingService>();
    final controlService = context.read<ControlService>();
    _reconnecting = true;
    _resumeReconnectGeneration += 1;
    final generation = _resumeReconnectGeneration;
    controlService.sendScrollDiagnostic({
      'event': 'lifecycle_foreground_resume',
      'diag_id': _connectionDiagId,
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
      'trigger': trigger,
      'signaling_status': signaling.status.name,
      'selected_hwnd': _lastSelectedHwnd ?? controlService.selectedHwnd,
      'h264_available': controlService.usingH264Video,
      'h264_negotiating': controlService.h264VideoStream.negotiating,
      'last_frame_at_ms': controlService.lastFrameAt?.millisecondsSinceEpoch,
      'last_h264_frame_at_ms': controlService
          .h264VideoStream.lastRenderedFrameAt?.millisecondsSinceEpoch,
    });
    controlService.setStatus('正在恢复连接...');

    try {
      await _performFullReconnect(
        controlService,
        signaling,
        generation,
        attempt: 1,
        reason: trigger,
        videoRestoreReason: videoRestoreReason,
      );
      unawaited(_persistBackgroundRecoveryPending(false));
      _expectVisualChange(
        controlService,
        sent: true,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        reason: 'foreground_resume',
      );
      controlService.setStatus('连接已恢复');
      // Successful recovery clears the watchdog backoff so a future failure
      // starts at attempt #1 again.
      _resumeRetryAttempt = 0;
      _resumeRetryTimer?.cancel();
      _resumeRetryTimer = null;
    } catch (e) {
      controlService.setConnected(false,
          roomId: _activeRoomId, windowTitle: controlService.windowTitle);
      controlService.setStatus('恢复连接失败：$e');
      controlService.sendScrollDiagnostic({
        'event': 'lifecycle_reconnect_failed',
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'attempt': 1,
        'error': e.toString(),
      });
      _scheduleResumeRetry(e.toString());
    } finally {
      _reconnecting = false;
    }
  }

  Future<void> _refreshActiveDeviceRoute(
    ControlService controlService,
    SignalingService signaling,
    String serverUrl,
  ) async {
    if (widget.deviceId.trim().isEmpty) return;
    try {
      final probe = SignalingService(serverUrl: serverUrl);
      final agents =
          await probe.fetchAgents().timeout(const Duration(seconds: 4));
      final current = agents.firstWhereOrNull(
        (item) => item['deviceId']?.toString() == widget.deviceId,
      );
      if (current == null) {
        controlService.sendScrollDiagnostic({
          'event': 'full_reconnect_device_refresh_missing',
          'diag_id': _connectionDiagId,
          'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
          'device_id': widget.deviceId,
          'server_url': serverUrl,
          'agent_count': agents.length,
        });
        return;
      }
      final nextRoomId = current['roomId']?.toString() ?? '';
      final nextLocalIp = current['localIp']?.toString() ?? '';
      final nextLocalIps = ((current['localIps'] as List?) ?? const [])
          .map((item) => item.toString())
          .toList(growable: false);
      final nextLanProbePort = (current['lanProbePort'] as num?)?.toInt() ?? 0;
      final nextLanDirectPort =
          (current['lanDirectPort'] as num?)?.toInt() ?? 0;
      controlService.sendScrollDiagnostic({
        'event': 'full_reconnect_device_refreshed',
        'diag_id': _connectionDiagId,
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'device_id': widget.deviceId,
        'old_room_id': _activeRoomId,
        'new_room_id': nextRoomId,
        'old_local_ip': _activeDeviceLocalIp,
        'new_local_ip': nextLocalIp,
        'lan_probe_port': nextLanProbePort,
        'lan_direct_port': nextLanDirectPort,
      });
      if (nextRoomId.isNotEmpty) {
        _activeRoomId = nextRoomId;
        signaling.roomId = nextRoomId;
      }
      if (nextLocalIp.isNotEmpty) {
        _activeDeviceLocalIp = nextLocalIp;
      }
      if (nextLocalIps.isNotEmpty) {
        _activeDeviceLocalIps = nextLocalIps;
      }
      if (nextLanProbePort > 0) {
        _activeDeviceLanProbePort = nextLanProbePort;
      }
      if (nextLanDirectPort > 0) {
        _activeDeviceLanDirectPort = nextLanDirectPort;
      }
    } catch (e) {
      controlService.sendScrollDiagnostic({
        'event': 'full_reconnect_device_refresh_failed',
        'diag_id': _connectionDiagId,
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'device_id': widget.deviceId,
        'server_url': serverUrl,
        'error': e.toString(),
      });
    }
  }

  Future<void> _performFullReconnect(
    ControlService controlService,
    SignalingService signaling,
    int generation, {
    required int attempt,
    required String reason,
    required String videoRestoreReason,
  }) async {
    final selectedHwnd = _lastSelectedHwnd ?? controlService.selectedHwnd;
    controlService.sendScrollDiagnostic({
      'event': 'full_reconnect_begin',
      'diag_id': _connectionDiagId,
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
      'attempt': attempt,
      'reason': reason,
      'selected_hwnd': selectedHwnd,
      'signaling_status': signaling.status.name,
      'h264_available': controlService.usingH264Video,
      'h264_negotiating': controlService.h264VideoStream.negotiating,
    });
    if (selectedHwnd != null) {
      _lastSelectedHwnd = selectedHwnd;
    }
    _lastSelectedTitle ??= controlService.windowTitle;

    await controlService.resetForHardReconnect();
    signaling.disconnect();
    controlService.sendScrollDiagnostic({
      'event': 'full_reconnect_after_reset',
      'diag_id': _connectionDiagId,
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
      'attempt': attempt,
      'reason': reason,
    });
    controlService.setConnected(false,
        roomId: _activeRoomId, windowTitle: controlService.windowTitle);
    await Future<void>.delayed(const Duration(milliseconds: 180));

    final resolvedEndpoint = await ServerEndpointResolver.resolveEndpoint(
      localServerUrl: widget.localServerUrl,
      fallbackServerUrl: widget.fallbackServerUrl,
    );
    await _refreshActiveDeviceRoute(
      controlService,
      signaling,
      resolvedEndpoint.serverUrl,
    );
    final isLocalNetwork = await NetworkRouteResolver.isSameLocalNetwork(
      resolvedServerUrl: resolvedEndpoint.serverUrl,
      deviceLocalIp: _activeDeviceLocalIp,
      expectedDeviceId: widget.deviceId,
      deviceLocalIps: _activeDeviceLocalIps,
      deviceLanProbePort: _activeDeviceLanProbePort,
      forceRefresh: true,
    );
    if (!mounted || generation != _resumeReconnectGeneration) {
      controlService.sendScrollDiagnostic({
        'event': 'full_reconnect_aborted_post_route',
        'diag_id': _connectionDiagId,
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'attempt': attempt,
        'expected_generation': generation,
        'actual_generation': _resumeReconnectGeneration,
        'mounted': mounted,
      });
      return;
    }

    final lanDirectUrl = isLocalNetwork ? _activeLanDirectServerUrl() : '';
    final pdHost = widget.publicDirectHost?.trim() ?? '';
    final pdPort = widget.publicDirectPort;
    String? pdUrlFromInfo;
    if (!isLocalNetwork && pdHost.isNotEmpty && pdPort > 0) {
      pdUrlFromInfo = 'ws://$pdHost:$pdPort';
    }
    final publicDirectAttempt = await PublicDirectClient.tryPrepare(
      expectedDeviceId: widget.deviceId,
    );
    final effectivePublicDirect = publicDirectAttempt != null
        ? publicDirectAttempt
        : (pdUrlFromInfo != null
            ? PublicDirectAttempt(
                serverUrl: pdUrlFromInfo,
                totpCode: '',
                totpNonce: '',
                config: PublicDirectConfig(
                  host: pdHost,
                  port: pdPort,
                  deviceId: widget.deviceId,
                  totpSecret: '',
                ),
              )
            : null);
    if (effectivePublicDirect != null) {
      signaling.serverUrl = effectivePublicDirect.serverUrl;
      signaling.setPublicDirectAuth(
        totpCode: effectivePublicDirect.totpCode,
        totpNonce: effectivePublicDirect.totpNonce,
      );
    } else {
      signaling.serverUrl =
          lanDirectUrl.isNotEmpty ? lanDirectUrl : resolvedEndpoint.serverUrl;
      signaling.clearPublicDirectAuth();
    }
    signaling.roomId = _activeRoomId;
    controlService.setSignalingService(signaling);
    try {
      await signaling.connect().timeout(const Duration(seconds: 8));
    } catch (_) {
      // Cascade: public-direct → LAN-direct → signaling relay.
      if (effectivePublicDirect != null) {
        signaling.disconnect();
        signaling.clearPublicDirectAuth();
        final fallbackUrl = lanDirectUrl.isNotEmpty
            ? lanDirectUrl
            : resolvedEndpoint.serverUrl;
        signaling.serverUrl = fallbackUrl;
        signaling.roomId = _activeRoomId;
        try {
          await signaling.connect().timeout(const Duration(seconds: 8));
        } catch (_) {
          if (lanDirectUrl.isEmpty || fallbackUrl == resolvedEndpoint.serverUrl) {
            rethrow;
          }
          signaling.disconnect();
          signaling.serverUrl = resolvedEndpoint.serverUrl;
          signaling.roomId = _activeRoomId;
          await signaling.connect().timeout(const Duration(seconds: 8));
        }
      } else {
        if (lanDirectUrl.isEmpty) rethrow;
        signaling.disconnect();
        signaling.serverUrl = resolvedEndpoint.serverUrl;
        signaling.roomId = _activeRoomId;
        await signaling.connect().timeout(const Duration(seconds: 8));
      }
    }
    if (!mounted || generation != _resumeReconnectGeneration) {
      controlService.sendScrollDiagnostic({
        'event': 'full_reconnect_aborted_post_connect',
        'diag_id': _connectionDiagId,
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'attempt': attempt,
        'expected_generation': generation,
        'actual_generation': _resumeReconnectGeneration,
        'mounted': mounted,
      });
      return;
    }
    controlService.sendScrollDiagnostic({
      'event': 'full_reconnect_signaling_connected',
      'diag_id': _connectionDiagId,
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
      'attempt': attempt,
      'server_url': signaling.serverUrl,
      'fallback_server_url': resolvedEndpoint.serverUrl,
      'lan_direct_url': lanDirectUrl,
      'is_local_network': isLocalNetwork,
      'room_id': _activeRoomId,
      'selected_hwnd': selectedHwnd,
    });

    setState(() {
      _isLocalNetworkConnection = isLocalNetwork;
      if (!isLocalNetwork && _preferredStreamProfile == StreamProfile.lan) {
        _preferredStreamProfile = StreamProfile.smoothHd;
        _usingLocalNetworkPreset = false;
      }
    });
    controlService.setConnected(true,
        roomId: _activeRoomId, windowTitle: controlService.windowTitle);
    controlService.sendScrollDiagnostic({
      'event': 'full_reconnect_post_signaling_settle',
      'diag_id': _connectionDiagId,
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
      'attempt': attempt,
      'reason': reason,
      'generation': generation,
      'current_generation': _resumeReconnectGeneration,
    });
    // NOTE: previously we awaited a 250ms grace period here. That was the
    // exact spot where a transient lifecycle pause (user briefly switching
    // apps mid-recovery) could bump _resumeReconnectGeneration and cause
    // the function to silently return below. Removed: there's nothing to
    // settle that can't ride the next event loop tick.
    if (!mounted || generation != _resumeReconnectGeneration) {
      controlService.sendScrollDiagnostic({
        'event': 'full_reconnect_aborted_post_settle',
        'diag_id': _connectionDiagId,
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'attempt': attempt,
        'expected_generation': generation,
        'actual_generation': _resumeReconnectGeneration,
        'mounted': mounted,
      });
      return;
    }

    if (selectedHwnd != null) {
      controlService.setWindow(selectedHwnd);
      _initialFitRequested = false;
      controlService.sendScrollDiagnostic({
        'event': 'full_reconnect_set_window_sent',
        'diag_id': _connectionDiagId,
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'attempt': attempt,
        'selected_hwnd': selectedHwnd,
      });
    }
    _applyConnectionStreamSettings(
      controlService,
      isLocalNetwork: isLocalNetwork,
    );
    controlService.sendScrollDiagnostic({
      'event': 'full_reconnect_stream_settings_applied',
      'diag_id': _connectionDiagId,
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
      'attempt': attempt,
      'is_local_network': isLocalNetwork,
      'stream_profile': controlService.streamProfile.name,
      'h264_available': controlService.usingH264Video,
      'h264_negotiating': controlService.h264VideoStream.negotiating,
      'h264_failed': controlService.h264VideoStream.failed,
      'video_transport': controlService.videoTransportLabel,
    });
    controlService.startDirectTransportProbe();
    controlService.sendScrollDiagnostic({
      'event': 'full_reconnect_probe_started',
      'diag_id': _connectionDiagId,
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
      'attempt': attempt,
      'video_transport': controlService.videoTransportLabel,
      'handshake_progress': controlService.videoHandshakeProgress,
    });
    await _waitForRecoveredVisualFrame(
      controlService,
      generation,
      attempt: attempt,
      reason: reason,
      timeout: const Duration(seconds: 6),
    );
    if (mounted &&
        selectedHwnd != null &&
        !_didFitWindow &&
        _stableFitViewportSize != null) {
      _fitWindowToPhone(auto: true);
    }
    controlService.sendScrollDiagnostic({
      'event': 'lifecycle_reconnect_success',
      'diag_id': _connectionDiagId,
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
      'attempt': attempt,
      'reason': reason,
      'server_url': resolvedEndpoint.serverUrl,
      'room_id': _activeRoomId,
      'selected_hwnd': selectedHwnd,
      'is_local_network': isLocalNetwork,
      'video_restore_reason': videoRestoreReason,
    });
  }

  Future<void> _waitForRecoveredVisualFrame(
    ControlService controlService,
    int generation, {
    required int attempt,
    required String reason,
    required Duration timeout,
  }) async {
    final baseline =
        controlService.lastVisualFrameAt?.millisecondsSinceEpoch ?? 0;
    final completer = Completer<void>();
    Timer? timeoutTimer;
    late VoidCallback listener;
    listener = () {
      final frameAt =
          controlService.lastVisualFrameAt?.millisecondsSinceEpoch ?? 0;
      if (frameAt > baseline && !completer.isCompleted) {
        completer.complete();
      }
    };
    controlService.addListener(listener);
    timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('visual frame not restored', timeout),
        );
      }
    });
    controlService.requestVideoRestart(
      reason: 'reconnect-wait-visual-frame',
      forceH264: true,
    );
    controlService.sendScrollDiagnostic({
      'event': 'lifecycle_wait_visual_frame_begin',
      'diag_id': _connectionDiagId,
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
      'attempt': attempt,
      'reason': reason,
      'baseline_frame_at_ms': baseline,
      'h264_available': controlService.usingH264Video,
      'h264_negotiating': controlService.h264VideoStream.negotiating,
    });
    try {
      listener();
      await completer.future;
      if (!mounted || generation != _resumeReconnectGeneration) {
        controlService.sendScrollDiagnostic({
          'event': 'lifecycle_wait_visual_frame_aborted',
          'diag_id': _connectionDiagId,
          'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
          'attempt': attempt,
          'expected_generation': generation,
          'actual_generation': _resumeReconnectGeneration,
          'mounted': mounted,
        });
        return;
      }
      controlService.sendScrollDiagnostic({
        'event': 'lifecycle_wait_visual_frame_success',
        'diag_id': _connectionDiagId,
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'attempt': attempt,
        'reason': reason,
        'frame_at_ms': controlService.lastVisualFrameAt?.millisecondsSinceEpoch,
        'baseline_frame_at_ms': baseline,
        'h264_available': controlService.usingH264Video,
        'h264_negotiating': controlService.h264VideoStream.negotiating,
      });
    } catch (e) {
      controlService.sendScrollDiagnostic({
        'event': 'lifecycle_wait_visual_frame_timeout',
        'diag_id': _connectionDiagId,
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'attempt': attempt,
        'reason': reason,
        'error': e.toString(),
        'baseline_frame_at_ms': baseline,
        'frame_at_ms': controlService.lastVisualFrameAt?.millisecondsSinceEpoch,
        'last_h264_frame_at_ms': controlService
            .h264VideoStream.lastRenderedFrameAt?.millisecondsSinceEpoch,
        'h264_available': controlService.usingH264Video,
        'h264_negotiating': controlService.h264VideoStream.negotiating,
        'h264_failed': controlService.h264VideoStream.failed,
        'video_transport': controlService.videoTransportLabel,
        'handshake_progress': controlService.videoHandshakeProgress,
        'video_width': controlService.videoFrameWidth,
        'video_height': controlService.videoFrameHeight,
        'has_image_frame': controlService.currentFrame != null,
        'stream_profile': controlService.streamProfile.name,
      });
      rethrow;
    } finally {
      timeoutTimer.cancel();
      controlService.removeListener(listener);
    }
  }

  bool _visualTransportLooksReady(ControlService controlService) {
    final videoReady = controlService.usingH264Video &&
        (controlService.videoFrameWidth ?? 0) > 0 &&
        (controlService.videoFrameHeight ?? 0) > 0;
    return videoReady || controlService.currentFrame != null;
  }

  bool _hasFreshVisualFrame(ControlService controlService, int nowMs) {
    final frameAt = controlService.lastVisualFrameAt?.millisecondsSinceEpoch;
    if (frameAt == null) return false;
    if (nowMs - frameAt > 3000) return false;
    return _visualTransportLooksReady(controlService) &&
        !controlService.h264VideoStream.negotiating;
  }

  Size _contentSize({
    required double viewportW,
    required double viewportH,
    required double remoteW,
    required double remoteH,
  }) {
    final scale = math.min(viewportW / remoteW, viewportH / remoteH);
    return Size(remoteW * scale, remoteH * scale);
  }

  void _resetBrowseTransform() {
    _transformationController.value = Matrix4.identity();
  }

  (int, int)? _mapToRemote({
    required Offset local,
    required double containerW,
    required double containerH,
    required int? remoteW,
    required int? remoteH,
  }) {
    if (remoteW == null || remoteH == null || remoteW <= 0 || remoteH <= 0) {
      return null;
    }
    if (containerW <= 0 || containerH <= 0) return null;

    final scale = math.min(containerW / remoteW, containerH / remoteH);
    final drawW = remoteW * scale;
    final drawH = remoteH * scale;
    final offsetX = (containerW - drawW) / 2;
    final offsetY = (containerH - drawH) / 2;

    final clampedDx = local.dx.clamp(offsetX, offsetX + drawW);
    final clampedDy = local.dy.clamp(offsetY, offsetY + drawH);
    final x = ((clampedDx - offsetX) / scale).round().clamp(0, remoteW - 1);
    final y = ((clampedDy - offsetY) / scale).round().clamp(0, remoteH - 1);
    return (x, y);
  }

  String _formatBytes(double bytes) {
    const kb = 1024.0;
    const mb = kb * 1024.0;
    if (bytes >= mb) {
      return '${(bytes / mb).toStringAsFixed(2)} MB';
    }
    if (bytes >= kb) {
      return '${(bytes / kb).toStringAsFixed(1)} KB';
    }
    return '${bytes.toStringAsFixed(0)} B';
  }

  Widget _buildBottomBarV2(BuildContext context) {
    if (_inputMode == InputMode.textOnly) {
      return _buildTextOnlyBottomBar(context);
    }
    return Material(
      color: Colors.grey[100],
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: _ActionTextButton(
                    label: '历史',
                    minWidth: 0,
                    onPressed: _openSendHistorySheet,
                  ),
                ),
                const SizedBox(width: 2),
                Expanded(
                  flex: 2,
                  child: _ActionTextButton(
                    label: 'ESC',
                    minWidth: 0,
                    onPressed: () {
                      context.read<ControlService>().keyPress(0x1B);
                    },
                  ),
                ),
                const SizedBox(width: 2),
                Expanded(
                  flex: 2,
                  child: _ActionTextButton(
                    label: '发送',
                    minWidth: 0,
                    onPressed: _sendText,
                  ),
                ),
                const SizedBox(width: 2),
                Expanded(
                  flex: 2,
                  child: _ActionTextButton(
                    label: _captureSelectionMode ? '取消截图' : '截图',
                    minWidth: 0,
                    onPressed: _toggleCaptureSelectionMode,
                  ),
                ),
                const SizedBox(width: 2),
                Expanded(
                  flex: 2,
                  child: _ActionTextButton(
                    label: '删字',
                    minWidth: 0,
                    onPressed: _deleteRemoteText,
                    onLongPress: _startRepeatingDelete,
                    onLongPressStop: _stopRepeatingDelete,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: _ActionTextButton(
                    label: '窗口',
                    minWidth: 0,
                    onPressed: _selectWindow,
                  ),
                ),
                const SizedBox(width: 2),
                Expanded(
                  flex: 2,
                  child: _ActionTextButton(
                    label: '命令',
                    minWidth: 0,
                    onPressed: _openQuickCommandSheetV4,
                  ),
                ),
                const SizedBox(width: 2),
                Expanded(
                  flex: 2,
                  child: _ActionTextButton(
                    label: '回车',
                    minWidth: 0,
                    onPressed: () {
                      context.read<ControlService>().keyPress(0x0D);
                    },
                  ),
                ),
                const SizedBox(width: 2),
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: _bottomButtonHeight,
                    child: TextField(
                      controller: _textController,
                      focusNode: _textFocusNode,
                      textAlign: TextAlign.center,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '输入',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 10),
                      ),
                      minLines: 1,
                      maxLines: 1,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendText(),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Expanded(
                  flex: 2,
                  child: _ActionTextButton(
                    label: _keyboardVisible ? '收键盘' : '键盘',
                    minWidth: 0,
                    onPressed: _toggleKeyboardOverlay,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextOnlyBottomBar(BuildContext context) {
    return Material(
      color: Colors.grey[100],
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
        child: Row(
          children: [
            Expanded(
              child: _ActionTextButton(
                label: '历史',
                minWidth: 0,
                onPressed: _openSendHistorySheet,
              ),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: _ActionTextButton(
                label: _autoSubmitText ? '自动' : '手动',
                minWidth: 0,
                onPressed: () {
                  setState(() {
                    _autoSubmitText = !_autoSubmitText;
                  });
                  _handleTextInputChanged();
                },
              ),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: _ActionTextButton(
                label: '发送',
                minWidth: 0,
                onPressed: _sendText,
              ),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: _ActionTextButton(
                label: '回车',
                minWidth: 0,
                onPressed: () {
                  context.read<ControlService>().keyPress(0x0D);
                },
              ),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: _ActionTextButton(
                label: '退格',
                minWidth: 0,
                onPressed: _deleteRemoteText,
                onLongPress: _startRepeatingDelete,
                onLongPressStop: _stopRepeatingDelete,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openQuickCommandSheetV4() async {
    if (!_prefsLoaded) {
      await _restorePreferences();
    }
    if (!mounted) return;
    final controlService = context.read<ControlService>();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => QuickCommandSheetForTest(
        title: _qcTitle,
        builtinTitle: _qcBuiltinTitle,
        customTitle: _qcCustomTitle,
        emptyText: _qcEmpty,
        addLabel: _qcAddLabel,
        addHint: _qcAddHint,
        nameTitle: _qcNameTitle,
        nameHint: _qcNameHint,
        savePresetLabel: _qcSavePreset,
        builtinCommands: _builtinCodexCommands(),
        quickCommands: _quickCommands,
        onCommandSelected: (command) {
          controlService.pasteText(command);
          Navigator.of(sheetContext).pop();
        },
        onDeleteCommand: (name) async {
          if (!mounted) return;
          setState(() {
            _quickCommands = _quickCommands
                .where((entry) => entry.name != name)
                .toList(growable: false);
          });
          await _persistQuickCommands();
        },
        onSaveCommand: (name, command) async {
          if (!mounted) return;
          setState(() {
            _quickCommands = [
              ..._quickCommands.where((item) => item.name != name),
              QuickCommandForTest(name: name, command: command),
            ];
          });
          await _persistQuickCommands();
        },
      ),
    );
  }

  String _leftOverlayTextV2(ControlService controlService) {
    final title = _lastSelectedTitle ?? controlService.windowTitle ?? '未选择窗口';
    final routeLabel = _isLocalNetworkConnection ? '局域网' : '外网';
    final presetLabel = _usingLocalNetworkPreset ? '满配' : '自定义';
    return '窗口：$title\n房间：$_activeRoomId\n网络：$routeLabel/$presetLabel\n模式：${_titleForModeV2(_inputMode)}';
  }

  String _rightOverlayTextReadable(ControlService controlService) {
    final resolution = controlService.videoFrameWidth != null &&
            controlService.videoFrameHeight != null
        ? '${controlService.videoFrameWidth}x${controlService.videoFrameHeight}'
        : '--';
    final frameFps =
        controlService.fps.round().clamp(0, 999).toString().padLeft(3, '0');
    final cursorFps = controlService.cursorFps
        .round()
        .clamp(0, 999)
        .toString()
        .padLeft(3, '0');
    final targetFrameFps = (controlService.streamProfile == StreamProfile.lan ||
                controlService.streamProfile == StreamProfile.smoothHd ||
                controlService.scrollModeActive
            ? 60.0
            : controlService.fps > 0
                ? controlService.dynamicFpsLimit
                : controlService.staticFpsLimit)
        .round()
        .clamp(0, 999)
        .toString()
        .padLeft(3, '0');
    final perSecond = _formatBytes(controlService.bytesPerSecondEstimate);
    final perMinute = _formatBytes(controlService.bytesPerMinuteEstimate);
    final frameFpsLabel = controlService.usingH264Video ? '视频流帧率' : '旧版帧率';
    return '状态：${controlService.statusMessage}\n'
        '画质：${controlService.streamProfileLabel}\n'
        '画面通道：${controlService.videoTransportLabel}\n'
        '分辨率：$resolution\n'
        '$frameFpsLabel：$frameFps / $targetFrameFps FPS\n'
        '鼠标帧率：$cursorFps FPS\n'
        '每秒流量：$perSecond/s\n'
        '每分钟流量：$perMinute/min';
  }

  // Kept temporarily for comparison with older overlays.
  // ignore: unused_element
  String _rightOverlayTextV2(ControlService controlService) {
    final resolution = controlService.videoFrameWidth != null &&
            controlService.videoFrameHeight != null
        ? '${controlService.videoFrameWidth}x${controlService.videoFrameHeight}'
        : '--';
    final frameFps =
        controlService.fps.round().clamp(0, 999).toString().padLeft(3, '0');
    final cursorFps = controlService.cursorFps
        .round()
        .clamp(0, 999)
        .toString()
        .padLeft(3, '0');
    final targetFrameFps = (controlService.streamProfile == StreamProfile.lan ||
                controlService.streamProfile == StreamProfile.smoothHd ||
                controlService.scrollModeActive
            ? 60.0
            : controlService.fps > 0
                ? controlService.dynamicFpsLimit
                : controlService.staticFpsLimit)
        .round()
        .clamp(0, 999)
        .toString()
        .padLeft(3, '0');
    final perSecond = _formatBytes(controlService.bytesPerSecondEstimate);
    final perMinute = _formatBytes(controlService.bytesPerMinuteEstimate);
    final directStatus =
        controlService.directTransport?.message ?? 'server relay';
    return '状态：${controlService.statusMessage}\n'
        '画质：${controlService.streamProfileLabel}\n'
        '直连：$directStatus\n'
        '分辨率：$resolution\n'
        '画面帧率：$frameFps / $targetFrameFps FPS\n'
        '鼠标帧率：$cursorFps FPS\n'
        '每秒流量：$perSecond/s\n'
        '每分钟流量：$perMinute/min';
  }

  String _titleForModeV2(InputMode mode) {
    switch (mode) {
      case InputMode.browse:
        return '远程浏览';
      case InputMode.direct:
        return '远程直控';
      case InputMode.touchpad:
        return '远程鼠标';
      case InputMode.textOnly:
        return '纯输入';
    }
  }

  String _badgeTextV2(InputMode mode) {
    switch (mode) {
      case InputMode.browse:
        return '浏览';
      case InputMode.direct:
        return '直控';
      case InputMode.touchpad:
        return '鼠标';
      case InputMode.textOnly:
        return '输入';
    }
  }

  Future<void> _restorePreferences() async {
    if (!mounted || _prefsLoaded) return;
    final controlService = context.read<ControlService>();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final qualityScale = prefs.getDouble('control.quality_scale');
    final resolutionScale = prefs.getDouble('control.resolution_scale');
    final dynamicFpsLimit = prefs.getDouble('control.dynamic_fps_limit');
    final staticFpsLimit = prefs.getDouble('control.static_fps_limit');
    final streamProfileName = prefs.getString('control.stream_profile');
    final overlayVisible = prefs.getBool('control.show_overlay');
    final inputModeName = prefs.getString('control.input_mode');
    final windowScalePercent = prefs.getInt('control.window_scale_percent');
    final lastSelectedHwnd = prefs.getInt('control.last_selected_hwnd');
    final lastSelectedTitle = prefs.getString('control.last_selected_title');
    final fitPrefix = 'control.fit_viewport.$_activeRoomId';
    final fitWidth = prefs.getDouble('$fitPrefix.width');
    final fitHeight = prefs.getDouble('$fitPrefix.height');
    final fitPersisted = prefs.getBool('$fitPrefix.persisted') ?? false;
    final quickCommandsJson = prefs.getString(_quickCommandsPrefsKey);
    final sendHistory = prefs.getStringList(_sendHistoryPrefsKey);

    if (overlayVisible != null) {
      _showOverlay = overlayVisible;
    }
    if (inputModeName != null) {
      _inputMode = InputMode.values.firstWhere(
        (item) => item.name == inputModeName,
        orElse: () => InputMode.browse,
      );
    }
    if (windowScalePercent != null) {
      _windowScalePercent = windowScalePercent.clamp(30, 100).toInt();
    }
    if (lastSelectedHwnd != null) {
      _lastSelectedHwnd = lastSelectedHwnd;
    }
    if (lastSelectedTitle != null && lastSelectedTitle.isNotEmpty) {
      _lastSelectedTitle = lastSelectedTitle;
    }
    if (fitWidth != null &&
        fitHeight != null &&
        fitWidth > 0 &&
        fitHeight > 0) {
      _stableFitViewportSize = Size(fitWidth, fitHeight);
      _fitViewportPersisted = fitPersisted;
    }
    if (quickCommandsJson != null && quickCommandsJson.isNotEmpty) {
      _quickCommands = _decodeQuickCommands(quickCommandsJson);
    }
    if (sendHistory != null) {
      _sendHistory = sendHistory
          .where((item) => item.trim().isNotEmpty)
          .take(50)
          .toList(growable: false);
    }

    _preferredStreamProfile = StreamProfile.values.firstWhere(
      (item) => item.name == streamProfileName,
      orElse: () => StreamProfile.smoothHd,
    );
    _preferredQualityScale = qualityScale ?? controlService.qualityScale;
    _preferredResolutionScale =
        resolutionScale ?? controlService.resolutionScale;
    _preferredDynamicFpsLimit =
        dynamicFpsLimit ?? controlService.dynamicFpsLimit;
    _preferredStaticFpsLimit = staticFpsLimit ?? controlService.staticFpsLimit;
    for (final profile in StreamProfile.values) {
      _scrollVideoTunings[profile] = _loadScrollVideoTuning(prefs, profile);
    }
    _syncPreferredScrollVideoTuning(_preferredStreamProfile);

    _applyConnectionStreamSettings(
      controlService,
      isLocalNetwork: _isLocalNetworkConnection,
    );
    controlService.setVideoPaused(_inputMode == InputMode.textOnly);

    _prefsLoaded = true;
    if (mounted) {
      setState(() {});
    }
  }

  void _logOnce(
    ControlService controlService,
    String dedupKey,
    Map<String, dynamic> payload,
  ) {
    if (_onceLoggedKeys.contains(dedupKey)) return;
    _onceLoggedKeys.add(dedupKey);
    if (_onceLoggedKeys.length > 64) {
      _onceLoggedKeys.remove(_onceLoggedKeys.first);
    }
    final enriched = <String, dynamic>{
      'diag_id': _connectionDiagId,
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
      'dedup_key': dedupKey,
    }..addAll(payload);
    controlService.sendScrollDiagnostic(enriched);
  }

  Future<void> _persistBackgroundRecoveryPending(bool pending) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'control.background_recovery_pending.$_activeRoomId';
    if (pending) {
      await prefs.setBool(key, true);
      await prefs.setInt(
        'control.background_recovery_ts.$_activeRoomId',
        DateTime.now().millisecondsSinceEpoch,
      );
    } else {
      await prefs.remove(key);
      await prefs.remove('control.background_recovery_ts.$_activeRoomId');
    }
  }

  Future<bool> _readBackgroundRecoveryPending() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs
            .getBool('control.background_recovery_pending.$_activeRoomId') ??
        false;
  }

  Future<void> _persistPreferences() async {
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    await prefs.setString(
        'control.stream_profile', _preferredStreamProfile.name);
    await prefs.setDouble('control.quality_scale', _preferredQualityScale);
    await prefs.setDouble(
        'control.resolution_scale', _preferredResolutionScale);
    await prefs.setDouble(
        'control.dynamic_fps_limit', _preferredDynamicFpsLimit);
    await prefs.setDouble('control.static_fps_limit', _preferredStaticFpsLimit);
    await _persistScrollVideoTunings(prefs);
    await prefs.setBool('control.show_overlay', _showOverlay);
    await prefs.setString('control.input_mode', _inputMode.name);
    await prefs.setInt('control.window_scale_percent', _windowScalePercent);
    if (_lastSelectedHwnd != null) {
      await prefs.setInt('control.last_selected_hwnd', _lastSelectedHwnd!);
    }
    if ((_lastSelectedTitle ?? '').isNotEmpty) {
      await prefs.setString('control.last_selected_title', _lastSelectedTitle!);
    }
    final fitPrefix = 'control.fit_viewport.$_activeRoomId';
    final fitViewport = _stableFitViewportSize;
    if (fitViewport != null &&
        fitViewport.width > 0 &&
        fitViewport.height > 0) {
      await prefs.setDouble('$fitPrefix.width', fitViewport.width);
      await prefs.setDouble('$fitPrefix.height', fitViewport.height);
      await prefs.setBool('$fitPrefix.persisted', _fitViewportPersisted);
    }
  }

  Future<void> _persistQuickCommands() async {
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    await prefs.setString(
      _quickCommandsPrefsKey,
      jsonEncode(
        _quickCommands.map((item) => item.toJson()).toList(growable: false),
      ),
    );
  }

  String _profilePrefsName(StreamProfile profile) => profile.name;

  _ScrollVideoTuning _defaultScrollVideoTuning(StreamProfile profile) {
    switch (profile) {
      case StreamProfile.hybrid:
        return const _ScrollVideoTuning(
          scale: 0.70,
          bitrateKbps: 4000,
          fps: 24.0,
          crf: 26,
          vbvMultiplier: 3,
          pixelFormat: 'yuv420p',
          preset: 'veryfast',
          restoreDelayMs: 250,
        );
      case StreamProfile.smoothHd:
        return const _ScrollVideoTuning(
          scale: 0.85,
          bitrateKbps: 10000,
          fps: 40.0,
          crf: 22,
          vbvMultiplier: 4,
          pixelFormat: 'yuv420p',
          preset: 'veryfast',
          restoreDelayMs: 250,
        );
      case StreamProfile.lan:
        return const _ScrollVideoTuning(
          scale: 1.0,
          bitrateKbps: 60000,
          fps: 60.0,
          crf: 18,
          vbvMultiplier: 6,
          pixelFormat: 'yuv420p',
          preset: 'veryfast',
          restoreDelayMs: 250,
        );
    }
  }

  _ScrollVideoTuning _scrollVideoTuningFor(StreamProfile profile) {
    return _scrollVideoTunings[profile] ?? _defaultScrollVideoTuning(profile);
  }

  void _syncPreferredScrollVideoTuning(StreamProfile profile) {
    final tuning = _scrollVideoTuningFor(profile);
    _preferredScrollVideoScale = tuning.scale;
    _preferredScrollVideoBitrateKbps = tuning.bitrateKbps;
    _preferredScrollVideoFps = tuning.fps;
    _preferredScrollVideoCrf = tuning.crf;
    _preferredScrollVideoVbvMultiplier = tuning.vbvMultiplier;
    _preferredScrollVideoPixelFormat = tuning.pixelFormat;
    _preferredScrollVideoPreset = tuning.preset;
    _preferredScrollRestoreDelayMs = tuning.restoreDelayMs;
  }

  _ScrollVideoTuning _loadScrollVideoTuning(
    SharedPreferences prefs,
    StreamProfile profile,
  ) {
    final defaults = _defaultScrollVideoTuning(profile);
    final suffix = _profilePrefsName(profile);
    final legacyScale = profile == StreamProfile.hybrid
        ? prefs.getDouble('control.scroll_video_scale')
        : null;
    final legacyBitrate = profile == StreamProfile.hybrid
        ? prefs.getInt('control.scroll_video_bitrate_kbps')
        : null;
    final legacyFps = profile == StreamProfile.hybrid
        ? prefs.getDouble('control.scroll_video_fps')
        : null;
    final legacyCrf = profile == StreamProfile.hybrid
        ? prefs.getInt('control.scroll_video_crf')
        : null;
    final legacyDelay = profile == StreamProfile.hybrid
        ? prefs.getInt('control.scroll_restore_delay_ms')
        : null;
    return _ScrollVideoTuning(
      scale: prefs.getDouble('control.scroll_video.$suffix.scale') ??
          legacyScale ??
          defaults.scale,
      bitrateKbps: prefs.getInt('control.scroll_video.$suffix.bitrate_kbps') ??
          legacyBitrate ??
          defaults.bitrateKbps,
      fps: prefs.getDouble('control.scroll_video.$suffix.fps') ??
          legacyFps ??
          defaults.fps,
      crf: prefs.getInt('control.scroll_video.$suffix.crf') ??
          legacyCrf ??
          defaults.crf,
      vbvMultiplier:
          prefs.getInt('control.scroll_video.$suffix.vbv_multiplier') ??
              defaults.vbvMultiplier,
      pixelFormat:
          prefs.getString('control.scroll_video.$suffix.pixel_format') ??
              defaults.pixelFormat,
      preset: prefs.getString('control.scroll_video.$suffix.preset') ??
          defaults.preset,
      restoreDelayMs:
          prefs.getInt('control.scroll_video.$suffix.restore_delay_ms') ??
              legacyDelay ??
              defaults.restoreDelayMs,
    );
  }

  Future<void> _persistScrollVideoTunings(SharedPreferences prefs) async {
    for (final profile in StreamProfile.values) {
      final tuning = _scrollVideoTuningFor(profile);
      final suffix = _profilePrefsName(profile);
      await prefs.setDouble('control.scroll_video.$suffix.scale', tuning.scale);
      await prefs.setInt(
          'control.scroll_video.$suffix.bitrate_kbps', tuning.bitrateKbps);
      await prefs.setDouble('control.scroll_video.$suffix.fps', tuning.fps);
      await prefs.setInt('control.scroll_video.$suffix.crf', tuning.crf);
      await prefs.setInt(
          'control.scroll_video.$suffix.vbv_multiplier', tuning.vbvMultiplier);
      await prefs.setString(
          'control.scroll_video.$suffix.pixel_format', tuning.pixelFormat);
      await prefs.setString(
          'control.scroll_video.$suffix.preset', tuning.preset);
      await prefs.setInt('control.scroll_video.$suffix.restore_delay_ms',
          tuning.restoreDelayMs);
    }
  }

  void _applyConnectionStreamSettings(
    ControlService controlService, {
    required bool isLocalNetwork,
  }) {
    _isLocalNetworkConnection = isLocalNetwork;
    if (!isLocalNetwork && _preferredStreamProfile == StreamProfile.lan) {
      _preferredStreamProfile = StreamProfile.smoothHd;
    }

    controlService.setStreamProfile(_preferredStreamProfile);
    _usingLocalNetworkPreset = _preferredStreamProfile == StreamProfile.lan;
    controlService.setStreamTuning(
      qualityScale: _preferredStreamProfile == StreamProfile.lan ? 1.0 : 1.0,
      resolutionScale: _preferredStreamProfile == StreamProfile.lan ? 1.0 : 1.0,
      dynamicFpsLimit: _preferredStreamProfile == StreamProfile.lan ||
              _preferredStreamProfile == StreamProfile.smoothHd
          ? 60.0
          : 20.0,
      staticFpsLimit: _preferredStreamProfile == StreamProfile.lan ||
              _preferredStreamProfile == StreamProfile.smoothHd
          ? 60.0
          : 1.0,
    );
    _syncPreferredScrollVideoTuning(_preferredStreamProfile);
    controlService.setScrollVideoTuning(
      scale: _preferredScrollVideoScale,
      bitrateKbps: _preferredScrollVideoBitrateKbps,
      fps: _preferredScrollVideoFps,
      crf: _preferredScrollVideoCrf,
      vbvMultiplier: _preferredScrollVideoVbvMultiplier,
      pixelFormat: _preferredScrollVideoPixelFormat,
      preset: _preferredScrollVideoPreset,
    );
  }

  List<QuickCommandForTest> _decodeQuickCommands(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map((item) => QuickCommandForTest.fromJson(
              Map<String, dynamic>.from(item as Map)))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  List<QuickCommandForTest> _builtinCodexCommands() {
    return const [
      QuickCommandForTest(
        name: '默认启动',
        command: 'codex -C .',
      ),
      QuickCommandForTest(
        name: '全放行启动',
        command: 'codex -C . --dangerously-bypass-approvals-and-sandbox',
      ),
      QuickCommandForTest(
        name: '模型菜单',
        command: '/model',
      ),
      QuickCommandForTest(
        name: '切 GPT-5.5',
        command: '/model gpt-5.5',
      ),
      QuickCommandForTest(
        name: '切 GPT-5.4',
        command: '/model gpt-5.4',
      ),
      QuickCommandForTest(
        name: '切 Mini',
        command: '/model gpt-5.4-mini',
      ),
      QuickCommandForTest(
        name: '查看状态',
        command: '/status',
      ),
    ];
  }
}

class _VirtualKeyDefinition {
  final String label;
  final int keyCode;
  final int flex;
  final double? fontSize;
  final Set<_KeyboardModifier> modifiers;

  const _VirtualKeyDefinition(
    this.label,
    this.keyCode, {
    this.flex = 1,
    this.fontSize,
    this.modifiers = const <_KeyboardModifier>{},
  });
}

class _KeyboardOverlayPanel extends StatelessWidget {
  final double width;
  final double height;
  final _KeyboardPage page;
  final Set<_KeyboardModifier> modifiers;
  final ValueChanged<_KeyboardPage> onPageChanged;
  final ValueChanged<Offset> onDragUpdate;
  final ValueChanged<_VirtualKeyDefinition> onKeyPressed;
  final ValueChanged<_KeyboardModifier> onModifierPressed;

  const _KeyboardOverlayPanel({
    required this.width,
    required this.height,
    required this.page,
    required this.modifiers,
    required this.onPageChanged,
    required this.onDragUpdate,
    required this.onKeyPressed,
    required this.onModifierPressed,
  });

  static const List<List<_VirtualKeyDefinition>> _numberRows = [
    [
      _VirtualKeyDefinition('7', 0x37),
      _VirtualKeyDefinition('8', 0x38),
      _VirtualKeyDefinition('9', 0x39),
    ],
    [
      _VirtualKeyDefinition('4', 0x34),
      _VirtualKeyDefinition('5', 0x35),
      _VirtualKeyDefinition('6', 0x36),
    ],
    [
      _VirtualKeyDefinition('1', 0x31),
      _VirtualKeyDefinition('2', 0x32),
      _VirtualKeyDefinition('3', 0x33),
    ],
    [
      _VirtualKeyDefinition('0', 0x30),
      _VirtualKeyDefinition('.', _ControlScreenState._vkOemPeriod),
      _VirtualKeyDefinition('=', _ControlScreenState._vkOemPlus),
    ],
  ];

  static const List<List<_VirtualKeyDefinition>> _auxRows = [
    [
      _VirtualKeyDefinition('/', _ControlScreenState._vkOem2),
      _VirtualKeyDefinition('-', _ControlScreenState._vkOemMinus),
      _VirtualKeyDefinition('↑', _ControlScreenState._vkUp),
      _VirtualKeyDefinition('+', _ControlScreenState._vkOemPlus,
          modifiers: {_KeyboardModifier.shift}),
    ],
    [
      _VirtualKeyDefinition('*', 0x38, modifiers: {_KeyboardModifier.shift}),
      _VirtualKeyDefinition('←', _ControlScreenState._vkLeft),
      _VirtualKeyDefinition('↓', _ControlScreenState._vkDown),
      _VirtualKeyDefinition('→', _ControlScreenState._vkRight),
    ],
    [
      _VirtualKeyDefinition('Home', _ControlScreenState._vkHome,
          flex: 2, fontSize: 10.5),
      _VirtualKeyDefinition('End', _ControlScreenState._vkEnd,
          flex: 2, fontSize: 10.5),
    ],
  ];

  static const List<List<_VirtualKeyDefinition>> _letterRows = [
    [
      _VirtualKeyDefinition('Q', 0x51),
      _VirtualKeyDefinition('W', 0x57),
      _VirtualKeyDefinition('E', 0x45),
      _VirtualKeyDefinition('R', 0x52),
      _VirtualKeyDefinition('T', 0x54),
      _VirtualKeyDefinition('Y', 0x59),
      _VirtualKeyDefinition('U', 0x55),
      _VirtualKeyDefinition('I', 0x49),
      _VirtualKeyDefinition('O', 0x4F),
      _VirtualKeyDefinition('P', 0x50),
    ],
    [
      _VirtualKeyDefinition('A', 0x41),
      _VirtualKeyDefinition('S', 0x53),
      _VirtualKeyDefinition('D', 0x44),
      _VirtualKeyDefinition('F', 0x46),
      _VirtualKeyDefinition('G', 0x47),
      _VirtualKeyDefinition('H', 0x48),
      _VirtualKeyDefinition('J', 0x4A),
      _VirtualKeyDefinition('K', 0x4B),
      _VirtualKeyDefinition('L', 0x4C),
    ],
    [
      _VirtualKeyDefinition('Z', 0x5A),
      _VirtualKeyDefinition('X', 0x58),
      _VirtualKeyDefinition('C', 0x43),
      _VirtualKeyDefinition('V', 0x56),
      _VirtualKeyDefinition('B', 0x42),
      _VirtualKeyDefinition('N', 0x4E),
      _VirtualKeyDefinition('M', 0x4D),
      _VirtualKeyDefinition('_', _ControlScreenState._vkOemMinus,
          modifiers: {_KeyboardModifier.shift}),
    ],
    [
      _VirtualKeyDefinition(',', _ControlScreenState._vkOemComma),
      _VirtualKeyDefinition('Space', _ControlScreenState._vkSpace,
          flex: 4, fontSize: 12),
      _VirtualKeyDefinition('.', _ControlScreenState._vkOemPeriod),
    ],
  ];

  static const List<List<_VirtualKeyDefinition>> _symbolRows = [
    [
      _VirtualKeyDefinition('@', 0x32, modifiers: {_KeyboardModifier.shift}),
      _VirtualKeyDefinition('!', 0x31, modifiers: {_KeyboardModifier.shift}),
      _VirtualKeyDefinition('?', _ControlScreenState._vkOem2,
          modifiers: {_KeyboardModifier.shift}),
      _VirtualKeyDefinition(':', _ControlScreenState._vkOem1,
          modifiers: {_KeyboardModifier.shift}),
      _VirtualKeyDefinition(';', _ControlScreenState._vkOem1),
      _VirtualKeyDefinition('"', _ControlScreenState._vkOem7,
          modifiers: {_KeyboardModifier.shift}),
      _VirtualKeyDefinition('\'', _ControlScreenState._vkOem7),
      _VirtualKeyDefinition('(', 0x39, modifiers: {_KeyboardModifier.shift}),
      _VirtualKeyDefinition(')', 0x30, modifiers: {_KeyboardModifier.shift}),
      _VirtualKeyDefinition('_', _ControlScreenState._vkOemMinus,
          modifiers: {_KeyboardModifier.shift}),
    ],
    [
      _VirtualKeyDefinition('#', 0x33, modifiers: {_KeyboardModifier.shift}),
      _VirtualKeyDefinition('\$', 0x34, modifiers: {_KeyboardModifier.shift}),
      _VirtualKeyDefinition('%', 0x35, modifiers: {_KeyboardModifier.shift}),
      _VirtualKeyDefinition('&', 0x37, modifiers: {_KeyboardModifier.shift}),
      _VirtualKeyDefinition('*', 0x38, modifiers: {_KeyboardModifier.shift}),
      _VirtualKeyDefinition('|', _ControlScreenState._vkOem5,
          modifiers: {_KeyboardModifier.shift}),
      _VirtualKeyDefinition('~', _ControlScreenState._vkOem3,
          modifiers: {_KeyboardModifier.shift}),
      _VirtualKeyDefinition('<', _ControlScreenState._vkOemComma,
          modifiers: {_KeyboardModifier.shift}),
      _VirtualKeyDefinition('>', _ControlScreenState._vkOemPeriod,
          modifiers: {_KeyboardModifier.shift}),
    ],
    [
      _VirtualKeyDefinition('[', _ControlScreenState._vkOem4),
      _VirtualKeyDefinition(']', _ControlScreenState._vkOem6),
      _VirtualKeyDefinition('{', _ControlScreenState._vkOem4,
          modifiers: {_KeyboardModifier.shift}),
      _VirtualKeyDefinition('}', _ControlScreenState._vkOem6,
          modifiers: {_KeyboardModifier.shift}),
      _VirtualKeyDefinition('`', _ControlScreenState._vkOem3),
      _VirtualKeyDefinition('_', _ControlScreenState._vkOemMinus,
          modifiers: {_KeyboardModifier.shift}),
      _VirtualKeyDefinition('-', _ControlScreenState._vkOemMinus),
      _VirtualKeyDefinition('+', _ControlScreenState._vkOemPlus,
          modifiers: {_KeyboardModifier.shift}),
    ],
    [
      _VirtualKeyDefinition('/', _ControlScreenState._vkOem2),
      _VirtualKeyDefinition('Space', _ControlScreenState._vkSpace,
          flex: 4, fontSize: 12),
      _VirtualKeyDefinition('=', _ControlScreenState._vkOemPlus),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    final List<List<_VirtualKeyDefinition>> modeRows =
        page == _KeyboardPage.letters ? _letterRows : _symbolRows;
    final topSectionHeight = (height * 0.40).clamp(116.0, 140.0);
    const modifierHeight = 26.0;
    final topKeyHeight = ((topSectionHeight - 12.0) / 4).clamp(24.0, 30.0);
    final auxKeyHeight = ((topSectionHeight - 8.0) / 3).clamp(24.0, 34.0);
    final middleSectionHeight =
        height - 30.0 - topSectionHeight - modifierHeight - 6.0;
    final modeKeyHeight = ((middleSectionHeight - 12.0) / 4).clamp(24.0, 32.0);
    return Material(
      color: Colors.transparent,
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            SizedBox(
              height: 30,
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (details) => onDragUpdate(details.delta),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          height: 7,
                          margin: const EdgeInsets.only(left: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF6E7786),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  SizedBox(
                    width: 126,
                    child: Row(
                      children: [
                        Expanded(
                          child: _KeyboardToggleChip(
                            label: 'ABC',
                            active: page == _KeyboardPage.letters,
                            height: 28,
                            onTap: () => onPageChanged(_KeyboardPage.letters),
                          ),
                        ),
                        const SizedBox(width: 2),
                        Expanded(
                          child: _KeyboardToggleChip(
                            label: '符号',
                            active: page == _KeyboardPage.symbols,
                            height: 28,
                            onTap: () => onPageChanged(_KeyboardPage.symbols),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            SizedBox(
              height: topSectionHeight,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: const BoxDecoration(
                  color: Color(0xFF151922),
                  border: Border(
                    top: BorderSide(color: Color(0xFF2C3444)),
                    bottom: BorderSide(color: Color(0xFF2C3444)),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Column(
                        children: [
                          for (var rowIndex = 0;
                              rowIndex < _numberRows.length;
                              rowIndex++) ...[
                            Expanded(
                              child: _KeyboardKeyRow(
                                keys: _numberRows[rowIndex],
                                keyHeight: topKeyHeight,
                                spacing: 2,
                                onKeyPressed: onKeyPressed,
                              ),
                            ),
                            if (rowIndex != _numberRows.length - 1)
                              const SizedBox(height: 2),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 2),
                    Expanded(
                      flex: 4,
                      child: Column(
                        children: [
                          for (var rowIndex = 0;
                              rowIndex < _auxRows.length;
                              rowIndex++) ...[
                            Expanded(
                              child: _KeyboardKeyRow(
                                keys: _auxRows[rowIndex],
                                keyHeight: auxKeyHeight,
                                spacing: 2,
                                onKeyPressed: onKeyPressed,
                              ),
                            ),
                            if (rowIndex != _auxRows.length - 1)
                              const SizedBox(height: 2),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 2),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: const BoxDecoration(
                  color: Color(0xFF151922),
                  border: Border(
                    top: BorderSide(color: Color(0xFF2C3444)),
                    bottom: BorderSide(color: Color(0xFF2C3444)),
                  ),
                ),
                child: Column(
                  children: [
                    for (var rowIndex = 0;
                        rowIndex < modeRows.length;
                        rowIndex++) ...[
                      Expanded(
                        child: _KeyboardKeyRow(
                          keys: modeRows[rowIndex],
                          keyHeight: modeKeyHeight,
                          spacing: 2,
                          onKeyPressed: onKeyPressed,
                        ),
                      ),
                      if (rowIndex != modeRows.length - 1)
                        const SizedBox(height: 2),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              decoration: const BoxDecoration(
                color: Color(0xFF151922),
                border: Border(
                  top: BorderSide(color: Color(0xFF2C3444)),
                  bottom: BorderSide(color: Color(0xFF2C3444)),
                ),
              ),
              child: _KeyboardModifierRow(
                modifiers: modifiers,
                onModifierPressed: onModifierPressed,
                keyHeight: modifierHeight,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
class _KeyboardModifierRow extends StatelessWidget {
  final Set<_KeyboardModifier> modifiers;
  final ValueChanged<_KeyboardModifier> onModifierPressed;
  final double keyHeight;

  const _KeyboardModifierRow({
    required this.modifiers,
    required this.onModifierPressed,
    required this.keyHeight,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _KeyboardToggleChip(
            label: 'Ctrl',
            active: modifiers.contains(_KeyboardModifier.ctrl),
            height: keyHeight,
            onTap: () => onModifierPressed(_KeyboardModifier.ctrl),
          ),
        ),
        const SizedBox(width: 2),
        Expanded(
          child: _KeyboardToggleChip(
            label: 'Alt',
            active: modifiers.contains(_KeyboardModifier.alt),
            height: keyHeight,
            onTap: () => onModifierPressed(_KeyboardModifier.alt),
          ),
        ),
        const SizedBox(width: 2),
        Expanded(
          child: _KeyboardToggleChip(
            label: 'Shift',
            active: modifiers.contains(_KeyboardModifier.shift),
            height: keyHeight,
            onTap: () => onModifierPressed(_KeyboardModifier.shift),
          ),
        ),
      ],
    );
  }
}

class _KeyboardKeyRow extends StatelessWidget {
  final List<_VirtualKeyDefinition> keys;
  final double keyHeight;
  final double spacing;
  final ValueChanged<_VirtualKeyDefinition> onKeyPressed;

  const _KeyboardKeyRow({
    required this.keys,
    required this.keyHeight,
    this.spacing = 4,
    required this.onKeyPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var index = 0; index < keys.length; index++) ...[
          Expanded(
            flex: keys[index].flex,
            child: _KeyboardKeyButton(
              label: keys[index].label,
              height: keyHeight,
              fontSize: keys[index].fontSize,
              onTap: () => onKeyPressed(keys[index]),
            ),
          ),
          if (index != keys.length - 1) SizedBox(width: spacing),
        ],
      ],
    );
  }
}

class _KeyboardKeyButton extends StatelessWidget {
  final String label;
  final double height;
  final VoidCallback onTap;
  final double? fontSize;

  const _KeyboardKeyButton({
    required this.label,
    required this.height,
    required this.onTap,
    this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFF2B3341),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF414C5F)),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.fade,
          softWrap: false,
          style: TextStyle(
            color: Colors.white,
            fontSize: fontSize ?? 11.8,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _KeyboardToggleChip extends StatelessWidget {
  final String label;
  final bool active;
  final double height;
  final VoidCallback onTap;

  const _KeyboardToggleChip({
    required this.label,
    required this.active,
    required this.onTap,
    this.height = 28,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: active ? const Color(0xFF2E6BE6) : const Color(0xFF2B3341),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? const Color(0xFF84B3FF) : const Color(0xFF414C5F),
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11.2,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

@visibleForTesting
class QuickCommandSheetForTest extends StatefulWidget {
  final String title;
  final String builtinTitle;
  final String customTitle;
  final String emptyText;
  final String addLabel;
  final String addHint;
  final String nameTitle;
  final String nameHint;
  final String savePresetLabel;
  final List<QuickCommandForTest> builtinCommands;
  final List<QuickCommandForTest> quickCommands;
  final ValueChanged<String> onCommandSelected;
  final Future<void> Function(String name) onDeleteCommand;
  final Future<void> Function(String name, String command) onSaveCommand;

  const QuickCommandSheetForTest({
    super.key,
    required this.title,
    required this.builtinTitle,
    required this.customTitle,
    required this.emptyText,
    required this.addLabel,
    required this.addHint,
    required this.nameTitle,
    required this.nameHint,
    required this.savePresetLabel,
    required this.builtinCommands,
    required this.quickCommands,
    required this.onCommandSelected,
    required this.onDeleteCommand,
    required this.onSaveCommand,
  });

  @override
  State<QuickCommandSheetForTest> createState() => _QuickCommandSheetState();
}

class _QuickCommandSheetState extends State<QuickCommandSheetForTest> {
  late final TextEditingController _nameController;
  late final TextEditingController _commandController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _commandController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _commandController.dispose();
    super.dispose();
  }

  Future<void> _savePreset() async {
    final name = _nameController.text.trim();
    final command = _commandController.text.trim();
    if (name.isEmpty || command.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('请先填写命令名称和命令内容')),
      );
      return;
    }
    await widget.onSaveCommand(name, command);
    if (!mounted) return;
    _nameController.clear();
    _commandController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    return SafeArea(
      top: false,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: mediaQuery.size.height * 0.82),
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Text(
                  widget.builtinTitle,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: widget.builtinCommands
                      .map(
                        (item) => InputChip(
                          label: Text(item.name),
                          onPressed: () =>
                              widget.onCommandSelected(item.command),
                        ),
                      )
                      .toList(growable: false),
                ),
                const SizedBox(height: 16),
                Text(
                  widget.customTitle,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                if (widget.quickCommands.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(widget.emptyText),
                  )
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: widget.quickCommands
                        .map(
                          (item) => InputChip(
                            label: Text(item.name),
                            onPressed: () =>
                                widget.onCommandSelected(item.command),
                            onDeleted: () => widget.onDeleteCommand(item.name),
                          ),
                        )
                        .toList(growable: false),
                  ),
                const SizedBox(height: 16),
                TextField(
                  controller: _nameController,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: widget.nameTitle,
                    hintText: widget.nameHint,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _commandController,
                  minLines: 1,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: widget.addLabel,
                    hintText: widget.addHint,
                    border: const OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _savePreset(),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _savePreset,
                    child: Text(widget.savePresetLabel),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
