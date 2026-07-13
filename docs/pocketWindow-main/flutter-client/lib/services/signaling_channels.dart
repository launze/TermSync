import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

const List<int> _videoFrameBinaryMagic = <int>[0x50, 0x57, 0x56, 0x46];

class SignalingChannels {
  SignalingChannels({
    required this.serverUrl,
    required this.roomId,
    required this.clientId,
    required this.clientName,
    required this.deviceId,
    required this.onMessage,
    required this.onError,
    required this.onDone,
    this.totpCode,
    this.totpNonce,
  });

  final String serverUrl;
  final String roomId;
  final String clientId;
  final String clientName;
  final String deviceId;
  final void Function(Map<String, dynamic> data) onMessage;
  final void Function(Object error) onError;
  final void Function(String channel) onDone;

  /// Optional TOTP credentials for public-direct mode. When both are
  /// non-empty the join_room frame carries `totp_code` + `totp_nonce`
  /// fields that the desktop's lan-direct server validates before
  /// accepting the connection. Set to null/empty for the legacy LAN
  /// or signaling-relay flow.
  final String? totpCode;
  final String? totpNonce;

  WebSocketChannel? _control;
  WebSocketChannel? _media;
  final List<WebSocketChannel> _streamChannels = <WebSocketChannel>[];
  int? _lastControlMessageTsMs;
  int? _lastMediaMessageTsMs;
  int _controlBurstCount = 0;
  int _mediaBurstCount = 0;
  bool get controlConnected => _control != null;
  bool get mediaConnected => _media != null;

  Future<void> connect() async {
    _control = await _connectChannel('control');
    try {
      _media = await _connectChannel('media');
    } catch (_) {
      _media = null;
    }
    for (var idx = 0; idx < 1; idx += 1) {
      final channelName = 'stream-${idx + 1}';
      try {
        final ch = await _connectChannel(channelName);
        _streamChannels.add(ch);
      } catch (_) {
        // stream channel connection failure is non-fatal
      }
    }
  }

  void disconnect() {
    for (final ch in _streamChannels) {
      ch.sink.close();
    }
    _streamChannels.clear();
    _media?.sink.close();
    _control?.sink.close();
    _media = null;
    _control = null;
  }

  void sendControl(Map<String, dynamic> payload) {
    _send(_control, payload);
  }

  void sendMedia(Map<String, dynamic> payload) {
    _send(_media ?? _control, payload);
  }

  Future<bool> reconnectMedia() async {
    try {
      await _media?.sink.close();
    } catch (_) {
      // Best effort: the control channel remains active.
    }
    _media = null;
    _lastMediaMessageTsMs = null;
    _mediaBurstCount = 0;
    try {
      _media = await _connectChannel('media');
      return true;
    } catch (_) {
      _media = null;
      return false;
    }
  }

  Future<WebSocketChannel> _connectChannel(String channelName) async {
    final uri = Uri.parse(_normalizeWsUrl(serverUrl));
    final channel = WebSocketChannel.connect(uri);
    final joined = Completer<void>();
    late final StreamSubscription<dynamic> subscription;

    subscription = channel.stream.listen(
      (message) {
        try {
          final messageStartUs = DateTime.now().microsecondsSinceEpoch;
          final messageTsMs = DateTime.now().millisecondsSinceEpoch;
          final lastTsMs = channelName == 'media'
              ? _lastMediaMessageTsMs
              : _lastControlMessageTsMs;
          final gapMs = lastTsMs == null ? null : messageTsMs - lastTsMs;
          final burstCount = _recordIncomingMessage(channelName, messageTsMs);
          final data = _parseIncomingMessage(message);
          final messageEndUs = DateTime.now().microsecondsSinceEpoch;
          data['_client_ws_channel'] = channelName;
          data['_client_ws_message_ts_ms'] = messageTsMs;
          data['_client_ws_message_gap_ms'] = gapMs;
          data['_client_ws_burst_count'] = burstCount;
          data['_client_ws_parse_ms'] = (messageEndUs - messageStartUs) / 1000.0;
          if (data['type'] == 'room_joined' && !joined.isCompleted) {
            final responseChannel = data['channel']?.toString() ?? '';
            if (channelName == 'control' &&
                (responseChannel.isEmpty || responseChannel == 'control')) {
              joined.complete();
            } else if (responseChannel == channelName) {
              joined.complete();
            }
          }
          onMessage(data);
        } catch (error) {
          if (!joined.isCompleted) {
            joined.completeError(error);
          }
          onError(error);
        }
      },
      onError: (error) {
        if (!joined.isCompleted) {
          joined.completeError(error);
        }
        onError(error);
      },
      onDone: () {
        if (channelName == 'media' && identical(_media, channel)) {
          _media = null;
        } else if (channelName == 'control' && identical(_control, channel)) {
          _control = null;
        }
        onDone(channelName);
      },
      cancelOnError: false,
    );

    channel.sink.add(json.encode({
      'type': 'join_room',
      'room_id': roomId,
      'role': 'client',
      'channel': channelName,
      'client_id': clientId,
      'client_name': clientName,
      'device_id': deviceId,
      if (totpCode != null && totpCode!.isNotEmpty) 'totp_code': totpCode,
      if (totpNonce != null && totpNonce!.isNotEmpty) 'totp_nonce': totpNonce,
    }));

    if (channelName == 'media' && !joined.isCompleted) {
      joined.complete();
    }

    try {
      await joined.future.timeout(const Duration(seconds: 5));
      return channel;
    } catch (error) {
      await subscription.cancel();
      await channel.sink.close();
      rethrow;
    }
  }

  void _send(WebSocketChannel? channel, Map<String, dynamic> payload) {
    if (channel == null) return;
    channel.sink.add(json.encode(payload));
  }

  int _recordIncomingMessage(String channelName, int messageTsMs) {
    if (channelName == 'media') {
      final lastTsMs = _lastMediaMessageTsMs;
      _lastMediaMessageTsMs = messageTsMs;
      if (lastTsMs != null && messageTsMs - lastTsMs <= 5) {
        _mediaBurstCount += 1;
      } else {
        _mediaBurstCount = 1;
      }
      return _mediaBurstCount;
    }
    final lastTsMs = _lastControlMessageTsMs;
    _lastControlMessageTsMs = messageTsMs;
    if (lastTsMs != null && messageTsMs - lastTsMs <= 5) {
      _controlBurstCount += 1;
    } else {
      _controlBurstCount = 1;
    }
    return _controlBurstCount;
  }

  Map<String, dynamic> _parseIncomingMessage(dynamic message) {
    if (message is String) {
      return json.decode(message) as Map<String, dynamic>;
    }
    final bytes = message is Uint8List
        ? message
        : Uint8List.fromList((message as List<int>).toList());
    if (_isVideoFrameBinary(bytes)) {
      return _parseVideoFrameBinary(bytes);
    }
    return json.decode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  bool _isVideoFrameBinary(Uint8List bytes) {
    if (bytes.length < _videoFrameBinaryMagic.length) return false;
    for (var index = 0; index < _videoFrameBinaryMagic.length; index += 1) {
      if (bytes[index] != _videoFrameBinaryMagic[index]) return false;
    }
    return true;
  }

  Map<String, dynamic> _parseVideoFrameBinary(Uint8List bytes) {
    const headerLength = 30;
    if (bytes.length < headerLength) {
      throw const FormatException('Invalid video frame binary header');
    }
    final view = ByteData.sublistView(bytes);
    final version = view.getUint8(4);
    if (version != 1) {
      throw FormatException('Unsupported video frame binary version: $version');
    }
    final codecId = view.getUint8(5);
    final seq = view.getUint32(8, Endian.big);
    final sentAtMs = view.getUint64(12, Endian.big);
    final width = view.getUint32(20, Endian.big);
    final height = view.getUint32(24, Endian.big);
    const profileLengthOffset = 28;
    if (bytes.length < profileLengthOffset + 2) {
      throw const FormatException('Invalid video frame profile length');
    }
    final profileLength = view.getUint16(profileLengthOffset, Endian.big);
    const profileStart = profileLengthOffset + 2;
    final payloadStart = profileStart + profileLength;
    if (bytes.length < payloadStart) {
      throw const FormatException('Invalid video frame profile payload');
    }
    final profile = profileLength > 0
        ? utf8.decode(bytes.sublist(profileStart, payloadStart))
        : '';
    return {
      'type': 'video_stream_frame',
      'seq': seq,
      'sent_at': sentAtMs,
      'codec': codecId == 2 ? 'h265' : 'h264',
      'format': 'annexb',
      'width': width,
      'height': height,
      'profile': profile,
      'data': Uint8List.sublistView(bytes, payloadStart),
      'binary': true,
    };
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
}
