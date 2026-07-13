// 语音输入服务 - 集成语音识别功能
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter/material.dart';

class SpeechService with ChangeNotifier {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _initialized = false;
  bool _listening = false;
  String _lastSpeech = '';

  bool get initialized => _initialized;
  bool get isListening => _listening;
  String get lastSpeech => _lastSpeech;

  /// 初始化语音识别
  Future<void> initialize() async {
    _initialized = await _speech.initialize(
      onError: (error) => print('语音识别错误: $error'),
      onStatus: (status) => print('语音状态: $status'),
    );
    notifyListeners();
  }

  /// 开始 listening
  Future<void> startListening() async {
    if (!_initialized) return;

    await _speech.listen(
      onResult: (result) {
        _lastSpeech = result.recognizedWords;
        notifyListeners();
      },
    );
    _listening = true;
    notifyListeners();
  }

  /// 停止 listening
  Future<void> stopListening() async {
    await _speech.stop();
    _listening = false;
    notifyListeners();
  }

  /// 取消 listening
  Future<void> cancelListening() async {
    await _speech.cancel();
    _listening = false;
    notifyListeners();
  }

  /// 清除语音记录
  void clear() {
    _lastSpeech = '';
    notifyListeners();
  }
}
