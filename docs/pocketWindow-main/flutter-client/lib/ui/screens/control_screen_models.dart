part of 'control_screen.dart';

class _ScrollVideoTuning {
  final double scale;
  final int bitrateKbps;
  final double fps;
  final int crf;
  final int vbvMultiplier;
  final String pixelFormat;
  final String preset;
  final int restoreDelayMs;

  const _ScrollVideoTuning({
    required this.scale,
    required this.bitrateKbps,
    required this.fps,
    required this.crf,
    required this.vbvMultiplier,
    required this.pixelFormat,
    required this.preset,
    required this.restoreDelayMs,
  });

  _ScrollVideoTuning copyWith({
    double? scale,
    int? bitrateKbps,
    double? fps,
    int? crf,
    int? vbvMultiplier,
    String? pixelFormat,
    String? preset,
    int? restoreDelayMs,
  }) {
    return _ScrollVideoTuning(
      scale: scale ?? this.scale,
      bitrateKbps: bitrateKbps ?? this.bitrateKbps,
      fps: fps ?? this.fps,
      crf: crf ?? this.crf,
      vbvMultiplier: vbvMultiplier ?? this.vbvMultiplier,
      pixelFormat: pixelFormat ?? this.pixelFormat,
      preset: preset ?? this.preset,
      restoreDelayMs: restoreDelayMs ?? this.restoreDelayMs,
    );
  }
}

@visibleForTesting
class QuickCommandForTest {
  final String name;
  final String command;

  const QuickCommandForTest({
    required this.name,
    required this.command,
  });

  factory QuickCommandForTest.fromJson(Map<String, dynamic> json) {
    return QuickCommandForTest(
      name: json['name']?.toString() ?? '',
      command: json['command']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'command': command,
      };
}
