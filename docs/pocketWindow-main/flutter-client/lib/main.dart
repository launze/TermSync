import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocketwindow/ui/screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  ErrorWidget.builder = (FlutterErrorDetails details) {
    final message = _formatFlutterError(details);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: _CopyableErrorScreen(message: message),
    );
  };

  runApp(const PocketWindowApp());
}

String _formatFlutterError(FlutterErrorDetails details) {
  final buffer = StringBuffer();
  buffer.writeln('PocketWindow - Flutter Error');
  buffer.writeln();
  buffer.writeln(details.exceptionAsString());
  if (details.stack != null) {
    buffer.writeln();
    buffer.writeln(details.stack.toString());
  }
  return buffer.toString();
}

class _CopyableErrorScreen extends StatelessWidget {
  final String message;

  const _CopyableErrorScreen({required this.message});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF0B1220),
      child: SafeArea(
        child: Scaffold(
          backgroundColor: const Color(0xFF0B1220),
          appBar: AppBar(
            backgroundColor: const Color(0xFF111B2E),
            title: const Text('应用错误'),
            actions: [
              IconButton(
                tooltip: '复制错误',
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: message));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('错误信息已复制')),
                  );
                },
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: SelectableText(
                message,
                style: const TextStyle(
                  color: Color(0xFFE2E8F0),
                  fontSize: 12,
                  height: 1.4,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PocketWindowApp extends StatelessWidget {
  const PocketWindowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PocketWindow',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2457F5)),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
