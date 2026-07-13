import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pocketwindow/services/control_diagnostic_filter.dart';
import 'package:pocketwindow/services/direct_transport_service.dart';
import 'package:pocketwindow/services/h264_video_stream_service.dart';
import 'package:pocketwindow/services/scroll_diagnostic_logger.dart';
import 'package:pocketwindow/services/signaling_service.dart';

enum StreamProfile {
  hybrid,
  smoothHd,
  lan,
}

class _FrameStat {
  final DateTime timestamp;
  final int bytes;

  const _FrameStat({
    required this.timestamp,
    required this.bytes,
  });
}

class _EventStat {
  final DateTime timestamp;

  const _EventStat({
    required this.timestamp,
  });
}

class ScreenshotCaptureResult {
  final Uint8List imageBytes;
  final String fileName;
  final int imageWidth;
  final int imageHeight;

  const ScreenshotCaptureResult({
    required this.imageBytes,
    required this.fileName,
    required this.imageWidth,
    required this.imageHeight,
  });
}

class ControlService with ChangeNotifier {
  bool _connected = false;
  String? _windowTitle;
  int? _selectedHwnd;
  Uint8List? _currentFrame;
  DateTime? _lastImageFrameAt;
  int? _remoteWidth;
  int? _remoteHeight;
  int? _videoStreamWidth;
  int? _videoStreamHeight;
  double? _cursorX;
  double? _cursorY;
  bool _cursorVisible = false;
  Uint8List? _cursorImageBytes;
  int? _cursorImageWidth;
  int? _cursorImageHeight;
  int _cursorHotspotX = 0;
  int _cursorHotspotY = 0;
  String? _cursorImageSignature;
  int _cursorInvisibleStreak = 0;
  String? _roomId;
  String _statusMessage = '未连接';
  int _lastFrameBytes = 0;
  StreamProfile _streamProfile = StreamProfile.hybrid;
  double _qualityScale = 1.0;
  double _resolutionScale = 1.0;
  double _dynamicFpsLimit = 20.0;
  double _staticFpsLimit = 2.0;
  double _scrollVideoScale = 0.62;
  int _scrollVideoBitrateKbps = 1800;
  double _scrollVideoFps = 15.0;
  int _scrollVideoCrf = 35;
  int _scrollVideoVbvMultiplier = 3;
  String _scrollVideoPixelFormat = 'yuv420p';
  String _scrollVideoPreset = 'veryfast';
  bool _scrollModeActive = false;
  int _lastImageFrameSeq = 0;
  final ListQueue<_FrameStat> _frameStats = ListQueue<_FrameStat>();
  final ListQueue<_EventStat> _cursorStats = ListQueue<_EventStat>();
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};

  SignalingService? _signalingService;
  DirectTransportService? _directTransport;
  final H264VideoStreamService _h264VideoStream = H264VideoStreamService();
  bool _lastReportedH264Active = false;
  String _lastReportedVideoCodec = '';
  int _lastReportedVideoStartGeneration = -1;
  final ControlDiagnosticFilter _diagnosticFilter = ControlDiagnosticFilter();
  int _lastMediaReconnectTsMs = 0;
  // Throttle for image_frame_received diagnostics. Image frames arrive 5-60
  // times per second; logging each one would flood the diagnostic stream.
  // We log the first frame seen after every connection_diag_id change, then
  // at most one frame every 5 seconds, plus the very first ack failure path.
  String _imageFrameDiagLastConnectionDiagId = '';
  int _imageFrameDiagLastTsMs = 0;
  int _lastVideoRestartRequestTsMs = 0;
  final Map<int, Map<String, dynamic>> _videoTransportTraces = {};
  final Map<int, Map<String, dynamic>> _videoTransportSendResults = {};
  int _videoHandshakeProgress = 0;
  String _videoHandshakeStage = '';
  String _videoHandshakeCodec = 'h264';
  int _lastVideoFrameLogTsMs = 0;
  int _lastVideoFrameLogSeq = 0;
  Function(Map<String, dynamic>)? _originalImageFrameCallback;
  Function(Map<String, dynamic>)? _originalVideoStreamCallback;
  Function(Map<String, dynamic>)? _originalCursorPositionCallback;
  Function(Map<String, dynamic>)? _originalSetWindowCallback;
  Function(Map<String, dynamic>)? _originalControlResponseCallback;
  Function(Map<String, dynamic>)? _originalWebRtcSignalCallback;
  bool _h264VideoListenerAttached = false;
  int _lastVideoStreamStartAtMs = 0;
  Timer? _videoStreamStartTimer;
  Timer? _handshakeTickTimer;
  int _videoStreamStartRetries = 0;
  static const int _maxVideoStreamStartRetries = 3;
  int _handshakeConnectedAtMs = 0;
  final Set<String> _handshakeReceivedTypes = {};
  String _handshakeStageDetail = '';
  int _handshakeProgressMs = 0;
  String _connectionDiagId = '';

  bool get connected => _connected;
  String? get windowTitle => _windowTitle;
  int? get selectedHwnd => _selectedHwnd;
  Uint8List? get currentFrame => _currentFrame;
  int? get remoteWidth => _remoteWidth;
  int? get remoteHeight => _remoteHeight;
  int? get videoFrameWidth {
    final direct = _directTransport;
    if (direct?.hasRemoteVideo == true && direct!.videoWidth != null) {
      return direct.videoWidth;
    }
    if (_h264VideoStream.available && _videoStreamWidth != null) {
      return _videoStreamWidth;
    }
    return _remoteWidth;
  }

  int? get videoFrameHeight {
    final direct = _directTransport;
    if (direct?.hasRemoteVideo == true && direct!.videoHeight != null) {
      return direct.videoHeight;
    }
    if (_h264VideoStream.available && _videoStreamHeight != null) {
      return _videoStreamHeight;
    }
    return _remoteHeight;
  }
  double? get cursorX => _cursorX;
  double? get cursorY => _cursorY;
  bool get cursorVisible => _cursorVisible;
  Uint8List? get cursorImageBytes => _cursorImageBytes;
  int? get cursorImageWidth => _cursorImageWidth;
  int? get cursorImageHeight => _cursorImageHeight;
  int get cursorHotspotX => _cursorHotspotX;
  int get cursorHotspotY => _cursorHotspotY;
  String? get roomId => _roomId;
  String get statusMessage => _statusMessage;
  int get lastFrameBytes => _lastFrameBytes;
  StreamProfile get streamProfile => _streamProfile;
  double get qualityScale => _qualityScale;
  double get resolutionScale => _resolutionScale;
  double get dynamicFpsLimit => _dynamicFpsLimit;
  double get staticFpsLimit => _staticFpsLimit;
  double get scrollVideoScale => _scrollVideoScale;
  int get scrollVideoBitrateKbps => _scrollVideoBitrateKbps;
  double get scrollVideoFps => _scrollVideoFps;
  int get scrollVideoCrf => _scrollVideoCrf;
  bool get scrollModeActive => _scrollModeActive;
  DirectTransportService? get directTransport => _directTransport;
  H264VideoStreamService get h264VideoStream => _h264VideoStream;
  String get connectionDiagId => _connectionDiagId;
  bool get usingWebRtcVideo => false;
  bool get usingH264Video => _h264VideoStream.available;
  String get handshakeStageDetail => _handshakeStageDetail;
  String get handshakeProgressTime {
    if (_handshakeConnectedAtMs <= 0) return '';
    final sec = (_handshakeProgressMs ~/ 1000);
    final min = sec ~/ 60;
    final s = sec % 60;
    return '${min.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  Set<String> get handshakeReceivedTypes => _handshakeReceivedTypes;
  int get videoHandshakeProgress => _h264VideoStream.available
      ? 100
      : (_videoHandshakeProgress <= 0 && _h264VideoStream.negotiating
          ? 60
          : _videoHandshakeProgress.clamp(0, 100));
  String get videoHandshakeStage {
    if (_h264VideoStream.available) {
      final codecLabel = _h264VideoStream.codec == 'h265' ? 'H265' : 'H264';
      return '$codecLabel 视频已就绪';
    }
    if (_videoHandshakeStage.isNotEmpty) return _videoHandshakeStage;
    if (_h264VideoStream.negotiating) {
      final codecLabel = _h264VideoStream.codec == 'h265' ? 'H265' : 'H264';
      return '正在启动 $codecLabel 解码器';
    }
    return '正在等待远端画面';
  }
  String get videoHandshakeCodec => _h264VideoStream.codec.isNotEmpty
      ? _h264VideoStream.codec
      : _videoHandshakeCodec;
  DateTime? get lastFrameAt =>
      _frameStats.isEmpty ? null : _frameStats.last.timestamp;
  DateTime? get lastVisualFrameAt =>
      _h264VideoStream.lastRenderedFrameAt ?? lastFrameAt;

  String get videoTransportLabel {
    final hasImageFallback = _currentFrame != null;
    if (_h264VideoStream.negotiating) {
      final codecLabel = _h264VideoStream.codec == 'h265' ? 'H265' : 'H264';
      return hasImageFallback
          ? '正在协商 $codecLabel / 图片兜底'
          : '正在协商 $codecLabel';
    }
    if (_h264VideoStream.available && _h264FrameFresh) {
      final prefix = _signalingService?.isLanDirectConnection == true
          ? 'LAN Direct'
          : 'WebSocket';
      return _h264VideoStream.codec == 'h265'
          ? '$prefix + H265'
          : '$prefix + H264';
    }
    // H264 negotiated earlier but the stream has gone stale (agent fell back to
    // image frames on a weak link). Reflect what is actually on screen.
    if (_h264VideoStream.available && !_h264FrameFresh && _imageFrameFresh) {
      return '图片模式（视频暂不可用）';
    }
    if (_h264VideoStream.failed && hasImageFallback) {
      return '旧版图片帧（视频不可用）';
    }
    return '旧版图片帧';
  }

  bool get _h264FrameFresh {
    final at = _h264VideoStream.lastRenderedFrameAt;
    if (at == null) return false;
    return DateTime.now().difference(at).inMilliseconds <= 2500;
  }

  bool get _imageFrameFresh {
    final at = _lastImageFrameAt;
    if (at == null) return false;
    return DateTime.now().difference(at).inMilliseconds <= 1500;
  }

  int get bytesLastMinute {
    final direct = _directTransport;
    if (direct?.hasRemoteVideo == true) {
      return direct!.bytesLastMinute;
    }
    _pruneStats();
    return _frameStats.fold(0, (sum, item) => sum + item.bytes);
  }

  double get bytesPerSecondEstimate {
    final direct = _directTransport;
    if (direct?.hasRemoteVideo == true) {
      return direct!.bytesPerSecondEstimate;
    }
    _pruneStats();
    if (_frameStats.isEmpty) return 0;
    final cutoff = DateTime.now().subtract(const Duration(seconds: 1));
    return _frameStats
        .where((item) => item.timestamp.isAfter(cutoff))
        .fold<int>(0, (sum, item) => sum + item.bytes)
        .toDouble();
  }

  double get fps {
    final direct = _directTransport;
    if (direct?.hasRemoteVideo == true) {
      return direct!.videoFps;
    }
    if (_h264VideoStream.available) {
      return _h264VideoStream.renderedFps;
    }
    _pruneStats();
    final cutoff = DateTime.now().subtract(const Duration(seconds: 1));
    return _frameStats
        .where((item) => item.timestamp.isAfter(cutoff))
        .length
        .toDouble();
  }

  double get cursorFps {
    _pruneStats();
    final cutoff = DateTime.now().subtract(const Duration(seconds: 1));
    return _cursorStats
        .where((item) => item.timestamp.isAfter(cutoff))
        .length
        .toDouble();
  }

  double get bytesPerMinuteEstimate {
    final direct = _directTransport;
    if (direct?.hasRemoteVideo == true) {
      return direct!.bytesPerMinuteEstimate;
    }
    _pruneStats();
    if (_frameStats.isEmpty) return 0;
    final first = _frameStats.first.timestamp;
    final last = _frameStats.last.timestamp;
    final elapsedMs = last.difference(first).inMilliseconds;
    if (elapsedMs <= 0) return _frameStats.last.bytes * 60.0;
    return bytesLastMinute * 60000 / elapsedMs;
  }

  String get streamProfileLabel {
    switch (_streamProfile) {
      case StreamProfile.hybrid:
        return '混合模式';
      case StreamProfile.smoothHd:
        return '高清流畅模式';
      case StreamProfile.lan:
        return '局域网模式';
    }
  }

  void setSignalingService(SignalingService service) {
    if (identical(_signalingService, service)) {
      return;
    }
    _detachSignalingService();
    _signalingService = service;
    _originalImageFrameCallback = service.onImageFrame;
    _originalVideoStreamCallback = service.onVideoStream;
    _originalCursorPositionCallback = service.onCursorPosition;
    _originalSetWindowCallback = service.onSetWindowResponse;
    _originalControlResponseCallback = service.onControlResponse;
    _originalWebRtcSignalCallback = service.onWebRtcSignal;
    service.addListener(_onSignalingStateChanged);
    _directTransport = DirectTransportService(service);
    _directTransport?.addListener(notifyListeners);
    if (!_h264VideoListenerAttached) {
      _h264VideoStream.addListener(_handleH264VideoStateChanged);
      _h264VideoListenerAttached = true;
    }
    _h264VideoStream.onDiagnostic = (payload) {
      if (_connectionDiagId.isNotEmpty) {
        payload['connection_diag_id'] = _connectionDiagId;
      }
      if (payload['event'] == 'video_frame_rendered' &&
          payload['rendered'] == true) {
        _setVideoHandshakeProgress(
          progress: 100,
          stage: '首帧已显示',
          codec: payload['codec']?.toString(),
        );
      }
      final seq = payload['seq'];
      if (seq is num) {
        final frameSeq = seq.toInt();
        final trace = _videoTransportTraces.remove(frameSeq);
        if (trace != null) {
          payload['transport_trace'] = trace;
        }
        final sendResult = _videoTransportSendResults.remove(frameSeq);
        if (sendResult != null) {
          payload['transport_send_result'] = sendResult;
        }
      }
      if (_shouldLogVideoFrameDiagnostic(payload)) {
        sendScrollDiagnostic(payload);
      }
      _sendVideoFrameAck(payload);
    };

    service.onImageFrame = (data) {
      _handleImageFrame(data);
      _originalImageFrameCallback?.call(data);
    };

    service.onVideoStream = (data) {
      _handleVideoStream(data);
      _h264VideoStream.handleSignal(data);
      _originalVideoStreamCallback?.call(data);
    };

    service.onCursorPosition = (data) {
      _handleCursorPosition(data);
      _originalCursorPositionCallback?.call(data);
    };

    service.onSetWindowResponse = (data) {
      final success = data['success'] == true;
      final title = data['title']?.toString();
      final hwnd = data['hwnd'];
      if (success && hwnd is int) {
        _selectedHwnd = hwnd;
      }
      if (success && title != null && title.isNotEmpty) {
        _windowTitle = title;
        _statusMessage = '已选择窗口：$title';
        notifyListeners();
      }
      _originalSetWindowCallback?.call(data);
    };

    service.onControlResponse = (data) {
      final command = data['command']?.toString() ?? '';
      final pending = _pending.remove(command);
      if (pending != null && !pending.isCompleted) {
        final success = data['success'] == true;
        if (success) {
          pending.complete(data);
        } else {
          pending.completeError(
            Exception(data['message']?.toString() ?? '$command 执行失败'),
          );
        }
      }

      final success = data['success'] == true;
      switch (command) {
        case 'fit_window':
          _statusMessage = success ? '窗口已调整为全屏比例' : '全屏适配失败';
          notifyListeners();
          break;
        case 'restore_window':
          _statusMessage = success ? '窗口已恢复原始大小' : '恢复窗口失败';
          notifyListeners();
          break;
        case 'clear_text':
          _statusMessage = success ? '已清空远端输入内容' : '清空失败';
          notifyListeners();
          break;
        case 'set_stream_profile':
          if (success) {
            final profileName = data['profile']?.toString();
            _streamProfile = _parseProfile(profileName) ?? _streamProfile;
            _statusMessage = '画质模式已切换为 $streamProfileLabel';
          } else {
            _statusMessage = '画质模式切换失败';
          }
          notifyListeners();
          break;
        case 'set_stream_tuning':
          if (success) {
            final qualityScale = data['quality_scale'];
            final resolutionScale = data['resolution_scale'];
            final dynamicFps = data['dynamic_fps_limit'];
            final staticFps = data['static_fps_limit'];
            if (qualityScale is num) _qualityScale = qualityScale.toDouble();
            if (resolutionScale is num) {
              _resolutionScale = resolutionScale.toDouble();
            }
            if (dynamicFps is num) _dynamicFpsLimit = dynamicFps.toDouble();
            if (staticFps is num) _staticFpsLimit = staticFps.toDouble();
            _statusMessage = '码率、分辨率和帧率参数已更新';
          } else {
            _statusMessage = '流媒体参数更新失败';
          }
          notifyListeners();
          break;
        case 'set_scroll_video_tuning':
          if (success) {
            final scale = data['scale'];
            final bitrateKbps = data['bitrate_kbps'];
            final fps = data['fps'];
            final crf = data['crf'];
            if (scale is num) _scrollVideoScale = scale.toDouble();
            if (bitrateKbps is num) {
              _scrollVideoBitrateKbps = bitrateKbps.toInt();
            }
            if (fps is num) _scrollVideoFps = fps.toDouble();
            if (crf is num) {
              _scrollVideoCrf = crf.toInt();
            } else if (crf is String) {
              _scrollVideoCrf = int.tryParse(crf) ?? _scrollVideoCrf;
            }
            _statusMessage = '滚动视频参数已更新';
          } else {
            _statusMessage = '滚动视频参数更新失败';
          }
          notifyListeners();
          break;
        case 'set_scroll_mode':
          if (success) {
            _scrollModeActive = data['active'] == true;
          } else {
            _scrollModeActive = false;
            _statusMessage = '婊氬姩妯″紡鍒囨崲澶辫触';
          }
          notifyListeners();
          break;
        case 'set_window_remark':
          if (!success) {
            _statusMessage = '绐楀彛澶囨敞淇濆瓨澶辫触';
            notifyListeners();
          }
          break;
        case 'key_press':
        case 'key_combo':
          if (!success) {
            _statusMessage = '按键发送失败';
            notifyListeners();
          }
          break;
        case 'mouse_click':
        case 'mouse_click_current':
        case 'mouse_move':
        case 'mouse_move_relative':
          if (!success) {
            _statusMessage = '鼠标控制失败';
            notifyListeners();
          }
          break;
      }

      _originalControlResponseCallback?.call(data);
    };

    service.onWebRtcSignal = (data) {
      _directTransport?.handleSignal(data);
      _originalWebRtcSignalCallback?.call(data);
    };
  }

  void _detachSignalingService() {
    final service = _signalingService;
    if (service != null) {
      service.removeListener(_onSignalingStateChanged);
      service.onImageFrame = _originalImageFrameCallback;
      service.onVideoStream = _originalVideoStreamCallback;
      service.onCursorPosition = _originalCursorPositionCallback;
      service.onSetWindowResponse = _originalSetWindowCallback;
      service.onControlResponse = _originalControlResponseCallback;
      service.onWebRtcSignal = _originalWebRtcSignalCallback;
    }
    final directTransport = _directTransport;
    if (directTransport != null) {
      directTransport.removeListener(notifyListeners);
      unawaited(directTransport.stop());
    }
    _signalingService = null;
    _directTransport = null;
    _originalImageFrameCallback = null;
    _originalVideoStreamCallback = null;
    _originalCursorPositionCallback = null;
    _originalSetWindowCallback = null;
    _originalControlResponseCallback = null;
    _originalWebRtcSignalCallback = null;
  }

  void startDirectTransportProbe() {
    return;
  }

  void setConnectionDiagId(String diagId) {
    _connectionDiagId = diagId;
  }

  Future<void> pauseDirectTransportProbe() async {
    try {
      _signalingService?.sendVideoStreamStatus(
        active: false,
        codec: _h264VideoStream.codec,
        reason: 'lifecycle-background',
      );
    } catch (e) {
      sendScrollDiagnostic({
        'event': 'video_status_pause_failed',
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'error': e.toString(),
      });
    }
    try {
      await _directTransport?.stop();
    } catch (e) {
      sendScrollDiagnostic({
        'event': 'direct_transport_pause_failed',
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'error': e.toString(),
      });
    }
    try {
      await _h264VideoStream.stop();
    } catch (e) {
      sendScrollDiagnostic({
        'event': 'h264_stream_pause_failed',
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'error': e.toString(),
      });
    }
    _lastReportedH264Active = false;
    _lastReportedVideoCodec = '';
    _lastReportedVideoStartGeneration = -1;
  }

  Future<bool> restoreVideoTransportAfterForeground({
    String reason = 'foreground-resume',
  }) async {
    final service = _signalingService;
    if (service == null || !service.isConnected) {
      sendScrollDiagnostic({
        'event': 'foreground_video_restore_skipped',
        'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
        'reason': service == null ? 'missing_signaling_service' : 'not_connected',
      });
      return false;
    }

    await _h264VideoStream.stop();
    _lastReportedH264Active = false;
    _lastReportedVideoCodec = '';
    _lastReportedVideoStartGeneration = -1;

    final mediaOk = await service.reconnectMedia();
    service.sendVideoStreamStatus(
      active: false,
      codec: 'h264',
      reason: reason,
    );
    requestVideoRestart(reason: reason, forceH264: true);
    sendScrollDiagnostic({
      'event': 'foreground_video_restore_requested',
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
      'reason': reason,
      'media_reconnect_success': mediaOk,
    });
    notifyListeners();
    return mediaOk;
  }

  Future<void> stopDirectTransportProbe() async {
    final directTransport = _directTransport;
    if (directTransport == null) return;
    directTransport.removeListener(notifyListeners);
    await directTransport.disposeRenderer();
    _directTransport = null;
    _h264VideoStream.onDiagnostic = null;
    await _h264VideoStream.stop();
  }

  void _setVideoHandshakeProgress({
    required int progress,
    required String stage,
    String? codec,
    bool notify = true,
  }) {
    final nextProgress = progress.clamp(_videoHandshakeProgress, 100);
    final nextCodec =
        (codec == 'h265' || codec == 'h264') ? codec! : _videoHandshakeCodec;
    if (_videoHandshakeProgress == nextProgress &&
        _videoHandshakeStage == stage &&
        _videoHandshakeCodec == nextCodec) {
      return;
    }
    _videoHandshakeProgress = nextProgress;
    _videoHandshakeStage = stage;
    _videoHandshakeCodec = nextCodec;
    if (notify) notifyListeners();
  }

  void _handleVideoStreamProgress(Map<String, dynamic> data) {
    final progress = (data['progress'] as num?)?.toInt() ?? 0;
    final stage = _videoProgressStageLabel(
      data['stage']?.toString() ?? '',
      data['stage_label']?.toString(),
    );
    final codec = data['codec']?.toString();
    final title = data['selected_window_title']?.toString();
    final hwnd = data['selected_hwnd'];
    if (title != null && title.isNotEmpty) {
      _windowTitle = title;
    }
    if (hwnd is num) {
      _selectedHwnd = hwnd.toInt();
    }
    _setVideoHandshakeProgress(
      progress: progress,
      stage: stage,
      codec: codec,
    );
  }

  String _videoProgressStageLabel(String stage, String? fallback) {
    switch (stage) {
      case 'window_stabilizing':
        return '正在确认窗口尺寸';
      case 'window_stable':
        return '窗口就绪，正在启动编码器';
      case 'restart_requested':
        return '已请求重新建立视频通道';
      case 'encoding':
        return '正在编码第一帧画面';
      case 'encoded_first_frame':
        return '第一帧已编码，准备发送';
      case 'stream_start_sent':
        return '视频通道信息已发送';
      case 'sending_first_frame':
        return '正在发送视频数据';
      case 'waiting_encoder_output':
        return '等待编码器输出';
      case 'encoder_failed':
        return '编码器启动失败，正在重试';
      default:
        return (fallback != null && fallback.isNotEmpty)
            ? fallback
            : '正在建立视频通道';
    }
  }

  void _handleH264VideoStateChanged() {
    final active = _h264VideoStream.available;
    final codec = _h264VideoStream.codec;
    final startGeneration = _h264VideoStream.startGeneration;
    if (_h264VideoStream.negotiating && !_h264VideoStream.failed) {
      _setVideoHandshakeProgress(
        progress: _videoHandshakeProgress < 88 ? 88 : _videoHandshakeProgress,
        stage: '正在启动解码器',
        codec: codec,
        notify: false,
      );
    } else if (active) {
      _setVideoHandshakeProgress(
        progress: 100,
        stage: '视频已就绪',
        codec: codec,
        notify: false,
      );
    } else if (_h264VideoStream.failed) {
      _setVideoHandshakeProgress(
        progress: _currentFrame != null ? 100 : _videoHandshakeProgress,
        stage: '视频通道失败，正在使用兜底画面',
        codec: codec,
        notify: false,
      );
    }
    if (_h264VideoStream.negotiating && !_h264VideoStream.failed) {
      if (_lastReportedH264Active != false ||
          _lastReportedVideoCodec != codec ||
          _lastReportedVideoStartGeneration != startGeneration) {
        _lastReportedH264Active = false;
        _lastReportedVideoCodec = codec;
        _lastReportedVideoStartGeneration = startGeneration;
        _signalingService?.sendVideoStreamStatus(
          active: false,
          codec: codec,
          reason: 'decoder-negotiating',
        );
      }
      notifyListeners();
      return;
    }
    if (_lastReportedH264Active != active ||
        _lastReportedVideoCodec != codec ||
        _lastReportedVideoStartGeneration != startGeneration ||
        _h264VideoStream.failed) {
      _lastReportedH264Active = active;
      _lastReportedVideoCodec = codec;
      _lastReportedVideoStartGeneration = startGeneration;
      _signalingService?.sendVideoStreamStatus(
        active: active,
        codec: codec,
        reason: active
            ? 'decoder-active'
            : (_h264VideoStream.lastError.isNotEmpty
                ? _h264VideoStream.lastError
                : 'decoder-inactive'),
      );
    }
    notifyListeners();
  }

  void _handleImageFrame(Map<String, dynamic> data) {
    final imageData = data['data'];
    final width = data['width'];
    final height = data['height'];
    final seq = data['seq'];
    final profileName = data['profile']?.toString();
    _signalingService?.sendImageFrameAck();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final shouldLogFrame =
        _imageFrameDiagLastConnectionDiagId != _connectionDiagId ||
            nowMs - _imageFrameDiagLastTsMs > 5000;
    if (shouldLogFrame) {
      _imageFrameDiagLastConnectionDiagId = _connectionDiagId;
      _imageFrameDiagLastTsMs = nowMs;
      sendScrollDiagnostic({
        'event': 'image_frame_received',
        if (_connectionDiagId.isNotEmpty) 'connection_diag_id': _connectionDiagId,
        'client_ts_ms': nowMs,
        'seq': seq,
        'width': width,
        'height': height,
        'profile': profileName ?? '',
        'h264_available': _h264VideoStream.available,
        'h264_negotiating': _h264VideoStream.negotiating,
        'video_stream_width': _videoStreamWidth,
        'video_stream_height': _videoStreamHeight,
        'ws_channel': data['_client_ws_channel']?.toString() ?? '',
        'ws_msg_gap_ms': data['_client_ws_message_gap_ms'],
      });
    }
    final videoTransitionActive =
        _textureOrVideoSizeKnown && nowMs - _lastVideoStreamStartAtMs < 3500;
    final videoOwnsDisplay = _h264VideoStream.available ||
        (_h264VideoStream.negotiating && _textureOrVideoSizeKnown) ||
        videoTransitionActive;

    if (seq is num) {
      final nextSeq = seq.toInt();
      if (nextSeq > 0 && nextSeq <= _lastImageFrameSeq) {
        return;
      }
      _lastImageFrameSeq = nextSeq;
    }

    if (!videoOwnsDisplay) {
      if (width is int) _remoteWidth = width;
      if (height is int) _remoteHeight = height;
    }

    final parsedProfile = _parseProfile(profileName);
    if (parsedProfile != null) {
      _streamProfile = parsedProfile;
    }

    Uint8List? decoded;
    int rawBytes = 0;
    if (imageData is String) {
      rawBytes = imageData.length;
      decoded = base64Decode(imageData);
    } else if (imageData is List) {
      final ints = imageData.map((e) => e as int).toList(growable: false);
      rawBytes = ints.length;
      decoded = Uint8List.fromList(ints);
    }

    if (decoded != null && !videoOwnsDisplay) {
      _currentFrame = decoded;
      _lastImageFrameAt = DateTime.now();
      _lastFrameBytes =
          decoded.lengthInBytes > 0 ? decoded.lengthInBytes : rawBytes;
      _recordFrame(_lastFrameBytes);
      notifyListeners();
      if (shouldLogFrame) {
        sendScrollDiagnostic({
          'event': 'image_frame_displayed',
          if (_connectionDiagId.isNotEmpty) 'connection_diag_id': _connectionDiagId,
          'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
          'seq': seq,
          'bytes': decoded.lengthInBytes,
        });
      }
    }
  }

  bool get _textureOrVideoSizeKnown =>
      _h264VideoStream.textureId != null ||
      (_videoStreamWidth != null && _videoStreamHeight != null);

  void _handleVideoStream(Map<String, dynamic> data) {
    final type = data['type']?.toString() ?? '';
    if (_handshakeConnectedAtMs > 0 && !_h264VideoStream.available) {
      _handshakeReceivedTypes.add(type);
      if (type == 'video_stream_progress') {
        _handshakeStageDetail = '收到 agent 进度: ${data['stage_label'] ?? data['stage'] ?? ''}';
      } else if (type == 'video_stream_start') {
        _handshakeStageDetail = '收到 video_stream_start';
      } else if (type == 'video_stream_frame') {
        _handshakeStageDetail = '正在接收视频帧';
      } else if (type == 'video_stream_keepalive') {
        _handshakeStageDetail = 'agent 保持活跃，等待视频通道...';
      }
    }
    if (type == 'video_stream_progress') {
      _handleVideoStreamProgress(data);
      return;
    }
    if (type == 'video_stream_keepalive') {
      return;
    }
    if (type == 'video_transport_trace') {
      final seq = data['seq'];
      if (seq is num) {
        _videoTransportTraces[seq.toInt()] = Map<String, dynamic>.from(data);
        _pruneVideoTransportMap(_videoTransportTraces);
      }
      return;
    }
    if (type == 'video_transport_send_result') {
      final seq = data['seq'];
      if (seq is num) {
        _videoTransportSendResults[seq.toInt()] =
            Map<String, dynamic>.from(data);
        _pruneVideoTransportMap(_videoTransportSendResults);
      }
      return;
    }
    final width = data['width'];
    final height = data['height'];
    final profileName = data['profile']?.toString();
    if (type == 'video_stream_start') {
      _videoStreamStartTimer?.cancel();
      _videoStreamStartTimer = null;
      _lastVideoStreamStartAtMs = DateTime.now().millisecondsSinceEpoch;
      _setVideoHandshakeProgress(
        progress: _videoHandshakeProgress < 68 ? 68 : _videoHandshakeProgress,
        stage: '已收到视频通道信息，正在接收数据',
        codec: data['codec']?.toString(),
        notify: false,
      );
    } else if (type == 'video_stream_frame') {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final seq = (data['seq'] as num?)?.toInt() ?? 0;
      final shouldLogFrame = seq <= 3 ||
          nowMs - _lastVideoFrameLogTsMs >= 1000 ||
          (seq > 0 && seq - _lastVideoFrameLogSeq >= 30);
      if (shouldLogFrame) {
        _lastVideoFrameLogTsMs = nowMs;
        _lastVideoFrameLogSeq = seq;
        sendScrollDiagnostic({
          'event': 'video_stream_frame_received',
          if (_connectionDiagId.isNotEmpty)
            'connection_diag_id': _connectionDiagId,
          'client_ts_ms': nowMs,
          'seq': data['seq'],
          'codec': data['codec']?.toString(),
          'width': width,
          'height': height,
          'profile': profileName ?? '',
          'h264_available': _h264VideoStream.available,
          'h264_negotiating': _h264VideoStream.negotiating,
        });
      }
      _setVideoHandshakeProgress(
        progress: _videoHandshakeProgress < 82 ? 82 : _videoHandshakeProgress,
        stage: '已收到视频数据，等待解码',
        codec: data['codec']?.toString(),
        notify: false,
      );
    }
    if (width is num && width > 0) _videoStreamWidth = width.toInt();
    if (height is num && height > 0) _videoStreamHeight = height.toInt();
    final parsedProfile = _parseProfile(profileName);
    if (parsedProfile != null) {
      _streamProfile = parsedProfile;
    }
    final payload = data['data'];
    if (payload is String) {
      _lastFrameBytes = payload.length;
      _recordFrame(_lastFrameBytes);
    } else if (payload is List) {
      _lastFrameBytes = payload.length;
      _recordFrame(_lastFrameBytes);
    }
    notifyListeners();
  }

  void _handleCursorPosition(Map<String, dynamic> data) {
    final nextVisible = data['visible'] == true;
    if (nextVisible) {
      _cursorInvisibleStreak = 0;
      _cursorVisible = true;
    } else {
      _cursorInvisibleStreak += 1;
      if (_cursorInvisibleStreak >= 3) {
        _cursorVisible = false;
      }
    }

    final x = data['x'];
    final y = data['y'];
    final width = data['width'];
    final height = data['height'];
    final cursorImage = data['cursor_image'];
    _recordCursorEvent();

    if (_remoteWidth == null && width is num && width > 0) {
      _remoteWidth = width.toInt();
    }
    if (_remoteHeight == null && height is num && height > 0) {
      _remoteHeight = height.toInt();
    }
    if (x is num) {
      _cursorX = x.toDouble().clamp(0.0, 1.0);
    }
    if (y is num) {
      _cursorY = y.toDouble().clamp(0.0, 1.0);
    }
    if (cursorImage is Map) {
      final png = cursorImage['png'];
      final width = cursorImage['width'];
      final height = cursorImage['height'];
      final hotspotX = cursorImage['hotspot_x'];
      final hotspotY = cursorImage['hotspot_y'];
      if (png is String && png.isNotEmpty) {
        if (_cursorImageSignature != png) {
          _cursorImageBytes = base64Decode(png);
          _cursorImageSignature = png;
        }
      }
      if (width is num) _cursorImageWidth = width.toInt();
      if (height is num) _cursorImageHeight = height.toInt();
      if (hotspotX is num) _cursorHotspotX = hotspotX.toInt();
      if (hotspotY is num) _cursorHotspotY = hotspotY.toInt();
    }
    notifyListeners();
  }

  StreamProfile? _parseProfile(String? name) {
    switch (name) {
      case 'hybrid':
        return StreamProfile.hybrid;
      case 'smooth_hd':
        return StreamProfile.smoothHd;
      case 'lan':
        return StreamProfile.lan;
      default:
        return null;
    }
  }

  void _recordFrame(int bytes) {
    final now = DateTime.now();
    _frameStats.add(_FrameStat(timestamp: now, bytes: bytes));
    _pruneStats(now: now);
  }

  void _recordCursorEvent() {
    final now = DateTime.now();
    _cursorStats.add(_EventStat(timestamp: now));
    _pruneStats(now: now);
  }

  void _pruneStats({DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(const Duration(minutes: 1));
    while (_frameStats.isNotEmpty &&
        _frameStats.first.timestamp.isBefore(cutoff)) {
      _frameStats.removeFirst();
    }
    while (_cursorStats.isNotEmpty &&
        _cursorStats.first.timestamp.isBefore(cutoff)) {
      _cursorStats.removeFirst();
    }
  }

  void _onSignalingStateChanged() {
    final signaling = _signalingService;
    if (signaling != null && signaling.isConnected && _handshakeConnectedAtMs <= 0) {
      _startHandshakeTimer();
    }
  }

  void _startHandshakeTimer() {
    _connected = true;
    _videoHandshakeProgress = 0;
    _videoHandshakeStage = '';
    _videoStreamStartRetries = 0;
    _handshakeConnectedAtMs = DateTime.now().millisecondsSinceEpoch;
    _handshakeReceivedTypes.clear();
    _handshakeStageDetail = '信令已连接，等待 agent 响应';
    _handshakeProgressMs = 0;
    _videoStreamStartTimer?.cancel();
    _videoStreamStartTimer = Timer(const Duration(seconds: 15), () {
      _videoStreamStartTimer = null;
      _onVideoStreamStartTimeout();
    });
    _handshakeTickTimer?.cancel();
    _handshakeTickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_connected || _h264VideoStream.available) {
        _handshakeTickTimer?.cancel();
        _handshakeTickTimer = null;
        return;
      }
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      _handshakeProgressMs = nowMs - _handshakeConnectedAtMs;
      notifyListeners();
    });
  }

  void setConnected(bool value, {String? roomId, String? windowTitle}) {
    _connected = value;
    _roomId = roomId;
    _windowTitle = windowTitle ?? _windowTitle;
    final suffix = roomId == null || roomId.isEmpty ? '' : ' - $roomId';
    _statusMessage = value ? '已连接$suffix' : '未连接';
    if (!value) {
      _videoStreamStartTimer?.cancel();
      _videoStreamStartTimer = null;
      _handshakeTickTimer?.cancel();
      _handshakeTickTimer = null;
      _handshakeConnectedAtMs = 0;
    }
    notifyListeners();
  }

  void _onVideoStreamStartTimeout() {
    final signaling = _signalingService;
    if (signaling == null || !_connected) return;
    _videoStreamStartRetries++;
    sendScrollDiagnostic({
      'event': 'video_stream_start_timeout',
      'retry': _videoStreamStartRetries,
      'max_retries': _maxVideoStreamStartRetries,
      'stage': _videoHandshakeStage,
      'progress': _videoHandshakeProgress,
    });
    if (_videoStreamStartRetries > _maxVideoStreamStartRetries) {
      _videoHandshakeStage = '视频通道连接失败，请检查网络后重试';
      notifyListeners();
      return;
    }
    _setVideoHandshakeProgress(
      progress: 5,
      stage: '视频通道超时，正在请求重启...($_videoStreamStartRetries/$_maxVideoStreamStartRetries)',
      codec: 'h264',
    );
    signaling.sendControl('request_video_restart', {
      'reason': 'client-timeout',
      'force_h264': true,
    });
    _videoStreamStartTimer = Timer(const Duration(seconds: 15), () {
      _videoStreamStartTimer = null;
      _onVideoStreamStartTimeout();
    });
  }

  Future<void> resetForHardReconnect() async {
    _videoStreamStartTimer?.cancel();
    _videoStreamStartTimer = null;
    _handshakeTickTimer?.cancel();
    _handshakeTickTimer = null;
    _handshakeConnectedAtMs = 0;
    _videoStreamStartRetries = 0;
    await pauseDirectTransportProbe();
    await _h264VideoStream.disposeService();
    _currentFrame = null;
    _remoteWidth = null;
    _remoteHeight = null;
    _videoStreamWidth = null;
    _videoStreamHeight = null;
    _cursorVisible = false;
    _cursorImageBytes = null;
    _cursorImageWidth = null;
    _cursorImageHeight = null;
    _cursorImageSignature = null;
    _cursorInvisibleStreak = 0;
    _lastFrameBytes = 0;
    _lastImageFrameSeq = 0;
    _lastReportedH264Active = false;
    _lastReportedVideoCodec = '';
    _lastReportedVideoStartGeneration = -1;
    _diagnosticFilter.resetVideoStreamStatus();
    _lastMediaReconnectTsMs = 0;
    _lastVideoRestartRequestTsMs = 0;
    _lastVideoStreamStartAtMs = 0;
    _lastVideoFrameLogTsMs = 0;
    _lastVideoFrameLogSeq = 0;
    _videoTransportTraces.clear();
    _videoTransportSendResults.clear();
    _frameStats.clear();
    _cursorStats.clear();
    _videoHandshakeProgress = 0;
    _videoHandshakeStage = '';
    _videoHandshakeCodec = '';
    _handshakeStageDetail = '';
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(Exception('hard reconnect rebuilding'));
      }
    }
    _pending.clear();
    notifyListeners();
  }

  void setStatus(String message) {
    _statusMessage = message;
    notifyListeners();
  }

  bool sendControl(String command, Map<String, dynamic> params) {
    final signaling = _signalingService;
    if (signaling == null) {
      ScrollDiagnosticLogger.log({
        'event': 'control_send_dropped',
        'command': command,
        'reason': 'missing_signaling_service',
        'connected': _connected,
      });
      return false;
    }
    final sent = signaling.sendControl(command, params);
    if (!sent) {
      ScrollDiagnosticLogger.log({
        'event': 'control_send_dropped',
        'command': command,
        'reason': signaling.isConnected
            ? 'control_channel_unavailable'
            : 'signaling_not_connected',
        'connected': _connected,
        'signaling_status': signaling.status.name,
      });
    }
    return sent;
  }

  void mouseMove(int x, int y) {
    sendControl('mouse_move', {'x': x, 'y': y});
  }

  void mouseMoveRelative(int dx, int dy) {
    sendControl('mouse_move_relative', {'dx': dx, 'dy': dy});
  }

  void mouseClick(int x, int y, String button) {
    sendControl('mouse_click', {'x': x, 'y': y, 'button': button});
  }

  void mouseClickCurrent([String button = 'left']) {
    sendControl('mouse_click_current', {'button': button});
  }

  void debugClientClick({
    required String source,
    required double localX,
    required double localY,
    required double containerW,
    required double containerH,
    required int remoteW,
    required int remoteH,
    required int mappedX,
    required int mappedY,
    int? selectedHwnd,
    String? button,
  }) {
    sendControl('debug_client_click', {
      'source': source,
      'local_x': localX,
      'local_y': localY,
      'container_w': containerW,
      'container_h': containerH,
      'remote_w': remoteW,
      'remote_h': remoteH,
      'mapped_x': mappedX,
      'mapped_y': mappedY,
      'selected_hwnd': selectedHwnd,
      'button': button ?? '',
    });
  }

  void centerCursor() {
    sendControl('center_cursor', {});
  }

  bool mouseWheel(
    int delta, {
    int? wheelDelta,
    Map<String, dynamic>? diagnostic,
  }) {
    final sent = sendControl('mouse_wheel', {
      'delta': delta,
      if (wheelDelta != null) 'wheel_delta': wheelDelta,
      if (diagnostic != null) 'diagnostic': diagnostic,
    });
    return sent;
  }

  bool sendScrollDiagnostic(Map<String, dynamic> payload) {
    if (!_diagnosticFilter.shouldKeepRecoveryDiagnostic(payload)) return false;
    ScrollDiagnosticLogger.log(payload);
    return sendControl('scroll_diagnostic', payload);
  }

  bool requestVideoRestart({
    String reason = 'client-request',
    bool forceH264 = true,
  }) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastVideoRestartRequestTsMs < 1200) return false;
    _lastVideoRestartRequestTsMs = nowMs;
    final sent = sendControl('request_video_restart', {
      'reason': reason,
      'force_h264': forceH264,
    });
    sendScrollDiagnostic({
      'event': 'video_restart_requested',
      'client_ts_ms': nowMs,
      'reason': reason,
      'force_h264': forceH264,
      'sent': sent,
      'h264_available': _h264VideoStream.available,
      'h264_negotiating': _h264VideoStream.negotiating,
    });
    return sent;
  }

  bool _shouldLogVideoFrameDiagnostic(Map<String, dynamic> payload) {
    return _diagnosticFilter.shouldLogVideoFrameDiagnostic(payload);
  }

  void _sendVideoFrameAck(Map<String, dynamic> payload) {
    final service = _signalingService;
    if (service == null) return;
    final seq = payload['seq'];
    if (seq is! num) return;
    final sentAtMs = payload['sent_at_ms'];
    final receiveTsMs = payload['client_receive_ts_ms'];
    final renderTsMs = payload['client_render_ts_ms'];
    final wsGapMs = payload['client_ws_message_gap_ms'];
    final wsBurstCount = payload['client_ws_burst_count'];
    final transportTrace = payload['transport_trace'];
    int? serverForwardTsMs;
    if (transportTrace is Map) {
      final value = transportTrace['server_forward_ts_ms'];
      if (value is num) serverForwardTsMs = value.toInt();
    }
    final ackPayload = <String, dynamic>{
      'seq': seq.toInt(),
      'codec': payload['codec']?.toString() ?? '',
      'rendered': payload['rendered'] == true,
      'available': payload['available'] == true,
      'bytes': (payload['bytes'] as num?)?.toInt() ?? 0,
      'client_ws_message_gap_ms': (wsGapMs as num?)?.toInt(),
      'client_ws_burst_count': (wsBurstCount as num?)?.toInt(),
      'stale_dropped_before_frame':
          (payload['stale_dropped_before_frame'] as num?)?.toInt(),
      'native_call_ms': payload['native_call_ms'],
      'client_receive_ts_ms': (receiveTsMs as num?)?.toInt(),
      'client_render_ts_ms': (renderTsMs as num?)?.toInt(),
      'sent_at_ms': (sentAtMs as num?)?.toInt(),
      if (sentAtMs is num && receiveTsMs is num)
        'desktop_to_client_receive_ms': receiveTsMs.toInt() - sentAtMs.toInt(),
      if (sentAtMs is num && renderTsMs is num)
        'desktop_to_client_render_ms': renderTsMs.toInt() - sentAtMs.toInt(),
      if (serverForwardTsMs != null && receiveTsMs is num)
        'server_to_client_receive_ms':
            receiveTsMs.toInt() - serverForwardTsMs,
    };
    service.sendVideoFrameAck(ackPayload);
    final serverToClientMs = ackPayload['server_to_client_receive_ms'];
    final burstCount = ackPayload['client_ws_burst_count'];
    final gapMs = ackPayload['client_ws_message_gap_ms'];
    if ((serverToClientMs is int && serverToClientMs >= 900) ||
        (burstCount is int && burstCount >= 12) ||
        (gapMs is int && gapMs >= 500)) {
      service.sendVideoCongestion({
        ...ackPayload,
        'reason': 'media_delay',
      });
      _maybeReconnectCongestedMedia(
        serverToClientMs: serverToClientMs is int ? serverToClientMs : 0,
        burstCount: burstCount is int ? burstCount : 0,
        gapMs: gapMs is int ? gapMs : 0,
      );
    }
  }

  void _maybeReconnectCongestedMedia({
    required int serverToClientMs,
    required int burstCount,
    required int gapMs,
  }) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastMediaReconnectTsMs < 2500) return;
    if (serverToClientMs < 1800 && burstCount < 24 && gapMs < 900) return;
    _lastMediaReconnectTsMs = nowMs;
    sendScrollDiagnostic({
      'event': 'media_reconnect_suppressed',
      'client_ts_ms': nowMs,
      'reason': 'congestion_should_not_restart_or_close_active_media',
      'server_to_client_receive_ms': serverToClientMs,
      'client_ws_burst_count': burstCount,
      'client_ws_message_gap_ms': gapMs,
    });
  }

  void _pruneVideoTransportMap(Map<int, Map<String, dynamic>> values) {
    if (values.length <= 300) return;
    final keys = values.keys.toList(growable: false)..sort();
    for (final key in keys.take(values.length - 300)) {
      values.remove(key);
    }
  }

  void setVideoPaused(bool paused) {
    sendControl('set_video_paused', {'paused': paused});
  }

  void setScrollMode(bool active) {
    if (_scrollModeActive == active) {
      if (active) {
        sendControl('set_scroll_mode', {'active': true});
        if (!_h264VideoStream.available) {
          requestVideoRestart(reason: 'scroll-mode-keepalive');
        }
      }
      return;
    }
    _scrollModeActive = active;
    notifyListeners();
    sendControl('set_scroll_mode', {'active': active});
    if (active && !_h264VideoStream.available) {
      requestVideoRestart(reason: 'scroll-mode-video-inactive');
    }
  }

  void keyPress(int keyCode) {
    sendControl('key_press', {'key_code': keyCode});
  }

  void keyCombo(List<int> modifiers, int keyCode) {
    sendControl('key_combo', {
      'modifiers': modifiers,
      'key_code': keyCode,
    });
  }

  void deleteLastChar() {
    keyPress(0x08);
  }

  void clearRemoteText() {
    sendControl('clear_text', {});
  }

  void pasteText(String text, {String diagId = ''}) {
    sendControl('paste_text', {
      'text': text,
      if (diagId.isNotEmpty) 'diag_id': diagId,
    });
  }

  void executeCommand(String commandText, {bool autoEnter = true}) {
    sendControl('execute_command', {
      'command_text': commandText,
      'auto_enter': autoEnter,
    });
  }

  void setWindow(int hwnd) {
    _selectedHwnd = hwnd;
    _signalingService?.setWindow(hwnd);
  }

  void setStreamProfile(StreamProfile profile) {
    _streamProfile = profile;
    _statusMessage = '正在切换到 $streamProfileLabel...';
    notifyListeners();
    sendControl(
      'set_stream_profile',
      {
        'profile': switch (profile) {
          StreamProfile.hybrid => 'hybrid',
          StreamProfile.smoothHd => 'smooth_hd',
          StreamProfile.lan => 'lan',
        },
      },
    );
  }

  void setStreamTuning({
    required double qualityScale,
    required double resolutionScale,
    required double dynamicFpsLimit,
    required double staticFpsLimit,
  }) {
    _qualityScale = qualityScale.clamp(0.15, 1.0);
    _resolutionScale = resolutionScale.clamp(0.20, 1.0);
    _dynamicFpsLimit = dynamicFpsLimit.clamp(1.0, 60.0);
    _staticFpsLimit = staticFpsLimit.clamp(0.2, 60.0);
    _statusMessage = '正在更新码率、分辨率和帧率参数...';
    notifyListeners();
    sendControl(
      'set_stream_tuning',
      {
        'quality_scale': _qualityScale,
        'resolution_scale': _resolutionScale,
        'dynamic_fps_limit': _dynamicFpsLimit,
        'static_fps_limit': _staticFpsLimit,
      },
    );
  }

  void setScrollVideoTuning({
    required double scale,
    required int bitrateKbps,
    required double fps,
    required int crf,
    int vbvMultiplier = 3,
    String pixelFormat = 'yuv420p',
    String preset = 'veryfast',
  }) {
    _scrollVideoScale = scale.clamp(0.30, 1.0);
    _scrollVideoBitrateKbps = bitrateKbps.clamp(128, 60000);
    _scrollVideoFps = fps.clamp(5.0, 60.0);
    _scrollVideoCrf = crf.clamp(0, 38);
    _scrollVideoVbvMultiplier = vbvMultiplier.clamp(2, 8);
    _scrollVideoPixelFormat =
        pixelFormat == 'yuv444p' ? 'yuv444p' : 'yuv420p';
    _scrollVideoPreset = <String>{
      'ultrafast',
      'superfast',
      'veryfast',
      'faster',
      'fast',
    }.contains(preset)
        ? preset
        : 'veryfast';
    _statusMessage = '正在更新滚动视频参数...';
    notifyListeners();
    sendControl(
      'set_scroll_video_tuning',
      {
        'scale': _scrollVideoScale,
        'bitrate_kbps': _scrollVideoBitrateKbps,
        'fps': _scrollVideoFps,
        'crf': _scrollVideoCrf,
        'vbv_multiplier': _scrollVideoVbvMultiplier,
        'pixel_format': _scrollVideoPixelFormat,
        'preset': _scrollVideoPreset,
      },
    );
  }

  Future<String> setWindowRemark(int hwnd, String remark) async {
    final response = await _sendControlForResult(
      'set_window_remark',
      {
        'hwnd': hwnd,
        'remark': remark,
      },
    );
    return response['remark']?.toString() ?? '';
  }

  void fitWindowToViewport({
    required double viewportWidth,
    required double viewportHeight,
    double padding = 24,
    int windowScalePercent = 100,
  }) {
    _statusMessage = '正在切换全屏...';
    notifyListeners();
    sendControl(
      'fit_window',
      {
        'viewport_width': viewportWidth.round(),
        'viewport_height': viewportHeight.round(),
        'padding': padding.round(),
        'window_scale_percent': windowScalePercent.clamp(30, 100),
      },
    );
  }

  void restoreWindow() {
    _statusMessage = '正在恢复窗口...';
    notifyListeners();
    sendControl('restore_window', {});
  }

  Future<ScreenshotCaptureResult> captureScreenshotRegion({
    required int left,
    required int top,
    required int width,
    required int height,
  }) async {
    final signaling = _signalingService;
    if (signaling == null || !signaling.isConnected) {
      throw Exception('当前未连接到电脑');
    }
    final remoteW = _remoteWidth;
    final remoteH = _remoteHeight;
    if (remoteW == null || remoteH == null || remoteW <= 0 || remoteH <= 0) {
      throw Exception('当前还没有有效的远程画面尺寸');
    }

    _statusMessage = '正在生成高清截图...';
    notifyListeners();

    final response = await _sendControlForResult(
      'capture_region_screenshot',
      {
        'client_id': signaling.clientId,
        'left': left,
        'top': top,
        'width': width,
        'height': height,
        'remote_width': remoteW,
        'remote_height': remoteH,
      },
      timeout: const Duration(seconds: 90),
    );

    final absoluteDownloadUrl = response['download_url']?.toString() ?? '';
    final relativeDownloadUrl =
        response['relative_download_url']?.toString() ?? '';
    if (absoluteDownloadUrl.trim().isEmpty &&
        relativeDownloadUrl.trim().isEmpty) {
      throw Exception('服务端未返回截图下载地址');
    }

    final uri = _resolveDownloadUri(
      signaling.serverUrl,
      absoluteDownloadUrl: absoluteDownloadUrl,
      relativeDownloadUrl: relativeDownloadUrl,
    );
    final httpResponse = await http.get(uri).timeout(
          const Duration(seconds: 120),
          onTimeout: () => throw Exception('截图下载超时'),
        );
    if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
      throw Exception('截图下载失败: ${httpResponse.statusCode}');
    }

    _statusMessage = '截图已加载';
    notifyListeners();
    return ScreenshotCaptureResult(
      imageBytes: httpResponse.bodyBytes,
      fileName: response['file_name']?.toString() ?? 'capture.png',
      imageWidth: response['image_width'] is num
          ? (response['image_width'] as num).toInt()
          : 0,
      imageHeight: response['image_height'] is num
          ? (response['image_height'] as num).toInt()
          : 0,
    );
  }

  Future<Map<String, dynamic>> _sendControlForResult(
    String command,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    final signaling = _signalingService;
    if (signaling == null || !signaling.isConnected) {
      throw Exception('当前未连接到电脑');
    }

    if (_pending.containsKey(command)) {
      throw Exception('命令仍在执行中: $command');
    }

    final completer = Completer<Map<String, dynamic>>();
    _pending[command] = completer;
    signaling.sendControl(command, params);
    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(command);
      throw Exception('请求超时: $command');
    });
  }

  Uri _resolveDownloadUri(
    String serverUrl, {
    required String absoluteDownloadUrl,
    required String relativeDownloadUrl,
  }) {
    final absolute = absoluteDownloadUrl.trim();
    if (absolute.isNotEmpty) {
      final parsed = Uri.tryParse(absolute);
      if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
        return parsed;
      }
    }

    final relative = relativeDownloadUrl.trim();
    if (relative.isEmpty) {
      throw Exception('下载地址为空');
    }

    final wsUri = Uri.parse(_normalizeWsUrl(serverUrl));
    final scheme = wsUri.scheme == 'wss' ? 'https' : 'http';
    final baseUri = wsUri.replace(scheme: scheme, path: '/', query: '');
    return baseUri.resolve(relative);
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

  void disconnect() {
    _signalingService?.disconnect();
    setConnected(false);
  }

  @visibleForTesting
  set currentFrameForTest(Uint8List value) {
    _currentFrame = value;
  }

  @visibleForTesting
  set remoteSizeForTest(Size value) {
    _remoteWidth = value.width.round();
    _remoteHeight = value.height.round();
  }
}
