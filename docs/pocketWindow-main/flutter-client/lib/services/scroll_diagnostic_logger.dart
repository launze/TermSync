import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class ScrollDiagnosticLogger {
  ScrollDiagnosticLogger._();

  static File? _file;
  static Future<File>? _fileFuture;

  static void log(Map<String, dynamic> payload) {
    unawaited(_write(payload));
  }

  static Future<void> _write(Map<String, dynamic> payload) async {
    try {
      final file = await _resolveFile();
      final record = <String, dynamic>{
        'ts_ms': DateTime.now().millisecondsSinceEpoch,
        ...payload,
      };
      await file.writeAsString(
        '${jsonEncode(record)}\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (_) {
      // Diagnostics must never affect control input.
    }
  }

  static Future<File> _resolveFile() {
    final existing = _file;
    if (existing != null) return Future<File>.value(existing);
    final pending = _fileFuture;
    if (pending != null) return pending;
    final future = _createFile();
    _fileFuture = future;
    return future;
  }

  static Future<File> _createFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final logDir = Directory('${dir.path}${Platform.pathSeparator}PocketWindow');
    if (!await logDir.exists()) {
      await logDir.create(recursive: true);
    }
    final file = File(
      '${logDir.path}${Platform.pathSeparator}scroll_diagnostics_phone.jsonl',
    );
    _file = file;
    return file;
  }
}
