import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:pocketwindow/services/control_service.dart';
import 'package:pocketwindow/services/signaling_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum _WindowFilterMode {
  all,
  terminal,
  folder,
}

class WindowSelectorScreen extends StatefulWidget {
  final String roomId;
  final SignalingService signaling;
  final ControlService controlService;

  const WindowSelectorScreen({
    super.key,
    required this.roomId,
    required this.signaling,
    required this.controlService,
  });

  @override
  State<WindowSelectorScreen> createState() => _WindowSelectorScreenState();
}

class _WindowSelectorScreenState extends State<WindowSelectorScreen> {
  static const _filterModeKey = 'window_selector.filter_mode';
  static const _completedUnreadKey = 'window_selector.completed_unread_hwnds';
  static const _activeUnreadKey = 'window_selector.active_unread_hwnds';
  static const _windowRefreshInterval = Duration(seconds: 2);
  static const _activeTerminalWindow = Duration(seconds: 6);

  List<dynamic> _windows = [];
  List<dynamic> _filteredWindows = [];
  final Map<int, String> _lastWindowTitles = <int, String>{};
  final Map<int, DateTime> _windowChangedAt = <int, DateTime>{};
  final Set<int> _completedUnreadHwnds = <int>{};
  final Set<int> _activeUnreadHwnds = <int>{};
  final Set<int> _viewedHwnds = <int>{};

  bool _loadingWindows = false;
  bool _windowsRequestInFlight = false;
  int _windowsRequestSerial = 0;
  _WindowFilterMode _filterMode = _WindowFilterMode.all;
  int? _selectedWindowHwnd;
  final _searchController = TextEditingController();
  Timer? _windowRefreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _restoreFilterMode();
      await _restoreUnreadState();
      await _loadWindows();
      _startAutoRefresh();
    });
  }

  @override
  void dispose() {
    _windowRefreshTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _startAutoRefresh() {
    _windowRefreshTimer?.cancel();
    _windowRefreshTimer = Timer.periodic(_windowRefreshInterval, (_) {
      _loadWindows(showLoading: false, showErrors: false);
    });
  }

  Future<void> _restoreFilterMode() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_filterModeKey);
    if (!mounted || raw == null || raw.isEmpty) {
      return;
    }

    _WindowFilterMode? restored;
    try {
      restored =
          _WindowFilterMode.values.firstWhere((item) => item.name == raw);
    } catch (_) {
      restored = null;
    }

    if (restored == null) {
      return;
    }

    setState(() {
      _filterMode = restored!;
    });
  }

  Future<void> _persistFilterMode() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_filterModeKey, _filterMode.name);
  }

  Set<int> _decodeHwndSet(String? raw) {
    if (raw == null || raw.isEmpty) {
      return <int>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .map((item) => item is num ? item.toInt() : int.tryParse('$item'))
            .whereType<int>()
            .toSet();
      }
    } catch (_) {}
    return <int>{};
  }

  Future<void> _restoreUnreadState() async {
    final prefs = await SharedPreferences.getInstance();
    _completedUnreadHwnds
      ..clear()
      ..addAll(_decodeHwndSet(prefs.getString(_completedUnreadKey)));
    _activeUnreadHwnds
      ..clear()
      ..addAll(_decodeHwndSet(prefs.getString(_activeUnreadKey)));
  }

  Future<void> _persistUnreadState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _completedUnreadKey,
      jsonEncode(_completedUnreadHwnds.toList(growable: false)),
    );
    await prefs.setString(
      _activeUnreadKey,
      jsonEncode(_activeUnreadHwnds.toList(growable: false)),
    );
  }

  void _recordWindowTitleChanges(List<dynamic> list) {
    final now = DateTime.now();
    final liveHwnds = <int>{};
    final activeNow = <int>{};

    for (final item in list) {
      if (item is! Map) {
        continue;
      }
      final hwndValue = item['hwnd'];
      if (hwndValue is! num) {
        continue;
      }
      final hwnd = hwndValue.toInt();
      final title = item['title']?.toString() ?? '';
      final className = item['class_name']?.toString() ?? '';
      final isTerminal =
          _isTerminalWindow(title.toLowerCase(), className.toLowerCase());
      final isRunning = item['activity_state']?.toString() == 'running';
      liveHwnds.add(hwnd);

      final previousTitle = _lastWindowTitles[hwnd];
      final titleChanged = previousTitle != null && previousTitle != title;
      if (titleChanged) {
        _viewedHwnds.remove(hwnd);
      }
      if (isTerminal &&
          !_viewedHwnds.contains(hwnd) &&
          (isRunning || titleChanged)) {
        _windowChangedAt[hwnd] = now;
        _completedUnreadHwnds.remove(hwnd);
        _activeUnreadHwnds.add(hwnd);
      }
      _lastWindowTitles[hwnd] = title;

      final changedAt = _windowChangedAt[hwnd];
      if (changedAt != null &&
          now.difference(changedAt) <= _activeTerminalWindow) {
        activeNow.add(hwnd);
      }
    }

    _lastWindowTitles.removeWhere((hwnd, _) => !liveHwnds.contains(hwnd));
    _viewedHwnds.removeWhere((hwnd) => !liveHwnds.contains(hwnd));
    _windowChangedAt.removeWhere((hwnd, changedAt) {
      if (!liveHwnds.contains(hwnd)) {
        return true;
      }
      final expired = now.difference(changedAt) > _activeTerminalWindow;
      return expired;
    });
    final completedNow = _activeUnreadHwnds.difference(activeNow);
    completedNow.removeWhere((hwnd) => !liveHwnds.contains(hwnd));
    _completedUnreadHwnds.removeWhere((hwnd) => !liveHwnds.contains(hwnd));
    _completedUnreadHwnds.addAll(completedNow);
    _activeUnreadHwnds
      ..removeWhere((hwnd) => !liveHwnds.contains(hwnd))
      ..removeAll(completedNow);
    unawaited(_persistUnreadState());
  }

  Future<void> _loadWindows({
    bool showLoading = true,
    bool showErrors = true,
  }) async {
    if (_windowsRequestInFlight) {
      return;
    }
    _windowsRequestInFlight = true;

    if (showLoading && mounted) {
      setState(() {
        _loadingWindows = true;
      });
    }

    final signaling = widget.signaling;
    final previousHandler = signaling.onWindowsList;
    final completer = Completer<List<dynamic>>();
    final requestSerial = ++_windowsRequestSerial;

    void handleWindowsList(Map<String, dynamic> data) {
      if (requestSerial != _windowsRequestSerial) {
        previousHandler?.call(data);
        return;
      }
      final list = data['windows'];
      if (list is List && !completer.isCompleted) {
        completer.complete(list);
      }
      previousHandler?.call(data);
    }

    signaling.onWindowsList = handleWindowsList;

    signaling.requestWindowsList();

    try {
      final list = await completer.future.timeout(const Duration(seconds: 5));
      if (requestSerial != _windowsRequestSerial) {
        return;
      }
      if (!mounted) {
        return;
      }

      _recordWindowTitleChanges(list);

      setState(() {
        _windows = list;
        _filteredWindows = _applyFilter(
          list,
          _searchController.text,
          filterMode: _filterMode,
        );
        _loadingWindows = false;
      });
    } catch (e) {
      if (requestSerial == _windowsRequestSerial) {
        _windowsRequestSerial++;
      }
      if (!mounted) {
        return;
      }
      if (showLoading) {
        setState(() {
          _loadingWindows = false;
        });
      }
      if (showErrors) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取窗口列表失败: $e')),
        );
      }
    } finally {
      if (identical(signaling.onWindowsList, handleWindowsList)) {
        signaling.onWindowsList = previousHandler;
      }
      _windowsRequestInFlight = false;
    }
  }

  List<dynamic> _applyFilter(
    List<dynamic> list,
    String keyword, {
    required _WindowFilterMode filterMode,
  }) {
    final query = keyword.trim().toLowerCase();

    return list.where((item) {
      final title =
          (item is Map ? item['title'] : null)?.toString().toLowerCase() ?? '';
      final className =
          (item is Map ? item['class_name'] : null)?.toString().toLowerCase() ??
              '';

      switch (filterMode) {
        case _WindowFilterMode.terminal:
          if (!_isTerminalWindow(title, className)) {
            return false;
          }
          break;
        case _WindowFilterMode.folder:
          if (!_isFolderWindow(title, className)) {
            return false;
          }
          break;
        case _WindowFilterMode.all:
          break;
      }

      if (query.isEmpty) {
        return true;
      }
      return title.contains(query) || className.contains(query);
    }).toList();
  }

  bool _isTerminalWindow(String title, String className) {
    const terminalHints = [
      'cascadia_hosting_window_class',
      'consolewindowclass',
      'terminal',
      'powershell',
      'pwsh',
      'cmd',
      'git bash',
      'bash',
      'shell',
      'ubuntu',
      'wsl',
    ];
    return terminalHints.any(
      (hint) => title.contains(hint) || className.contains(hint),
    );
  }

  bool _isFolderWindow(String title, String className) {
    const folderHints = [
      'cabinetwclass',
      'explorewclass',
      '文件资源管理器',
      '资源管理器',
      'explorer',
      'folder',
      '目录',
      '文件夹',
      '此电脑',
    ];
    return folderHints.any(
      (hint) => title.contains(hint) || className.contains(hint),
    );
  }

  bool _isTerminalActive(int? hwnd, String title, String className) {
    if (hwnd == null ||
        !_isTerminalWindow(title.toLowerCase(), className.toLowerCase())) {
      return false;
    }
    final changedAt = _windowChangedAt[hwnd];
    if (changedAt == null) {
      return false;
    }
    return DateTime.now().difference(changedAt) <= _activeTerminalWindow;
  }

  bool _isCompletedUnread(int? hwnd) {
    if (hwnd == null) {
      return false;
    }
    return _completedUnreadHwnds.contains(hwnd);
  }

  Future<void> _markWindowViewed(int? hwnd) async {
    if (hwnd == null) {
      return;
    }
    _viewedHwnds.add(hwnd);
    var changed = false;
    changed = _completedUnreadHwnds.remove(hwnd) || changed;
    changed = _activeUnreadHwnds.remove(hwnd) || changed;
    changed = _windowChangedAt.remove(hwnd) != null || changed;
    if (!changed) return;
    if (mounted) {
      setState(() {});
    }
    await _persistUnreadState();
  }

  Future<void> _editWindowRemark(Map<String, dynamic> window) async {
    final hwnd = window['hwnd'] is num ? (window['hwnd'] as num).toInt() : null;
    if (hwnd == null || hwnd <= 0 || !mounted) {
      return;
    }
    final controller = TextEditingController(
      text: window['remark']?.toString() ?? '',
    );
    final nextRemark = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑备注'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '给这个窗口起一个备注名',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, ''),
            child: const Text('清空'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (nextRemark == null || !mounted) {
      return;
    }
    try {
      final savedRemark =
          await widget.controlService.setWindowRemark(hwnd, nextRemark);
      for (final source in [_windows, _filteredWindows]) {
        final index = source.indexWhere(
          (item) =>
              item is Map &&
              (item['hwnd'] is num) &&
              (item['hwnd'] as num).toInt() == hwnd,
        );
        if (index >= 0) {
          (source[index] as Map)['remark'] = savedRemark;
        }
      }
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存备注失败: $e')),
      );
    }
  }

  String _filterLabel(_WindowFilterMode mode) {
    switch (mode) {
      case _WindowFilterMode.all:
        return '全部';
      case _WindowFilterMode.terminal:
        return '终端';
      case _WindowFilterMode.folder:
        return '文件夹';
    }
  }

  Future<void> _setFilterMode(_WindowFilterMode mode) async {
    setState(() {
      _filterMode = mode;
      _filteredWindows = _applyFilter(
        _windows,
        _searchController.text,
        filterMode: _filterMode,
      );
    });
    await _persistFilterMode();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择窗口'),
        actions: [
          PopupMenuButton<_WindowFilterMode>(
            tooltip: '切换筛选',
            initialValue: _filterMode,
            onSelected: _setFilterMode,
            itemBuilder: (context) => const [
              PopupMenuItem(value: _WindowFilterMode.all, child: Text('全部')),
              PopupMenuItem(
                value: _WindowFilterMode.terminal,
                child: Text('终端'),
              ),
              PopupMenuItem(
                value: _WindowFilterMode.folder,
                child: Text('文件夹'),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Text(_filterLabel(_filterMode)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadingWindows ? null : _loadWindows,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索窗口',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onChanged: (value) {
                setState(() {
                  _filteredWindows = _applyFilter(
                    _windows,
                    value,
                    filterMode: _filterMode,
                  );
                });
              },
            ),
          ),
          Expanded(
            child: _loadingWindows
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _filteredWindows.length,
                    itemBuilder: (context, index) {
                      final window = Map<String, dynamic>.from(
                        _filteredWindows[index] as Map,
                      );
                      final title = window['title']?.toString() ?? '';
                      final className = window['class_name']?.toString() ?? '';
                      final hwnd = window['hwnd'] is num
                          ? (window['hwnd'] as num).toInt()
                          : null;
                      final isSelected =
                          hwnd != null && _selectedWindowHwnd == hwnd;
                      final isTerminalActive =
                          _isTerminalActive(hwnd, title, className);
                      final isCompletedUnread = _isCompletedUnread(hwnd);
                      final remark = window['remark']?.toString() ?? '';

                      Color? tileColor;
                      Color borderColor = Colors.transparent;
                      if (isTerminalActive) {
                        tileColor = const Color(0xFFFFF7E8);
                        borderColor = const Color(0xFFFFC857);
                      } else if (isCompletedUnread) {
                        tileColor = const Color(0xFFEAF8E6);
                        borderColor = const Color(0xFF8BCF7A);
                      }
                      if (isSelected) {
                        tileColor = isTerminalActive
                            ? const Color(0xFFFFF0CC)
                            : isCompletedUnread
                                ? const Color(0xFFDDF3D5)
                                : Colors.blue[50];
                        borderColor = isTerminalActive
                            ? const Color(0xFFFFB020)
                            : isCompletedUnread
                                ? const Color(0xFF67B35B)
                                : Colors.blue.shade200;
                      }

                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: tileColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: borderColor),
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            leading: Icon(
                              _getClassIcon(className),
                              color: isTerminalActive
                                  ? const Color(0xFFB86A00)
                                  : isCompletedUnread
                                      ? const Color(0xFF3F8F35)
                                      : Colors.blue,
                            ),
                            title: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (remark.isNotEmpty)
                                  Text(
                                    remark,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          color: isTerminalActive
                                              ? const Color(0xFF9C6500)
                                              : isCompletedUnread
                                                  ? const Color(0xFF4E8D45)
                                                  : Theme.of(context).hintColor,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                AnimatedDefaultTextStyle(
                                  duration: const Duration(milliseconds: 220),
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium!
                                      .copyWith(
                                        color: isTerminalActive
                                            ? const Color(0xFF7A4A00)
                                            : isCompletedUnread
                                                ? const Color(0xFF2F6D28)
                                                : Theme.of(context)
                                                    .colorScheme
                                                    .onSurface,
                                        fontWeight: isTerminalActive ||
                                                isCompletedUnread
                                            ? FontWeight.w600
                                            : FontWeight.w500,
                                      ),
                                  child: Text(
                                    title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            subtitle: Text(
                              className.isEmpty ? '未知窗口类型' : className,
                            ),
                            trailing: Wrap(
                              spacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                IconButton(
                                  tooltip: '编辑备注',
                                  icon: const Icon(Icons.edit_note),
                                  onPressed: () => _editWindowRemark(window),
                                ),
                                if (isSelected)
                                  Icon(
                                    Icons.check,
                                    color: isTerminalActive
                                        ? const Color(0xFFB86A00)
                                        : isCompletedUnread
                                            ? const Color(0xFF3F8F35)
                                            : Colors.blue,
                                  ),
                              ],
                            ),
                            onTap: () async {
                              final navigator = Navigator.of(context);
                              setState(() {
                                _selectedWindowHwnd = hwnd;
                              });
                              await _markWindowViewed(hwnd);
                              if (!mounted) return;
                              navigator.pop(window);
                            },
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  IconData _getClassIcon(String className) {
    if (className == 'POCKETWINDOW_DESKTOP') {
      return Icons.desktop_windows;
    }
    if (className.contains('Chrome') || className.contains('Browser')) {
      return Icons.public;
    }
    if (className.contains('Code') || className.contains('IDE')) {
      return Icons.code;
    }
    if (className.contains('Term') || className.contains('Console')) {
      return Icons.computer;
    }
    if (className.contains('Cabinet') || className.contains('Explore')) {
      return Icons.folder;
    }
    if (className.contains('Editor')) {
      return Icons.note;
    }
    return Icons.apps;
  }
}
