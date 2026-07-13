import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class _PendingVideoFrame {
  const _PendingVideoFrame({
    required this.data,
    required this.seq,
    required this.receiveTsMs,
    required this.droppedBefore,
  });

  final Map<String, dynamic> data;
  final int seq;
  final int receiveTsMs;
  final int droppedBefore;
}

class H264VideoStreamService with ChangeNotifier {
  static const MethodChannel _channel =
      MethodChannel('pocketwindow/h264_video');

  int? _textureId;
  bool _available = false;
  bool _failed = false;
  int _lastSeq = 0;
  int? _width;
  int? _height;
  int? _contentWidth;
  int? _contentHeight;
  String _codec = 'h264';
  int _framesWithoutOutput = 0;
  int _nativeRestartAttempts = 0;
  bool _hasRenderedFrame = false;
  bool _pendingNativeStart = false;
  bool _negotiating = false;
  int? _negotiationStartedAtMs;
  int _startGeneration = 0;
  String _lastError = '';
  final List<DateTime> _renderedFrameTimes = <DateTime>[];
  void Function(Map<String, dynamic>)? onDiagnostic;
  _PendingVideoFrame? _pendingFrame;
  bool _decodingFrame = false;
  int _droppedStaleFrames = 0;
  static const int _restartFramesWithoutOutput = 24;
  static const int _maxFramesWithoutOutput = 45;
  static const int _restartNegotiationMsWithoutOutput = 3000;
  static const int _maxNegotiationMsWithoutOutput = 6000;
  final SplayTreeMap<int, _PendingVideoFrame> _reorderBuffer =
      SplayTreeMap<int, _PendingVideoFrame>();
  int _nextExpectedSeq = 0;
  int? _reorderWaitingSinceMs;
  static const int _reorderTimeoutMs = 500;

  bool get available =>
      _available && _textureId != null && !_failed && _hasRenderedFrame;
  bool get failed => _failed;
  int? get textureId => _textureId;
  int? get width => _width;
  int? get height => _height;
  int? get contentWidth => _contentWidth;
  int? get contentHeight => _contentHeight;
  String get codec => _codec;
  String get lastError => _lastError;
  bool get negotiating => _negotiating && !_available && !_failed;
  bool get hasRenderedFrame => _hasRenderedFrame;
  int get startGeneration => _startGeneration;
  double get renderedFps {
    _pruneRenderedFrameTimes();
    return _renderedFrameTimes.length.toDouble();
  }

  DateTime? get lastRenderedFrameAt =>
      _renderedFrameTimes.isEmpty ? null : _renderedFrameTimes.last;

  Future<void> handleSignal(Map<String, dynamic> data) async {
    if (!Platform.isAndroid) return;
    final type = data['type']?.toString() ?? '';
    try {
      switch (type) {
        case 'video_stream_start':
          await _start(data);
          break;
        case 'video_stream_frame':
          _enqueueFrame(data);
          break;
        case 'video_stream_stop':
          await stop();
          break;
      }
    } catch (error) {
      _lastError = error.toString();
      _failed = true;
      _available = false;
      notifyListeners();
    }
  }

  Future<void> stop({bool notify = true}) async {
    final textureId = _textureId;
    _textureId = null;
    _available = false;
    _lastSeq = 0;
    _framesWithoutOutput = 0;
    _nativeRestartAttempts = 0;
    _hasRenderedFrame = false;
    _pendingNativeStart = false;
    _negotiating = false;
    _negotiationStartedAtMs = null;
    _pendingFrame = null;
    _decodingFrame = false;
    _droppedStaleFrames = 0;
    _reorderBuffer.clear();
    _nextExpectedSeq = 0;
    _reorderWaitingSinceMs = null;
    _renderedFrameTimes.clear();
    _width = null;
    _height = null;
    _contentWidth = null;
    _contentHeight = null;
    if (textureId != null && Platform.isAndroid) {
      try {
        await _channel.invokeMethod<void>('stop', {'textureId': textureId});
      } catch (_) {
        // The fallback image stream remains active if native cleanup fails.
      }
    }
    if (notify) notifyListeners();
  }

  Future<void> disposeService() async {
    await stop(notify: false);
    _failed = false;
  }

  Future<void> _start(Map<String, dynamic> data) async {
    final codec = data['codec']?.toString() ?? '';
    final format = data['format']?.toString() ?? '';
    final width = (data['width'] as num?)?.toInt() ?? 0;
    final height = (data['height'] as num?)?.toInt() ?? 0;
    final contentWidth = (data['content_width'] as num?)?.toInt();
    final contentHeight = (data['content_height'] as num?)?.toInt();
    if ((codec != 'h264' && codec != 'h265') ||
        format != 'annexb' ||
        width <= 0 ||
        height <= 0) {
      return;
    }
    _contentWidth = contentWidth;
    _contentHeight = contentHeight;
    final currentCodec = _codec;
    if (_textureId != null &&
        _width == width &&
        _height == height &&
        currentCodec == codec &&
        !_failed) {
      if (!_hasRenderedFrame && !_failed) {
        _negotiating = true;
        _negotiationStartedAtMs ??= DateTime.now().millisecondsSinceEpoch;
        notifyListeners();
      } else if (_hasRenderedFrame && _available) {
        notifyListeners();
      }
      return;
    }
    if (_textureId != null) {
      await stop(notify: false);
    }
    _startGeneration += 1;
    _codec = codec;
    _width = width;
    _height = height;
    _available = false;
    _failed = false;
    _lastSeq = 0;
    _framesWithoutOutput = 0;
    _nativeRestartAttempts = 0;
    _hasRenderedFrame = false;
    _negotiating = true;
    _negotiationStartedAtMs = DateTime.now().millisecondsSinceEpoch;
    _lastError = '';
    notifyListeners();
    if (codec == 'h265' || codec == 'h264') {
      _pendingNativeStart = true;
      return;
    }
    final textureId = await _channel.invokeMethod<int>('start', {
      'codec': codec,
      'width': width,
      'height': height,
    });
    if (textureId == null) return;
    _textureId = textureId;
    _pendingNativeStart = false;
  }

  void _enqueueFrame(Map<String, dynamic> data) {
    final receiveTsMs = DateTime.now().millisecondsSinceEpoch;
    final seq = (data['seq'] as num?)?.toInt() ?? 0;

    if (seq > 0) {
      if (seq < _nextExpectedSeq) return;
      _reorderBuffer[seq] = _PendingVideoFrame(
        data: data,
        seq: seq,
        receiveTsMs: receiveTsMs,
        droppedBefore: _droppedStaleFrames,
      );
      if (_reorderBuffer.length > 8) {
        _droppedStaleFrames += _reorderBuffer.length - 1;
        final latest = _reorderBuffer.lastKey()!;
        final latestFrame = _reorderBuffer.remove(latest)!;
        _nextExpectedSeq = latest + 1;
        _reorderBuffer.clear();
        _reorderBuffer[latest] = latestFrame;
      }
    } else {
      _pendingFrame = _PendingVideoFrame(
        data: data,
        seq: seq,
        receiveTsMs: receiveTsMs,
        droppedBefore: _droppedStaleFrames,
      );
    }

    if (!_decodingFrame) {
      unawaited(_drainFrames());
    }
  }

  Future<void> _drainFrames() async {
    if (_decodingFrame) return;
    _decodingFrame = true;
    var processed = false;
    var batchCount = 0;
    try {
      while (!_failed) {
        _pendingFrame ??= _nextReorderFrame();
        if (_pendingFrame == null) break;
        processed = true;
        final frame = _pendingFrame!;
        _pendingFrame = null;
        await _pushFrame(
          frame.data,
          receiveTsMs: frame.receiveTsMs,
          staleDroppedBeforeFrame: frame.droppedBefore,
        );
        batchCount++;
        if (batchCount >= 2) {
          await Future<void>.delayed(Duration.zero);
          batchCount = 0;
        }
      }
    } finally {
      _decodingFrame = false;
      if (processed && (_pendingFrame != null || _reorderBuffer.isNotEmpty) && !_failed) {
        unawaited(_drainFrames());
      }
    }
  }

  _PendingVideoFrame? _nextReorderFrame() {
    while (_reorderBuffer.isNotEmpty) {
      final firstKey = _reorderBuffer.firstKey()!;
      if (firstKey <= _nextExpectedSeq) {
        final frame = _reorderBuffer.remove(firstKey)!;
        _nextExpectedSeq = firstKey + 1;
        _reorderWaitingSinceMs = null;
        return frame;
      }
      if (_nextExpectedSeq == 0) {
        _nextExpectedSeq = firstKey;
        final frame = _reorderBuffer.remove(firstKey)!;
        _nextExpectedSeq = firstKey + 1;
        _reorderWaitingSinceMs = null;
        return frame;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_reorderWaitingSinceMs == null) {
        _reorderWaitingSinceMs = now;
        _scheduleReorderTimeout();
      }
      if (now - _reorderWaitingSinceMs! >= _reorderTimeoutMs) {
        onDiagnostic?.call({
          'event': 'reorder_seq_skip',
          'skipped_seq': _nextExpectedSeq,
          'next_buffered_seq': firstKey,
        });
        _nextExpectedSeq++;
        _reorderWaitingSinceMs = null;
        continue;
      }
      break;
    }
    return null;
  }

  void _scheduleReorderTimeout() {
    Future.delayed(const Duration(milliseconds: _reorderTimeoutMs), () {
      if (!_failed && _reorderWaitingSinceMs != null && _reorderBuffer.isNotEmpty) {
        _drainFrames();
      }
    });
  }

  Future<void> _pushFrame(
    Map<String, dynamic> data, {
    required int receiveTsMs,
    required int staleDroppedBeforeFrame,
  }) async {
    var textureId = _textureId;
    if (_failed) return;
    final seq = (data['seq'] as num?)?.toInt() ?? 0;
    if (seq > 0 && seq <= _lastSeq) return;
    final sentAtMs = (data['sent_at'] as num?)?.toInt();
    final raw = data['data'];
    Uint8List bytes;
    final base64StartUs = DateTime.now().microsecondsSinceEpoch;
    final binaryFrame = data['binary'] == true;
    if (raw is Uint8List) {
      bytes = raw;
    } else if (raw is String && raw.isNotEmpty) {
      bytes = base64Decode(raw);
    } else if (raw is List) {
      bytes = Uint8List.fromList(raw.map((item) => item as int).toList());
    } else {
      return;
    }
    final base64EndUs = DateTime.now().microsecondsSinceEpoch;
    if (bytes.isEmpty) return;
    if (textureId == null && _pendingNativeStart) {
      try {
        textureId = await _channel.invokeMethod<int>('start', {
          'codec': _codec,
          'width': _width,
          'height': _height,
          'configData': bytes,
        });
      } catch (error) {
        _lastError = error.toString();
        _failed = true;
        _available = false;
        notifyListeners();
        return;
      }
      if (textureId == null) return;
      _textureId = textureId;
      _pendingNativeStart = false;
    }
    if (textureId == null) return;
    bool rendered;
    Map<dynamic, dynamic>? nativeStats;
    final nativeStartUs = DateTime.now().microsecondsSinceEpoch;
    try {
      final result = await _channel.invokeMethod<dynamic>('pushFrame', {
        'textureId': textureId,
        'data': bytes,
        'ptsUs': DateTime.now().microsecondsSinceEpoch,
        'seq': seq,
        'sentAtMs': sentAtMs,
      });
      if (result is bool) {
        rendered = result;
      } else if (result is Map) {
        nativeStats = result;
        rendered = result['rendered'] == true;
      } else {
        rendered = false;
      }
    } catch (error) {
      _lastError = error.toString();
      _failed = true;
      _available = false;
      notifyListeners();
      return;
    }
    final nativeEndUs = DateTime.now().microsecondsSinceEpoch;
    final renderTsMs = DateTime.now().millisecondsSinceEpoch;
    if (seq > 0) _lastSeq = seq;
    if (rendered) {
      _recordRenderedFrame();
      _framesWithoutOutput = 0;
      _hasRenderedFrame = true;
      _negotiating = false;
      _negotiationStartedAtMs = null;
      if (!_available) {
        _available = true;
        notifyListeners();
      }
    } else if (!_hasRenderedFrame) {
      _framesWithoutOutput += 1;
      final startedAtMs = _negotiationStartedAtMs;
      final elapsedMs = startedAtMs == null ? 0 : renderTsMs - startedAtMs;
      if (_nativeRestartAttempts < 1 &&
          (_framesWithoutOutput >= _restartFramesWithoutOutput ||
              elapsedMs >= _restartNegotiationMsWithoutOutput)) {
        try {
          await _restartNativeDecoder(bytes);
        } catch (error) {
          _lastError = error.toString();
          _failed = true;
          _available = false;
          _negotiating = false;
          _negotiationStartedAtMs = null;
          notifyListeners();
          return;
        }
        onDiagnostic?.call({
          'event': 'video_decoder_native_restart',
          'seq': seq,
          'codec': _codec,
          'frames_without_output': _framesWithoutOutput,
          'elapsed_ms': elapsedMs,
        });
        return;
      }
      if (_framesWithoutOutput >= _maxFramesWithoutOutput ||
          elapsedMs >= _maxNegotiationMsWithoutOutput) {
        _lastError = '$_codec decoder produced no output';
        _failed = true;
        _available = false;
        _negotiating = false;
        _negotiationStartedAtMs = null;
        notifyListeners();
      }
    }
    onDiagnostic?.call({
      'event': 'video_frame_rendered',
      'seq': seq,
      'codec': _codec,
      'sent_at_ms': sentAtMs,
      'client_ws_message_ts_ms': data['_client_ws_message_ts_ms'],
      'client_ws_channel': data['_client_ws_channel'],
      'client_ws_message_gap_ms': data['_client_ws_message_gap_ms'],
      'client_ws_burst_count': data['_client_ws_burst_count'],
      'client_ws_parse_ms': data['_client_ws_parse_ms'],
      'client_receive_ts_ms': receiveTsMs,
      'client_render_ts_ms': renderTsMs,
      'bytes': bytes.lengthInBytes,
      'rendered': rendered,
      'available': available,
      'width': _width,
      'height': _height,
      'binary_frame': binaryFrame,
      'stale_dropped_before_frame': staleDroppedBeforeFrame,
      'pending_frame_after_decode': _pendingFrame?.seq,
      'base64_decode_ms': (base64EndUs - base64StartUs) / 1000.0,
      'native_call_ms': (nativeEndUs - nativeStartUs) / 1000.0,
      if (sentAtMs != null) 'server_sent_to_client_receive_ms': receiveTsMs - sentAtMs,
      if (sentAtMs != null) 'server_sent_to_client_render_ms': renderTsMs - sentAtMs,
      if (nativeStats != null) ..._normalizeNativeStats(nativeStats),
    });
  }

  Future<void> _restartNativeDecoder(Uint8List configData) async {
    final oldTextureId = _textureId;
    _nativeRestartAttempts += 1;
    _framesWithoutOutput = 0;
    _pendingNativeStart = false;
    if (oldTextureId != null) {
      try {
        await _channel.invokeMethod<void>('stop', {'textureId': oldTextureId});
      } catch (_) {
        // A failed decoder session may already be gone on the native side.
      }
    }
    _textureId = null;
    _available = false;
    _lastSeq = 0;
    _reorderBuffer.clear();
    _pendingFrame = null;
    _nextExpectedSeq = 0;
    _reorderWaitingSinceMs = null;
    final textureId = await _channel.invokeMethod<int>('start', {
      'codec': _codec,
      'width': _width,
      'height': _height,
      'configData': configData,
    });
    if (textureId != null) {
      _textureId = textureId;
      _negotiating = true;
      _negotiationStartedAtMs = DateTime.now().millisecondsSinceEpoch;
      notifyListeners();
    }
  }

  Map<String, dynamic> _normalizeNativeStats(Map<dynamic, dynamic> stats) {
    final result = <String, dynamic>{};
    for (final entry in stats.entries) {
      final key = entry.key?.toString();
      if (key == null || key.isEmpty) continue;
      result['native_$key'] = entry.value;
    }
    return result;
  }

  void _recordRenderedFrame() {
    final now = DateTime.now();
    _renderedFrameTimes.add(now);
    _pruneRenderedFrameTimes(now: now);
  }

  void _pruneRenderedFrameTimes({DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(const Duration(seconds: 1));
    _renderedFrameTimes.removeWhere((item) => item.isBefore(cutoff));
  }
}
