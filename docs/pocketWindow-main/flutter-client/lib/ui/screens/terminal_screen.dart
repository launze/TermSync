import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import 'package:pocketwindow/services/terminal_service.dart';

class TerminalScreen extends StatefulWidget {
  final String roomId;

  const TerminalScreen({
    super.key,
    required this.roomId,
  });

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  // User-adjustable font size; columns/rows auto-fit the screen from this.
  double _fontSize = 12.0;
  static const double _minFontSize = 6.0;
  static const double _maxFontSize = 28.0;

  // The session currently rendered full-screen; null = showing the list.
  TerminalSessionState? _current;

  // Input mode: when false, a vertical drag scrolls the program's own
  // scrollback (read-only); when true, the soft keyboard is shown and
  // keystrokes go to the terminal.
  bool _inputMode = false;
  final FocusNode _terminalFocusNode = FocusNode();
  // We drive scrolling ourselves so a single-finger drag scrolls the
  // scrollback (xterm's built-in drag does text selection instead).
  final ScrollController _scrollController = ScrollController();
  // Read-only scroll gesture: accumulated drag distance and a rate-limit clock
  // so a swipe becomes mouse-wheel events (terminal.scroll) on the desktop.
  double _scrollDragAccum = 0;
  DateTime _lastScrollSent = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _terminalFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _toggleInputMode() {
    setState(() => _inputMode = !_inputMode);
    if (_inputMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _terminalFocusNode.requestFocus();
      });
    } else {
      _terminalFocusNode.unfocus();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<TerminalService>().requestList();
    });
  }

  void _openInfo(RemoteSessionInfo info) {
    final service = context.read<TerminalService>();
    final state = service.attach(info);
    setState(() {
      _current = state;
    });
  }

  void _createAndOpen(String shell) {
    context.read<TerminalService>().createSession(shell: shell);
    // The session opens automatically when terminal.created arrives; switch to
    // it via a listener-driven rebuild.
    _pendingShell = shell;
  }

  String? _pendingShell;

  void _backToList() {
    final service = context.read<TerminalService>();
    final current = _current;
    if (current != null) {
      // Leaving the view = detach (keep desktop PTY alive).
      service.detach(current.sessionId);
    }
    setState(() => _current = null);
    service.requestList();
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<TerminalService>();

    // Auto-open a freshly created session.
    if (_pendingShell != null && _current == null) {
      final attached = service.attachedSessions;
      if (attached.isNotEmpty) {
        _pendingShell = null;
        _current = attached.last;
      }
    }

    final current = _current;
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        title: Text(current == null ? '终端' : current.title),
        leading: current != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回列表',
                onPressed: _backToList,
              )
            : null,
        actions: current == null
            ? [
                PopupMenuButton<String>(
                  icon: const Icon(Icons.add),
                  tooltip: '新建终端',
                  onSelected: _createAndOpen,
                  itemBuilder: (_) => [
                    for (final shell in service.availableShells)
                      PopupMenuItem(value: shell, child: Text(_shellLabel(shell))),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: '刷新列表',
                  onPressed: () => service.requestList(),
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '关闭此终端',
                  onPressed: () {
                    final id = current.sessionId;
                    context.read<TerminalService>().closeSession(id);
                    setState(() => _current = null);
                    context.read<TerminalService>().requestList();
                  },
                ),
              ],
      ),
      body: current == null ? _buildSessionList(service) : _buildAttachedView(current),
    );
  }

  String _shellLabel(String shell) {
    switch (shell) {
      case 'powershell':
        return 'PowerShell';
      case 'pwsh':
        return 'PowerShell Core (pwsh)';
      case 'cmd':
        return 'cmd';
      default:
        return shell;
    }
  }

  Widget _buildSessionList(TerminalService service) {
    final sessions = service.remoteSessions;
    if (!service.isConnected) {
      return const Center(
        child: Text('未连接到电脑', style: TextStyle(color: Colors.white70)),
      );
    }
    if (sessions.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '电脑上还没有终端',
              style: TextStyle(color: Colors.white70, fontSize: 15),
            ),
            const SizedBox(height: 16),
            PopupMenuButton<String>(
              onSelected: _createAndOpen,
              itemBuilder: (_) => [
                for (final shell in service.availableShells)
                  PopupMenuItem(value: shell, child: Text(_shellLabel(shell))),
              ],
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, color: Colors.white, size: 20),
                    SizedBox(width: 8),
                    Text('新建终端（选择类型）', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => service.requestList(),
      child: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: sessions.length,
        separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 1),
        itemBuilder: (_, index) {
          final s = sessions[index];
          return ListTile(
            leading: Icon(
              s.attached ? Icons.phonelink : Icons.terminal,
              color: s.attached ? Colors.lightBlueAccent : Colors.white70,
            ),
            title: Text(
              s.title.isNotEmpty ? s.title : _shellLabel(s.shell),
              style: const TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              '${s.shell}  ·  ${s.cols}×${s.rows}${s.attached ? '  ·  已被接入' : ''}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.white38),
              tooltip: '关闭',
              onPressed: () => context.read<TerminalService>().closeSession(s.id),
            ),
            onTap: () => _openInfo(s),
          );
        },
      ),
    );
  }

  Widget _buildAttachedView(TerminalSessionState session) {
    return Column(
      children: [
        Expanded(
          // Both modes render with the SAME xterm TerminalView so the picture
          // is always correct. The only difference is interaction:
          //  - input mode: fully interactive (soft keyboard, mouse reporting);
          //  - read-only mode: a vertical drag drives the *program's own*
          //    scrollback on the desktop (terminal.scroll -> mouse wheel), so
          //    opencode/claude scroll their internal history and repaint. We
          //    show the repainted frame, a 1:1 copy of the desktop.
          child: _buildTerminalView(session),
        ),
        _buildKeyBar(session),
      ],
    );
  }

  void _sendKey(TerminalSessionState session, String data) {
    session.terminal.onOutput?.call(data);
  }

  Widget _buildKeyBar(TerminalSessionState session) {
    final keys = <_KeyDef>[
      const _KeyDef('Esc', '\x1b'),
      const _KeyDef('Tab', '\t'),
      const _KeyDef('Ctrl+C', '\x03'),
      const _KeyDef('↑', '\x1b[A'),
      const _KeyDef('↓', '\x1b[B'),
      const _KeyDef('←', '\x1b[D'),
      const _KeyDef('→', '\x1b[C'),
    ];
    return Container(
      color: const Color(0xFF2A2A2A),
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
      child: Row(
        children: [
          // Input-mode toggle: scroll history vs. type.
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _inputMode ? Colors.blueAccent : const Color(0xFF3A3A3A),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 34),
              ),
              icon: Icon(_inputMode ? Icons.keyboard_hide : Icons.keyboard, size: 16),
              label: Text(_inputMode ? '收起' : '键盘', style: const TextStyle(fontSize: 12)),
              onPressed: _toggleInputMode,
            ),
          ),
          // Font size controls: columns/rows auto-fit from the chosen size.
          _fontButton(Icons.remove, () => _changeFontSize(-1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              _fontSize.toStringAsFixed(0),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          _fontButton(Icons.add, () => _changeFontSize(1)),
          const SizedBox(width: 6),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final key in keys)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white24),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          minimumSize: const Size(0, 34),
                        ),
                        onPressed: () => _sendKey(session, key.data),
                        child: Text(key.label, style: const TextStyle(fontSize: 12)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTerminalView(TerminalSessionState session) {
    // The user picks the font size; xterm's autoResize computes columns/rows
    // from the widget size and the font. autoResize keeps the content buffer
    // independent from the viewport, so output taller than the viewport goes to
    // scrollback and can be scrolled (manual resize broke that).
    final terminalView = TerminalView(
      session.terminal,
      focusNode: _terminalFocusNode,
      scrollController: _scrollController,
      // Default (non-interactive): read-only so a tap never pops the keyboard.
      // Interactive mode (toggled by the keyboard button) makes the terminal
      // fully interactive: taps do mouse reporting and the soft keyboard can be
      // used. xterm couples mouse-reporting and the keyboard, so we expose them
      // together behind the button.
      readOnly: !_inputMode,
      theme: TerminalThemes.defaultTheme,
      textStyle: TerminalStyle(
        fontSize: _fontSize,
        fontFamily: 'monospace',
      ),
      textScaler: TextScaler.noScaling,
      backgroundOpacity: 1.0,
      autofocus: false,
    );

    if (_inputMode) {
      return terminalView;
    }

    // Read-only: a vertical drag drives the program's own scrollback on the
    // desktop. We accumulate drag distance, convert each ~line-height of
    // movement into mouse-wheel lines, and send terminal.scroll. The desktop
    // program (opencode etc.) scrolls its internal history and repaints; that
    // repaint streams back and xterm renders it, so the picture stays correct.
    return Listener(
      onPointerMove: (event) {
        if (event.delta.dy.abs() <= event.delta.dx.abs()) return;
        _scrollDragAccum += event.delta.dy;
        final lineH = (_fontSize * 1.2).clamp(8.0, 64.0);
        if (_scrollDragAccum.abs() < lineH) return;
        final lines = (_scrollDragAccum.abs() / lineH).floor();
        // Drag down (finger moves content down) reveals older content = wheel up.
        final direction = _scrollDragAccum > 0 ? 'up' : 'down';
        _scrollDragAccum -=
            (direction == 'up' ? 1 : -1) * lines * lineH;
        final now = DateTime.now();
        if (now.difference(_lastScrollSent).inMilliseconds < 50) return;
        _lastScrollSent = now;
        context.read<TerminalService>().requestScroll(
              session.sessionId,
              direction,
              lines.clamp(1, 10),
            );
      },
      onPointerUp: (_) => _scrollDragAccum = 0,
      child: terminalView,
    );
  }

  void _changeFontSize(double delta) {
    setState(() {
      _fontSize = (_fontSize + delta).clamp(_minFontSize, _maxFontSize);
    });
  }

  Widget _fontButton(IconData icon, VoidCallback onPressed) {
    return SizedBox(
      width: 34,
      height: 34,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 18,
        color: Colors.white,
        icon: Icon(icon),
        onPressed: onPressed,
      ),
    );
  }
}

class _KeyDef {
  const _KeyDef(this.label, this.data);
  final String label;
  final String data;
}
