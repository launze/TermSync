import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:pocketwindow/services/signaling_service.dart';

enum DirectTransportState {
  idle,
  connecting,
  connected,
  failed,
  unsupported,
}

class DirectTransportService with ChangeNotifier {
  DirectTransportService(this._signaling);

  final SignalingService _signaling;
  RTCPeerConnection? _peer;
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _rendererInitialized = false;
  bool _hasRemoteVideo = false;
  DirectTransportState _state = DirectTransportState.idle;
  String _message = 'server relay';
  int _probeSeq = 0;
  String? _probeId;
  bool _confirmed = false;
  bool _sentRelayCandidate = false;
  Timer? _statsTimer;
  int? _lastBytesReceived;
  int? _lastFramesDecoded;
  double? _lastStatsTimestamp;
  double _videoFps = 0;
  double _bytesPerSecond = 0;
  int _bytesLastMinute = 0;
  int? _videoWidth;
  int? _videoHeight;
  int _recoverSeq = 0;
  DateTime? _connectedAt;
  DateTime? _lastGoodStatsAt;
  DateTime? _lastRecoveryAt;
  final ListQueue<_DirectByteStat> _byteStats = ListQueue<_DirectByteStat>();

  DirectTransportState get state => _state;
  String get message => _message;
  bool get connected => _state == DirectTransportState.connected;
  RTCVideoRenderer get remoteRenderer => _remoteRenderer;
  bool get hasRemoteVideo =>
      _hasRemoteVideo && _confirmed && _state == DirectTransportState.connected;
  double get videoFps => hasRemoteVideo ? _videoFps : 0;
  double get bytesPerSecondEstimate => hasRemoteVideo ? _bytesPerSecond : 0;
  double get bytesPerMinuteEstimate => hasRemoteVideo ? _bytesLastMinute.toDouble() : 0;
  int get bytesLastMinute => hasRemoteVideo ? _bytesLastMinute : 0;
  int? get videoWidth => _videoWidth;
  int? get videoHeight => _videoHeight;
  bool get isRecovering => _state == DirectTransportState.connecting &&
      _message.toLowerCase().contains('recover');

  Future<void> startProbe() async {
    if (_state == DirectTransportState.connecting ||
        _state == DirectTransportState.connected) {
      return;
    }
    await _startProbeAttempt();
  }

  Future<void> _startProbeAttempt() async {
    if (_peer != null) {
      await _closePeer(resetState: false);
    }
    final probeId =
        '${DateTime.now().millisecondsSinceEpoch}-${++_probeSeq}';
    _probeId = probeId;
    _confirmed = false;
    _hasRemoteVideo = false;
    _sentRelayCandidate = false;
    _setState(DirectTransportState.connecting, 'WebRTC: loading TURN');

    try {
      await _ensureRendererInitialized();
      final iceServers = await _loadIceServers();
      final peer = await createPeerConnection({
        'iceServers': iceServers,
        'iceTransportPolicy': 'relay',
        'bundlePolicy': 'max-bundle',
      });
      _peer = peer;

      peer.onIceCandidate = (candidate) {
        if (_probeId != probeId || _peer != peer) return;
        if (candidate.candidate == null || candidate.candidate!.isEmpty) {
          return;
        }
        if (!candidate.candidate!.contains(' typ relay ')) {
          return;
        }
        if (_sentRelayCandidate) {
          return;
        }
        _sentRelayCandidate = true;
        _setState(DirectTransportState.connecting, 'WebRTC: relay candidate');
        _signaling.sendWebRtcSignal('webrtc_ice_candidate', {
          'probe_id': probeId,
          'candidate': candidate.toMap(),
        });
      };
      peer.onConnectionState = (state) {
        if (_probeId != probeId || _peer != peer) return;
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _confirmed = true;
          _connectedAt = DateTime.now();
          _lastGoodStatsAt = null;
          _startStatsTimer();
          _setState(DirectTransportState.connected, 'direct connected');
        } else if (state ==
                RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _hasRemoteVideo = false;
          _clearRemoteRendererStream();
          _stopStatsTimer(resetStats: true);
          if (!_confirmed) {
            _setState(DirectTransportState.failed, 'direct unavailable');
            _scheduleRecovery('connection unavailable');
            Future.microtask(() async {
              if (_probeId == probeId && _peer == peer) {
                await _closePeer(resetState: false);
              }
            });
          } else {
            notifyListeners();
          }
        }
      };
      peer.onTrack = (event) {
        if (_probeId != probeId || _peer != peer) return;
        if (event.track.kind != 'video') return;
        if (event.streams.isNotEmpty) {
          _remoteRenderer.srcObject = event.streams.first;
        }
        _hasRemoteVideo = true;
        _setState(DirectTransportState.connecting, 'WebRTC: video track');
        notifyListeners();
      };
      await peer.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );

      final offer = await peer.createOffer({
        'offerToReceiveAudio': 0,
        'offerToReceiveVideo': 1,
      });
      _setState(DirectTransportState.connecting, 'WebRTC: gathering ICE');
      await peer.setLocalDescription(offer);
      await _waitForIceGathering(peer);
      final localDescription = await peer.getLocalDescription();
      _setState(DirectTransportState.connecting, 'WebRTC: offer sent');
      _signaling.sendWebRtcSignal('webrtc_offer', {
        'probe_id': probeId,
        'ice_servers': iceServers,
        'sdp': _relayOnlySingleCandidateSdp(
          _preferH264Sdp(localDescription?.sdp ?? offer.sdp ?? ''),
        ),
        'sdp_type': localDescription?.type ?? offer.type,
      });
    } catch (error) {
      _setState(DirectTransportState.failed, 'direct setup failed: $error');
      await _closePeer(resetState: false);
      _scheduleRecovery('setup failed');
    }
  }

  Future<void> handleSignal(Map<String, dynamic> data) async {
    final type = data['type']?.toString() ?? '';
    final probeId = data['probe_id']?.toString();
    if (probeId != null && probeId.isNotEmpty && probeId != _probeId) {
      return;
    }
    try {
      switch (type) {
        case 'webrtc_answer':
          final peer = _peer;
          final sdp = data['sdp']?.toString() ?? '';
          final sdpType = data['sdp_type']?.toString() ?? 'answer';
          if (peer != null && sdp.isNotEmpty) {
            _setState(DirectTransportState.connecting, 'WebRTC: answer received');
            await peer.setRemoteDescription(RTCSessionDescription(sdp, sdpType));
          }
          break;
        case 'webrtc_ice_candidate':
          final peer = _peer;
          final candidate = data['candidate'];
          if (peer != null && candidate is Map) {
            await peer.addCandidate(
              RTCIceCandidate(
                candidate['candidate']?.toString(),
                candidate['sdpMid']?.toString(),
                (candidate['sdpMLineIndex'] as num?)?.toInt(),
              ),
            );
          }
          break;
        case 'webrtc_transport_state':
          final state = data['state']?.toString() ?? '';
          if (state == 'unsupported') {
            _stopStatsTimer(resetStats: true);
            _setState(DirectTransportState.unsupported, 'direct unsupported');
          } else if (state == 'connected' || state == 'completed') {
            _confirmed = true;
            _startStatsTimer();
            _setState(DirectTransportState.connected, 'direct connected');
          } else if (state == 'failed') {
            _hasRemoteVideo = false;
            _clearRemoteRendererStream();
            _stopStatsTimer(resetStats: true);
            if (!_confirmed) {
              _setState(DirectTransportState.failed, 'direct failed');
              _scheduleRecovery('transport failed');
            } else {
              notifyListeners();
            }
          }
          break;
      }
    } catch (error) {
      _setState(DirectTransportState.failed, 'direct signal failed: $error');
    }
  }

  Future<void> stop() async {
    await _closePeer(resetState: true);
  }

  Future<void> _closePeer({required bool resetState}) async {
    final peer = _peer;
    _peer = null;
    _probeId = null;
    _confirmed = false;
    _hasRemoteVideo = false;
    _clearRemoteRendererStream();
    _stopStatsTimer(resetStats: true);
    await peer?.close();
    if (resetState && _state != DirectTransportState.unsupported) {
      _setState(DirectTransportState.idle, 'server relay');
    }
  }

  void _scheduleRecovery(String reason) {
    if (_state == DirectTransportState.unsupported) return;
    final now = DateTime.now();
    final lastRecovery = _lastRecoveryAt;
    if (lastRecovery != null && now.difference(lastRecovery).inSeconds < 5) {
      return;
    }
    _lastRecoveryAt = now;
    final seq = ++_recoverSeq;
    Future<void>.delayed(const Duration(seconds: 2), () async {
      if (seq != _recoverSeq || _state == DirectTransportState.unsupported) {
        return;
      }
      if (_state == DirectTransportState.connected ||
          _state == DirectTransportState.connecting) {
        return;
      }
      await restartProbe(reason: reason);
    });
  }

  Future<List<Map<String, dynamic>>> _loadIceServers() async {
    // The signaling server is the source of truth for ICE/TURN configuration
    // (see GET /api/ice-servers). When that fetch fails or returns nothing,
    // we return an empty list so callers can degrade gracefully instead of
    // dialing a baked-in TURN URL that only works for one developer's setup.
    try {
      final servers = await _signaling.fetchIceServers();
      return servers
          .map(_turnOnlyIceServer)
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  Map<String, dynamic>? _turnOnlyIceServer(Map<String, dynamic> server) {
    final urls = server['urls'];
    final rawUrls = urls is String
        ? <String>[urls]
        : urls is List
            ? urls.map((item) => item.toString()).toList(growable: false)
            : const <String>[];
    final turnUrls = rawUrls
        .map((url) => url.trim())
        .where((url) =>
            url.toLowerCase().startsWith('turn:') &&
            url.toLowerCase().contains('transport=tcp'))
        .toList(growable: false);
    if (turnUrls.isEmpty) return null;
    return {
      ...server,
      'urls': turnUrls.length == 1 ? turnUrls.first : turnUrls,
    };
  }

  Future<void> _waitForIceGathering(RTCPeerConnection peer) async {
    if (peer.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return;
    }
    final completer = Completer<void>();
    Timer? timeout;
    peer.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !completer.isCompleted) {
        completer.complete();
      }
    };
    timeout = Timer(const Duration(seconds: 5), () {
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;
    timeout.cancel();
  }

  void _setState(DirectTransportState state, String message) {
    _state = state;
    _message = message;
    notifyListeners();
  }

  void _startStatsTimer() {
    if (_statsTimer != null) return;
    _statsTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_sampleVideoStats()),
    );
    unawaited(_sampleVideoStats());
  }

  void _stopStatsTimer({required bool resetStats}) {
    _statsTimer?.cancel();
    _statsTimer = null;
    _lastBytesReceived = null;
    _lastFramesDecoded = null;
    _lastStatsTimestamp = null;
    if (resetStats) {
      _videoFps = 0;
      _bytesPerSecond = 0;
      _bytesLastMinute = 0;
      _videoWidth = null;
      _videoHeight = null;
      _byteStats.clear();
    }
  }

  Future<void> _sampleVideoStats() async {
    final peer = _peer;
    final stream = _remoteRenderer.srcObject;
    if (peer == null || stream == null || !hasRemoteVideo) return;
    final videoTracks = stream.getVideoTracks();
    if (videoTracks.isEmpty) return;
    try {
      var reports = await peer.getStats(videoTracks.first);
      StatsReport? inbound = _findInboundVideoReport(reports);
      if (inbound == null) {
        reports = await peer.getStats();
        inbound = _findInboundVideoReport(reports);
      }
      if (inbound == null) return;
      final values = inbound.values;
      final bytesReceived = _readInt(values['bytesReceived']);
      final framesDecoded =
          _readInt(values['framesDecoded']) ?? _readInt(values['framesReceived']);
      final framesPerSecond = _readDouble(values['framesPerSecond']);
      final frameWidth = _readInt(values['frameWidth']);
      final frameHeight = _readInt(values['frameHeight']);
      final timestamp = inbound.timestamp;

      if (frameWidth != null && frameWidth > 0) _videoWidth = frameWidth;
      if (frameHeight != null && frameHeight > 0) _videoHeight = frameHeight;

      if (bytesReceived != null) {
        final previousBytes = _lastBytesReceived;
        final previousTimestamp = _lastStatsTimestamp;
        if (previousBytes != null && previousTimestamp != null) {
          final elapsedSeconds = (timestamp - previousTimestamp) / 1000.0;
          final deltaBytes = bytesReceived - previousBytes;
          if (elapsedSeconds > 0 && deltaBytes >= 0) {
            _bytesPerSecond = deltaBytes / elapsedSeconds;
            _recordByteDelta(deltaBytes);
            if (deltaBytes > 0) {
              _lastGoodStatsAt = DateTime.now();
            }
          }
        }
        _lastBytesReceived = bytesReceived;
      }

      if (framesPerSecond != null && framesPerSecond >= 0) {
        _videoFps = framesPerSecond;
      } else if (framesDecoded != null &&
          _lastFramesDecoded != null &&
          _lastStatsTimestamp != null) {
        final elapsedSeconds = (timestamp - _lastStatsTimestamp!) / 1000.0;
        final deltaFrames = framesDecoded - _lastFramesDecoded!;
        if (elapsedSeconds > 0 && deltaFrames >= 0) {
          _videoFps = deltaFrames / elapsedSeconds;
        }
      }
      if (framesDecoded != null) _lastFramesDecoded = framesDecoded;
      _lastStatsTimestamp = timestamp;
      _maybeRecoverStalledVideo();
      notifyListeners();
    } catch (_) {
      // Stats are best-effort; the video path should not fail because of them.
    }
  }

  StatsReport? _findInboundVideoReport(List<StatsReport> reports) {
    StatsReport? fallback;
    for (final report in reports) {
      final values = report.values;
      final kind = values['kind']?.toString() ?? values['mediaType']?.toString();
      if (report.type == 'inbound-rtp' && kind == 'video') {
        return report;
      }
      if (report.type == 'inbound-rtp' &&
          (values.containsKey('bytesReceived') ||
              values.containsKey('framesDecoded') ||
              values.containsKey('framesReceived') ||
              values.containsKey('framesPerSecond'))) {
        fallback ??= report;
      }
    }
    return fallback;
  }

  int? _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  double? _readDouble(Object? value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  void _recordByteDelta(int bytes) {
    final now = DateTime.now();
    _byteStats.add(_DirectByteStat(timestamp: now, bytes: bytes));
    final cutoff = now.subtract(const Duration(minutes: 1));
    while (_byteStats.isNotEmpty && _byteStats.first.timestamp.isBefore(cutoff)) {
      _byteStats.removeFirst();
    }
    _bytesLastMinute = _byteStats.fold(0, (sum, item) => sum + item.bytes);
  }

  void _maybeRecoverStalledVideo() {
    if (!hasRemoteVideo) return;
    final now = DateTime.now();
    final connectedAt = _connectedAt;
    if (connectedAt == null || now.difference(connectedAt).inSeconds < 8) {
      return;
    }
    final lastGood = _lastGoodStatsAt;
    final staleSeconds = lastGood == null
        ? now.difference(connectedAt).inSeconds
        : now.difference(lastGood).inSeconds;
    if (staleSeconds < 6 && (_videoFps > 0 || _bytesPerSecond > 0)) {
      return;
    }
    final lastRecovery = _lastRecoveryAt;
    if (lastRecovery != null && now.difference(lastRecovery).inSeconds < 10) {
      return;
    }
    _lastRecoveryAt = now;
    unawaited(restartProbe(reason: 'stalled video stats'));
  }

  Future<void> restartProbe({String reason = 'manual'}) async {
    final seq = ++_recoverSeq;
    _setState(DirectTransportState.connecting, 'WebRTC: recovering');
    await _closePeer(resetState: false);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (seq != _recoverSeq) return;
    await _startProbeAttempt();
  }

  Future<void> _ensureRendererInitialized() async {
    if (_rendererInitialized) return;
    await _remoteRenderer.initialize();
    _rendererInitialized = true;
  }

  void _clearRemoteRendererStream() {
    if (!_rendererInitialized) return;
    try {
      _remoteRenderer.srcObject = null;
    } catch (_) {
      // Renderer can be uninitialized after Android backgrounds the app.
    }
  }

  Future<void> disposeRenderer() async {
    await stop();
    if (_rendererInitialized) {
      _rendererInitialized = false;
      await _remoteRenderer.dispose();
    }
  }

  String _preferH264Sdp(String sdp) {
    if (sdp.isEmpty || !sdp.contains('H264/90000')) {
      return sdp;
    }
    final lines = sdp.split('\r\n');
    final h264Payloads = <String>[];
    final rtpmapPattern = RegExp(r'^a=rtpmap:(\d+) H264/90000', caseSensitive: false);
    for (final line in lines) {
      final match = rtpmapPattern.firstMatch(line);
      if (match != null) {
        h264Payloads.add(match.group(1)!);
      }
    }
    if (h264Payloads.isEmpty) return sdp;
    return lines.map((line) {
      if (!line.startsWith('m=video ')) return line;
      final parts = line.split(' ');
      if (parts.length <= 3) return line;
      final header = parts.take(3).toList();
      final payloads = parts.skip(3).toList();
      final preferred = <String>[
        ...h264Payloads.where(payloads.contains),
        ...payloads.where((payload) => !h264Payloads.contains(payload)),
      ];
      return [...header, ...preferred].join(' ');
    }).join('\r\n');
  }

  String _relayOnlySingleCandidateSdp(String sdp) {
    if (sdp.isEmpty) return sdp;
    final lines = sdp.split('\r\n');
    var keptRelay = false;
    final filtered = <String>[];
    for (final line in lines) {
      if (line.startsWith('a=candidate:')) {
        if (!keptRelay && line.contains(' typ relay ')) {
          keptRelay = true;
          filtered.add(line);
        }
        continue;
      }
      filtered.add(line);
    }
    return filtered.join('\r\n');
  }
}

class _DirectByteStat {
  final DateTime timestamp;
  final int bytes;

  const _DirectByteStat({
    required this.timestamp,
    required this.bytes,
  });
}
