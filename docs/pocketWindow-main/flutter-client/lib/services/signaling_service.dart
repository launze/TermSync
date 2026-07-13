import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pocketwindow/services/signaling_channels.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum ConnectionStatus { idle, connecting, connected, failed }

class SignalingService with ChangeNotifier {
  WebSocketChannel? _channel;
  SignalingChannels? _channels;
  String _serverUrl;
  String _roomId;
  String _clientId;
  String _clientName;
  String _deviceId;
  String _totpCode = '';
  String _totpNonce = '';
  Completer<void>? _connectCompleter;

  ConnectionStatus _status = ConnectionStatus.idle;
  String? _errorMessage;

  SignalingService({
    String serverUrl = 'ws://127.0.0.1:58080',
    String roomId = '',
    String clientId = '',
    String clientName = '',
    String deviceId = '',
  })  : _serverUrl = serverUrl,
        _roomId = roomId,
        _clientId = clientId,
        _clientName = clientName,
        _deviceId = deviceId;

  ConnectionStatus get status => _status;
  String? get errorMessage => _errorMessage;
  String get serverUrl => _serverUrl;
  bool get isLanDirectConnection {
    final uri = Uri.tryParse(_normalizeWsUrl(_serverUrl));
    final port = uri?.port ?? 0;
    return port == 58082;
  }

  /// True when the next connect() will attach TOTP credentials, i.e. we
  /// are about to join a desktop's public-direct endpoint that lives
  /// behind a NAS frpc port forward instead of the signaling relay or
  /// the legacy LAN port. Diagnostic-only; does not change protocol.
  bool get isPublicDirectConnection => _totpCode.isNotEmpty;
  String get roomId => _roomId;
  String get clientId => _clientId;
  String get clientName => _clientName;
  String get deviceId => _deviceId;
  bool get isConnected => _status == ConnectionStatus.connected;

  Function(Map<String, dynamic>)? onRemoteConnected;
  Function(Map<String, dynamic>)? onRemoteDisconnected;
  Function(Map<String, dynamic>)? onImageFrame;
  Function(Map<String, dynamic>)? onVideoStream;
  Function(Map<String, dynamic>)? onCursorPosition;
  Function(Map<String, dynamic>)? onControlResponse;
  Function(Map<String, dynamic>)? onControlMessage;
  Function(Map<String, dynamic>)? onWindowsList;
  Function(Map<String, dynamic>)? onSetWindowResponse;
  Function(Map<String, dynamic>)? onWebRtcSignal;

  set serverUrl(String value) {
    _serverUrl = value;
    notifyListeners();
  }

  set roomId(String value) {
    _roomId = value;
    notifyListeners();
  }

  set clientId(String value) {
    _clientId = value;
    notifyListeners();
  }

  set clientName(String value) {
    _clientName = value;
    notifyListeners();
  }

  set deviceId(String value) {
    _deviceId = value;
    notifyListeners();
  }

  /// Configure (or clear) the TOTP credentials that will be sent in the
  /// next connect()'s join_room frame. Pass empty strings — or call
  /// `clearPublicDirectAuth()` — when reverting to the signaling
  /// relay / LAN-direct flow. Stored verbatim; rotation is the caller's
  /// responsibility (each connect() should generate a fresh nonce).
  void setPublicDirectAuth({required String totpCode, required String totpNonce}) {
    _totpCode = totpCode;
    _totpNonce = totpNonce;
    notifyListeners();
  }

  void clearPublicDirectAuth() {
    if (_totpCode.isEmpty && _totpNonce.isEmpty) return;
    _totpCode = '';
    _totpNonce = '';
    notifyListeners();
  }

  String _normalizeWsUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Server URL is required');
    }

    final withScheme =
        trimmed.startsWith('ws://') || trimmed.startsWith('wss://')
            ? trimmed
            : 'ws://$trimmed';
    final uri = Uri.parse(withScheme);
    if (uri.path.isEmpty || uri.path == '/') {
      return uri.replace(path: '/ws').toString();
    }
    return uri.toString();
  }

  Uri _httpApiUri(String path) {
    final wsUri = Uri.parse(_normalizeWsUrl(_serverUrl));
    final scheme = wsUri.scheme == 'wss' ? 'https' : 'http';
    return wsUri.replace(scheme: scheme, path: path, query: '');
  }

  Future<List<Map<String, dynamic>>> fetchAgents() async {
    final uri = _httpApiUri('/api/agents');
    final response = await http.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Failed to load agents: ${response.statusCode}');
    }
    final decoded = json.decode(response.body) as Map<String, dynamic>;
    final agents = decoded['agents'];
    if (agents is! List) return [];
    return agents
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> fetchIceServers() async {
    final uri = _httpApiUri('/api/ice-servers');
    final response = await http.get(uri).timeout(const Duration(seconds: 5));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Failed to load ICE servers: ${response.statusCode}');
    }
    final decoded = json.decode(response.body) as Map<String, dynamic>;
    final servers = decoded['iceServers'];
    if (servers is! List) return [];
    return servers
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .where((item) => item['urls'] is String || item['urls'] is List)
        .toList(growable: false);
  }

  Future<void> connect() async {
    if (isConnected) return;
    if (_roomId.trim().isEmpty) {
      throw ArgumentError('Room ID is required');
    }
    if (_clientId.trim().isEmpty) {
      throw ArgumentError('Client ID is required');
    }
    if (_deviceId.trim().isEmpty) {
      throw ArgumentError('Device ID is required');
    }

    if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
      return _connectCompleter!.future;
    }

    _connectCompleter = Completer<void>();
    _status = ConnectionStatus.connecting;
    _errorMessage = null;
    notifyListeners();

    try {
      final channels = SignalingChannels(
        serverUrl: _serverUrl,
        roomId: _roomId,
        clientId: _clientId,
        clientName: _clientName,
        deviceId: _deviceId,
        totpCode: _totpCode.isEmpty ? null : _totpCode,
        totpNonce: _totpNonce.isEmpty ? null : _totpNonce,
        onMessage: _handleMessage,
        onError: (error) {
          _status = ConnectionStatus.failed;
          _errorMessage = error.toString();
          notifyListeners();
          if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
            _connectCompleter!.completeError(error);
          }
        },
        onDone: (channel) {
          if (channel != 'control') {
            return;
          }
          if (_status == ConnectionStatus.connecting) {
            _status = ConnectionStatus.failed;
            _errorMessage = 'WebSocket closed before join completed';
            if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
              _connectCompleter!.completeError(_errorMessage!);
            }
          } else {
            _status = ConnectionStatus.idle;
          }
          notifyListeners();
        },
      );
      _channels = channels;
      await channels.connect();
      return _connectCompleter!.future;
    } catch (e) {
      _status = ConnectionStatus.failed;
      _errorMessage = e.toString();
      notifyListeners();
      if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
        _connectCompleter!.completeError(e);
      }
      rethrow;
    }
  }

  void disconnect() {
    final completer = _connectCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(Exception('disconnect() called while connecting'));
    }
    _channels?.disconnect();
    _channels = null;
    _channel?.sink.close();
    _channel = null;
    _connectCompleter = null;
    _status = ConnectionStatus.idle;
    notifyListeners();
  }

  Future<bool> reconnectMedia() async {
    final channels = _channels;
    if (channels == null || !isConnected) return false;
    return channels.reconnectMedia();
  }

  bool sendControl(String command, Map<String, dynamic> params) {
    if (!isConnected) return false;
    return _sendControlPayload({
      'type': 'control',
      'room_id': _roomId,
      'command': command,
      'params': params,
    });
  }

  void requestWindowsList() {
    if (!isConnected) return;
    _sendControlPayload({
      'type': 'get_windows',
      'room_id': _roomId,
    });
  }

  void setWindow(int hwnd) {
    if (!isConnected) return;
    _sendControlPayload({
      'type': 'set_window',
      'room_id': _roomId,
      'hwnd': hwnd,
    });
  }

  void sendImageFrameAck() {
    if (!isConnected) return;
    _sendControlPayload({
      'type': 'image_frame_ack',
      'room_id': _roomId,
    });
  }

  void sendVideoStreamStatus({
    required bool active,
    String codec = 'h264',
    String reason = '',
  }) {
    if (!isConnected) return;
    _sendControlPayload({
      'type': 'video_stream_status',
      'room_id': _roomId,
      'active': active,
      'codec': codec,
      'reason': reason,
    });
  }

  void sendVideoFrameAck(Map<String, dynamic> payload) {
    if (!isConnected) return;
    _sendControlPayload({
      ...payload,
      'type': 'video_frame_ack',
      'room_id': _roomId,
    });
  }

  void sendVideoCongestion(Map<String, dynamic> payload) {
    if (!isConnected) return;
    _sendControlPayload({
      ...payload,
      'type': 'video_congestion',
      'room_id': _roomId,
    });
  }

  void sendWebRtcSignal(String type, Map<String, dynamic> payload) {
    if (!isConnected) return;
    if (type != 'webrtc_offer' &&
        type != 'webrtc_answer' &&
        type != 'webrtc_ice_candidate' &&
        type != 'webrtc_transport_state') {
      throw ArgumentError('Unsupported WebRTC signaling type: $type');
    }
    _sendControlPayload({
      ...payload,
      'type': type,
      'room_id': _roomId,
    });
  }

  bool _sendControlPayload(Map<String, dynamic> payload) {
    final channels = _channels;
    if (channels != null) {
      channels.sendControl(payload);
      return channels.controlConnected;
    }
    if (_channel == null) return false;
    _channel!.sink.add(json.encode(payload));
    return true;
  }

  void _handleMessage(Map<String, dynamic> data) {
    switch (data['type']) {
      case 'room_joined':
        if (data['channel'] != null && data['channel'] != 'control') {
          break;
        }
        _status = ConnectionStatus.connected;
        notifyListeners();
        if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
          _connectCompleter!.complete();
        }
        break;
      case 'remote_connected':
        onRemoteConnected?.call(data);
        break;
      case 'remote_disconnected':
        onRemoteDisconnected?.call(data);
        break;
      case 'image_frame':
        onImageFrame?.call(data);
        break;
      case 'video_stream_start':
      case 'video_stream_frame':
      case 'video_stream_stop':
      case 'video_stream_progress':
      case 'video_stream_keepalive':
      case 'video_transport_trace':
      case 'video_transport_send_result':
        onVideoStream?.call(data);
        break;
      case 'cursor_position':
        onCursorPosition?.call(data);
        break;
      case 'control_response':
        onControlResponse?.call(data);
        break;
      case 'control':
        onControlMessage?.call(data);
        break;
      case 'windows_list':
        onWindowsList?.call(data);
        break;
      case 'set_window_response':
        onSetWindowResponse?.call(data);
        break;
      case 'webrtc_offer':
      case 'webrtc_answer':
      case 'webrtc_ice_candidate':
      case 'webrtc_transport_state':
        onWebRtcSignal?.call(data);
        break;
      case 'error':
        final msg = data['message']?.toString() ?? 'Unknown server error';
        _status = ConnectionStatus.failed;
        _errorMessage = msg;
        notifyListeners();
        if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
          _connectCompleter!.completeError(msg);
        }
        break;
    }
  }
}
