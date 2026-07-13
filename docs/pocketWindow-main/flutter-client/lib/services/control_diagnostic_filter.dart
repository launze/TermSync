class ControlDiagnosticFilter {
  bool _lastLoggedVideoStreamActive = false;
  String _lastLoggedVideoStreamCodec = '';
  String _lastLoggedVideoStreamReason = '';

  void resetVideoStreamStatus() {
    _lastLoggedVideoStreamActive = false;
    _lastLoggedVideoStreamCodec = '';
    _lastLoggedVideoStreamReason = '';
  }

  bool shouldKeepRecoveryDiagnostic(Map<String, dynamic> payload) {
    final event = payload['event']?.toString() ?? '';
    if (event.isEmpty) return false;
    if (event.startsWith('lifecycle_')) return true;
    if (event.startsWith('full_reconnect')) return true;
    if (event.startsWith('foreground_')) return true;
    if (event.startsWith('connection_diag')) return true;
    if (event.startsWith('media_reconnect')) return true;
    if (event == 'video_restart_requested') return true;
    if (event == 'video_stream_status_received') {
      final active = payload['active'] == true;
      final codec = payload['codec']?.toString() ?? '';
      final reason = payload['reason']?.toString() ?? '';
      final changed = active != _lastLoggedVideoStreamActive ||
          codec != _lastLoggedVideoStreamCodec ||
          reason != _lastLoggedVideoStreamReason;
      if (changed) {
        _lastLoggedVideoStreamActive = active;
        _lastLoggedVideoStreamCodec = codec;
        _lastLoggedVideoStreamReason = reason;
      }
      return changed;
    }
    if (event.contains('reconnect')) return true;
    if (event.contains('recovery')) return true;
    if (event.contains('failed') || event.contains('error')) return true;
    return false;
  }

  bool shouldLogVideoFrameDiagnostic(Map<String, dynamic> payload) {
    if (payload['event'] != 'video_frame_rendered') return true;
    return false;
  }
}
