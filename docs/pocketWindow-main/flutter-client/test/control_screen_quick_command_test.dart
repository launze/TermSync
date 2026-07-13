import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketwindow/ui/screens/control_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('quick command sheet can close after editing without framework errors', (
    tester,
  ) async {
    final errors = <FlutterErrorDetails>[];
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details);
    };

    addTearDown(() {
      FlutterError.onError = originalOnError;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return Center(
                child: ElevatedButton(
                  onPressed: () {
                    showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      showDragHandle: true,
                      builder: (sheetContext) => QuickCommandSheetForTest(
                        title: '快捷命令',
                        builtinTitle: 'Codex',
                        customTitle: '自定义命令',
                        emptyText: '暂无命令',
                        addLabel: '新增命令',
                        addHint: '输入命令内容',
                        nameTitle: '命令名称',
                        nameHint: '输入命令名称',
                        savePresetLabel: '保存预设',
                        builtinCommands: const [
                          QuickCommandForTest(name: '默认启动', command: 'codex -C .'),
                        ],
                        quickCommands: const [],
                        onCommandSelected: (_) {},
                        onDeleteCommand: (_) async {},
                        onSaveCommand: (_, __) async {},
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('快捷命令'), findsOneWidget);

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));

    await tester.tap(fields.first);
    await tester.pump();
    await tester.enterText(fields.first, '测试命令');
    await tester.pump();

    await tester.tap(fields.last);
    await tester.pump();
    await tester.enterText(fields.last, 'codex -C .');
    await tester.pump();

    await tester.tapAt(const Offset(20, 20));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    expect(find.text('快捷命令'), findsNothing);
    expect(
      errors.where(
        (details) => details.exceptionAsString().contains('_dependents.isEmpty'),
      ),
      isEmpty,
    );
  });

  testWidgets('quick command sheet stays stable on a small screen while typing', (
    tester,
  ) async {
    final errors = <FlutterErrorDetails>[];
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details);
    };

    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;

    addTearDown(() {
      FlutterError.onError = originalOnError;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          resizeToAvoidBottomInset: true,
          body: Builder(
            builder: (context) {
              return Center(
                child: ElevatedButton(
                  onPressed: () {
                    showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      showDragHandle: true,
                      builder: (sheetContext) => MediaQuery(
                        data: MediaQuery.of(sheetContext).copyWith(
                          viewInsets: const EdgeInsets.only(bottom: 280),
                        ),
                        child: QuickCommandSheetForTest(
                          title: '快捷命令',
                          builtinTitle: 'Codex',
                          customTitle: '自定义命令',
                          emptyText: '暂无命令',
                          addLabel: '新增命令',
                          addHint: '输入命令内容',
                          nameTitle: '命令名称',
                          nameHint: '输入命令名称',
                          savePresetLabel: '保存预设',
                          builtinCommands: const [
                            QuickCommandForTest(name: '默认启动', command: 'codex -C .'),
                          ],
                          quickCommands: const [],
                          onCommandSelected: (_) {},
                          onDeleteCommand: (_) async {},
                          onSaveCommand: (_, __) async {},
                        ),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));

    await tester.tap(fields.last);
    await tester.pump();
    await tester.enterText(fields.last, 'codex --dangerously-bypass-approvals-and-sandbox');
    await tester.pumpAndSettle();

    expect(find.text('快捷命令'), findsOneWidget);
    expect(
      errors.where(
        (details) =>
            details.exceptionAsString().contains('A RenderFlex overflowed') ||
            details.exceptionAsString().contains('_dependents.isEmpty'),
      ),
      isEmpty,
    );
  });
}
