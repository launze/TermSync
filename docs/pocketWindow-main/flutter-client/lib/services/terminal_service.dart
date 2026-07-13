import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import 'signaling_service.dart';

/// A terminal session that lives on the desktop. The phone may or may not be
/// currently attached to it.
class RemoteSessionInfo {
  RemoteSessionInfo({
    required this.id,
    required this.shell,
    required this.title,
    required this.cols,
    required this.rows,
    required this.attached,
  });

  final String id;
  final String shell;
  final String title;
  final int cols;
  final int rows;
  final bool attached;

  factory RemoteSessionInfo.fromMap(Map<String, dynamic> m) {
    return RemoteSessionInfo(
      id: m['id']?.toString() ?? '',
      shell: m['shell']?.toString() ?? 'powershell',
      title: m['title']?.toString() ?? '',
      cols: (m['cols'] as num?)?.toInt() ?? 80,
      rows: (m['rows'] as num?)?.toInt() ?? 24,
      attached: m['attached'] == true,
    );
  }
}

/// Local state for a session the phone is currently attached to (rendered).
class TerminalSessionState {
  TerminalSessionState({
    required this.sessionId,
    required this.shell,
    required this.title,
    required this.terminal,
  }) {
    // Streaming UTF-8 decoder: PTY byte chunks may split a multi-byte
    // character across packet boundaries, so we feed bytes through a chunked
    // converter that buffers partial sequences and emits complete strings.
    _decodeSink = _utf8Decoder.startChunkedConversion(
      _StringCallbackSink((decoded) => terminal.write(decoded)),
    );
  }

  final String sessionId;
  final String shell;
  final String title;
  final Terminal terminal;

  static const Utf8Decoder _utf8Decoder = Utf8Decoder(allowMalformed: true);
  late final Sink<List<int>> _decodeSink;

  /// Feed raw PTY bytes; complete characters are written to the terminal.
  void feedBytes(List<int> bytes) {
    _decodeSink.add(bytes);
  }

  bool attached = false;
  bool closed = false;
  int cols = 80;
  int rows = 24;

  /// Debounce timer for resize events (keyboard show/hide causes a burst).
  Timer? resizeDebounce;
  /// Last size we actually sent to the desktop, to suppress no-op resizes.
  int sentCols = 0;
  int sentRows = 0;
  /// Diagnostics: total snapshot bytes received and chunk count.
  int snapBytes = 0;
  int snapChunks = 0;
  int dataPackets = 0;
}

/// Adapts a callback into the Sink<String> that Utf8Decoder.startChunkedConversion expects.
class _StringCallbackSink implements Sink<String> {
  _StringCallbackSink(this._onString);
  final void Function(String) _onString;

  @override
  void add(String data) => _onString(data);

  @override
  void close() {}
}

/// Manages terminal sessions over the existing control channel.
///
/// Ownership model: the desktop owns sessions (generates ids, keeps PTYs alive
/// across detach). The phone lists/attaches/creates/detaches; it never owns a
/// session id.
class TerminalService extends ChangeNotifier {
  SignalingService? _signalingService;
  Function(Map<String, dynamic>)? _previousControlMessageCallback;

  // Sessions currently rendered by the phone (attached).
  final Map<String, TerminalSessionState> _attached = {};
  // Latest desktop session list + available shells from terminal.list.
  List<RemoteSessionInfo> _remoteSessions = [];
  List<String> _availableShells = const ['powershell', 'pwsh', 'cmd'];

  // Pending create requests keyed by a client token so we can attach once the
  // desktop assigns an id. Stores the measured size to use on attach.
  String? _pendingCreateShell;

  List<TerminalSessionState> get attachedSessions => _attached.values.toList();
  List<RemoteSessionInfo> get remoteSessions => _remoteSessions;
  List<String> get availableShells => _availableShells;

  bool get isConnected => _signalingService?.isConnected == true;

  void attachSignalingService(SignalingService service) {
    if (identical(_signalingService, service)) return;
    detachSignaling();
    _signalingService = service;
    _previousControlMessageCallback = service.onControlMessage;
    service.onControlMessage = _handleControlMessage;
  }

  void detachSignaling() {
    final service = _signalingService;
    if (service != null) {
      service.onControlMessage = _previousControlMessageCallback;
    }
    _previousControlMessageCallback = null;
    _signalingService = null;
  }

  /// Ask the desktop for the current session list + available shells.
  void requestList() {
    _send('terminal.list', {});
  }

  /// Request the desktop to create a new session. The desktop assigns the id
  /// and replies with terminal.created; we then attach automatically.
  void createSession({String shell = 'powershell'}) {
    _pendingCreateShell = shell;
    _send('terminal.create', {
      'shell': shell,
      'cols': 80,
      'rows': 24,
    });
  }

  /// Attach to an existing desktop session and start rendering it locally.
  TerminalSessionState attach(RemoteSessionInfo info) {
    var state = _attached[info.id];
    if (state != null) return state;

    final terminal = Terminal(maxLines: 4000);
    state = TerminalSessionState(
      sessionId: info.id,
      shell: info.shell,
      title: info.title,
      terminal: terminal,
    );
    state.cols = info.cols;
    state.rows = info.rows;
    _attached[info.id] = state;

    terminal.onOutput = (data) {
      _send('terminal.input', {
        'session_id': info.id,
        'b64': base64Encode(utf8.encode(data)),
      });
    };
    terminal.onResize = (w, h, pw, ph) {
      if (w <= 0 || h <= 0) return;
      final s = state!;
      s.cols = w;
      s.rows = h;
      // Keyboard show/hide triggers a burst of layout changes; debounce so we
      // only send the final stable size to the desktop (avoids resize storms).
      s.resizeDebounce?.cancel();
      s.resizeDebounce = Timer(const Duration(milliseconds: 300), () {
        if (s.closed) return;
        if (s.cols == s.sentCols && s.rows == s.sentRows) {
          return;
        }
        s.sentCols = s.cols;
        s.sentRows = s.rows;
        _send('terminal.resize', {
          'session_id': info.id,
          'cols': s.cols,
          'rows': s.rows,
        });
      });
    };

    // The desktop resizes to our size and returns a snapshot.
    state.sentCols = state.cols;
    state.sentRows = state.rows;
    _send('terminal.attach', {
      'session_id': info.id,
      'cols': state.cols,
      'rows': state.rows,
    });
    clientLog('attach id=${info.id} cols=${state.cols} rows=${state.rows} '
        'termViewHeight=${terminal.viewHeight}');
    state.attached = true;
    notifyListeners();
    return state;
  }

  /// Stop watching a session locally; the desktop keeps the PTY alive.
  void detach(String sessionId) {
    final state = _attached.remove(sessionId);
    if (state == null) return;
    state.resizeDebounce?.cancel();
    _send('terminal.detach', {'session_id': sessionId});
    notifyListeners();
  }

  /// Permanently close a session (destroys the desktop PTY).
  void closeSession(String sessionId) {
    final state = _attached.remove(sessionId);
    state?.resizeDebounce?.cancel();
    state?.closed = true;
    _send('terminal.close', {'session_id': sessionId});
    notifyListeners();
  }

  void _send(String command, Map<String, dynamic> params) {
    _signalingService?.sendControl(command, params);
  }

  /// Scroll the *program's own* viewport by injecting mouse-wheel events on the
  /// desktop. Full-screen TUIs (opencode etc.) keep their history internally
  /// and scroll it with the wheel; we reproduce that 1:1 instead of building
  /// our own history. The desktop repaints and pushes a fresh terminal.screen.
  void requestScroll(String sessionId, String direction, int lines) {
    _send('terminal.scroll', {
      'session_id': sessionId,
      'direction': direction,
      'lines': lines,
    });
  }

  /// Diagnostics: ship a log line to the desktop so it lands in agent.out.log.
  void clientLog(String msg) {
    _send('terminal.clientlog', {'msg': msg});
  }

  void _handleControlMessage(Map<String, dynamic> data) {
    final command = data['command']?.toString();
    if (command == null || !command.startsWith('terminal.')) {
      _previousControlMessageCallback?.call(data);
      return;
    }
    final params = (data['params'] as Map?)?.cast<String, dynamic>() ?? const {};

    switch (command) {
      case 'terminal.sessions':
        final shells = (params['shells'] as List?)?.map((e) => e.toString()).toList();
        if (shells != null && shells.isNotEmpty) {
          _availableShells = shells;
        }
        final list = (params['sessions'] as List?) ?? const [];
        _remoteSessions = list
            .whereType<Map>()
            .map((e) => RemoteSessionInfo.fromMap(e.cast<String, dynamic>()))
            .toList();
        notifyListeners();
        break;

      case 'terminal.created':
        if (params['ok'] != true) break;
        final id = params['session_id']?.toString() ?? '';
        if (id.isEmpty) break;
        final info = RemoteSessionInfo(
          id: id,
          shell: params['shell']?.toString() ?? (_pendingCreateShell ?? 'powershell'),
          title: params['title']?.toString() ?? '',
          cols: (params['cols'] as num?)?.toInt() ?? 80,
          rows: (params['rows'] as num?)?.toInt() ?? 24,
          attached: false,
        );
        _pendingCreateShell = null;
        attach(info);
        break;

      case 'terminal.data':
      case 'terminal.snapshot':
        final id = params['session_id']?.toString() ?? '';
        final state = _attached[id];
        if (state == null) break;
        final b64 = params['b64']?.toString();
        if (b64 != null) {
          final bytes = base64Decode(b64);
          if (command == 'terminal.snapshot') {
            state.snapBytes += bytes.length;
            state.snapChunks += 1;
          } else {
            state.dataPackets += 1;
          }
          state.feedBytes(bytes);
          final t = state.terminal;
          clientLog('recv $command bytes=${bytes.length} '
              'snapTotal=${state.snapBytes} snapChunks=${state.snapChunks} '
              'dataPkts=${state.dataPackets} '
              'bufLines=${t.buffer.lines.length} vh=${t.viewHeight} '
              'scrollBack=${t.buffer.scrollBack}');
        }
        break;

      case 'terminal.close':
        final id = params['session_id']?.toString() ?? '';
        final state = _attached[id];
        if (state != null) {
          state.closed = true;
        }
        _remoteSessions = _remoteSessions.where((s) => s.id != id).toList();
        notifyListeners();
        break;
    }
  }

  @override
  void dispose() {
    detachSignaling();
    _attached.clear();
    super.dispose();
  }
}
