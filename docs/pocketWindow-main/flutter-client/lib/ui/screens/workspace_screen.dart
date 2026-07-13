import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pocketwindow/services/workspace_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WorkspaceScreen extends StatefulWidget {
  final String roomId;

  const WorkspaceScreen({
    super.key,
    required this.roomId,
  });

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  final Set<String> _selectedPaths = <String>{};
  final TextEditingController _programController = TextEditingController();
  final TextEditingController _argumentsController = TextEditingController();

  List<_SavedLauncher> _savedLaunchers = const [];
  List<String> _recentTerminalDirs = const [];
  String? _selectedTerminalId;
  bool _initialized = false;

  bool get _showLegacyWorkspaceActions => false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  @override
  void dispose() {
    _programController.dispose();
    _argumentsController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    if (_initialized || !mounted) return;
    _initialized = true;
    await _loadPreferences();
    if (!mounted) return;
    final workspace = context.read<WorkspaceService>();
    try {
      await workspace.initialize();
      if (!mounted) return;
      if (_selectedTerminalId == null && workspace.terminalProfiles.isNotEmpty) {
        setState(() {
          _selectedTerminalId = workspace.terminalProfiles.first.id;
        });
      }
    } catch (e) {
      await _showError(e);
    }
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final selectedTerminal = prefs.getString('workspace.selected_terminal');
    final launcherJson = prefs.getString('workspace.saved_launchers');
    final recentTerminalDirsJson =
        prefs.getString('workspace.recent_terminal_dirs');
    if (!mounted) return;
    setState(() {
      _selectedTerminalId = selectedTerminal;
      _savedLaunchers = _decodeLaunchers(launcherJson);
      _recentTerminalDirs = _decodeStringList(recentTerminalDirsJson);
    });
  }

  Future<void> _persistPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (_selectedTerminalId != null && _selectedTerminalId!.isNotEmpty) {
      await prefs.setString('workspace.selected_terminal', _selectedTerminalId!);
    }
    await prefs.setString(
      'workspace.saved_launchers',
      _encodeLaunchers(_savedLaunchers),
    );
    await prefs.setString(
      'workspace.recent_terminal_dirs',
      jsonEncode(_recentTerminalDirs),
    );
  }

  List<_SavedLauncher> _decodeLaunchers(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map((item) => _SavedLauncher.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  String _encodeLaunchers(List<_SavedLauncher> launchers) {
    return jsonEncode(launchers.map((item) => item.toJson()).toList(growable: false));
  }

  List<String> _decodeStringList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map((item) => item.toString())
          .where((item) => item.trim().isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> _launchTerminalInPath(
    WorkspaceService workspace,
    String? terminalId,
    String workingDir,
  ) async {
    if (terminalId == null || terminalId.isEmpty || workingDir.isEmpty) {
      return;
    }
    try {
      await workspace.launchTerminal(
        terminalId: terminalId,
        workingDir: workingDir,
      );
      setState(() {
        _recentTerminalDirs = [
          workingDir,
          ..._recentTerminalDirs.where((item) => item != workingDir),
        ].take(6).toList(growable: false);
      });
      await _persistPreferences();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('终端已在 $workingDir 打开'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      await _showError(e);
    }
  }

  Future<void> _saveCurrentLauncher(WorkspaceService workspace) async {
    final executable = _programController.text.trim();
    if (executable.isEmpty) return;
    final label = await _promptText(
      title: '保存启动器',
      initialValue: executable,
      hintText: '启动器名称',
    );
    if (label == null || label.trim().isEmpty) return;

    setState(() {
      _savedLaunchers = [
        ..._savedLaunchers.where((item) => item.name != label.trim()),
        _SavedLauncher(
          name: label.trim(),
          executable: executable,
          arguments: _argumentsController.text.trim(),
          workingDir: workspace.currentPath,
        ),
      ];
    });
    await _persistPreferences();
  }

  Future<String?> _promptText({
    required String title,
    required String initialValue,
    required String hintText,
  }) async {
    final controller = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hintText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _showError(Object error) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.toString())),
    );
  }

  Future<void> _openSelectedEntry(WorkspaceEntry entry) async {
    if (!entry.isDir) return;
    _selectedPaths.clear();
    try {
      await context.read<WorkspaceService>().browse(entry.path);
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      await _showError(e);
    }
  }

  Future<void> _downloadEntry(WorkspaceEntry entry) async {
    final workspace = context.read<WorkspaceService>();
    try {
      final result = await workspace.downloadFileToPhone(entry);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已保存到手机: ${result.fileName}'),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      await _showError(e);
    }
  }

  Future<void> _uploadFileToCurrentDirectory() async {
    final workspace = context.read<WorkspaceService>();
    if (workspace.currentPath.isEmpty) {
      await _showError('请先进入电脑上的目标目录');
      return;
    }
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: false,
      );
      final path = result?.files.single.path;
      if (path == null || path.isEmpty) return;
      await workspace.uploadFileToComputer(File(path));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已上传'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      await _showError(e);
    }
  }

  Future<void> _createFolderInCurrentDirectory() async {
    final workspace = context.read<WorkspaceService>();
    if (workspace.currentPath.isEmpty) {
      await _showError('请先进入电脑上的目标目录');
      return;
    }
    final controller = TextEditingController();
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('新建文件夹'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '文件夹名称',
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (value) => Navigator.pop(context, value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('新建'),
            ),
          ],
        ),
      );
      if (name == null || name.trim().isEmpty) return;
      await workspace.createFolder(name.trim());
      if (mounted) {
        setState(() {
          _selectedPaths.clear();
        });
      }
    } catch (e) {
      await _showError(e);
    } finally {
      controller.dispose();
    }
  }

  Future<void> _copyEntry(WorkspaceService workspace, WorkspaceEntry entry) async {
    try {
      await workspace.copyPaths([entry.path]);
      if (!mounted) return;
      setState(() {
        _selectedPaths
          ..clear()
          ..add(entry.path);
      });
    } catch (e) {
      await _showError(e);
    }
  }

  Future<void> _cutEntry(WorkspaceService workspace, WorkspaceEntry entry) async {
    try {
      await workspace.cutPaths([entry.path]);
      if (!mounted) return;
      setState(() {
        _selectedPaths
          ..clear()
          ..add(entry.path);
      });
    } catch (e) {
      await _showError(e);
    }
  }

  WorkspaceEntry? _singleSelectedFile(WorkspaceService workspace) {
    if (_selectedPaths.length != 1) {
      return null;
    }
    final selectedPath = _selectedPaths.first;
    for (final entry in workspace.entries) {
      if (entry.path == selectedPath && !entry.isDir) {
        return entry;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<WorkspaceService>(
      builder: (context, workspace, child) {
        final terminals = workspace.terminalProfiles;
        final selectedTerminalExists = terminals.any((item) => item.id == _selectedTerminalId);
        final terminalValue = selectedTerminalExists ? _selectedTerminalId : null;

        return PopScope(
          canPop: true,
          onPopInvokedWithResult: (didPop, result) {},
          child: Scaffold(
            appBar: AppBar(
              title: const Text('文件与启动'),
              actions: [
                TextButton(
                  onPressed: workspace.loadingDirectory
                      ? null
                      : () async {
                          try {
                            await workspace.refresh();
                          } catch (e) {
                            await _showError(e);
                          }
                        },
                  child: const Text('刷新'),
                ),
                TextButton(
                  onPressed: workspace.currentPath.isEmpty
                      ? null
                      : _createFolderInCurrentDirectory,
                  child: const Text('新建文件夹'),
                ),
              ],
            ),
            body: Column(
              children: [
                _buildTopPanel(workspace, terminals, terminalValue),
                Expanded(
                  child: workspace.loadingDirectory
                      ? const Center(child: CircularProgressIndicator())
                      : _buildFileListV2(workspace),
                ),
                _buildBottomPanel(workspace),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopPanel(
    WorkspaceService workspace,
    List<TerminalProfile> terminals,
    String? terminalValue,
  ) {
    final singleSelectedFile = _singleSelectedFile(workspace);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade50,
        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: FilledButton(
                  style: _fileActionButtonStyle(),
                  onPressed: terminals.isEmpty ||
                          terminalValue == null ||
                          workspace.currentPath.isEmpty
                      ? null
                      : () => _launchTerminalInPath(
                            workspace,
                            terminalValue,
                            workspace.currentPath,
                          ),
                  child: const Text('打开终端'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 4,
                child: DropdownButtonFormField<String>(
                  initialValue: terminalValue,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '终端类型',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: terminals
                      .map(
                        (item) => DropdownMenuItem<String>(
                          value: item.id,
                          child: Text(item.name, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: terminals.isEmpty
                      ? null
                      : (value) async {
                          setState(() {
                            _selectedTerminalId = value;
                          });
                          await _persistPreferences();
                        },
                ),
              ),
            ],
          ),
          if (_recentTerminalDirs.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _recentTerminalDirs.length,
                separatorBuilder: (context, index) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final path = _recentTerminalDirs[index];
                  return ActionChip(
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 190),
                      child: Text(
                        path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    onPressed: terminals.isEmpty || terminalValue == null
                        ? null
                        : () => _launchTerminalInPath(
                              workspace,
                              terminalValue,
                              path,
                            ),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  style: _fileActionButtonStyle(),
                  onPressed: workspace.uploadingFile ||
                          workspace.currentPath.isEmpty
                      ? null
                      : _uploadFileToCurrentDirectory,
                  child: FittedBox(
                    child: Text(
                      workspace.uploadingFile
                          ? '${(_safePercent(workspace.uploadProgress) * 100).toStringAsFixed(0)}%'
                          : '上传',
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonal(
                  style: _fileActionButtonStyle(),
                  onPressed: workspace.downloadingFile || singleSelectedFile == null
                      ? null
                      : () => _downloadEntry(singleSelectedFile),
                  child: FittedBox(
                    child: Text(
                      workspace.downloadingFile
                          ? '${(_safePercent(workspace.downloadProgress) * 100).toStringAsFixed(0)}%'
                          : '下载',
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  style: _fileActionButtonStyle(),
                  onPressed: _selectedPaths.isEmpty
                    ? null
                    : () async {
                        try {
                          await workspace.copyPaths(_selectedPaths.toList(growable: false));
                        } catch (e) {
                          await _showError(e);
                        }
                      },
                  child: const Text('复制', maxLines: 1, softWrap: false),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  style: _fileActionButtonStyle(),
                onPressed: workspace.currentPath.isEmpty
                    ? null
                    : () async {
                        try {
                          await workspace.pasteToCurrentDirectory();
                          if (mounted) {
                            setState(() {
                              _selectedPaths.clear();
                            });
                          }
                        } catch (e) {
                          await _showError(e);
                        }
                      },
                  child: Text(
                    workspace.clipboardCount > 0
                        ? '粘贴 ${workspace.clipboardCount}'
                        : '粘贴',
                    maxLines: 1,
                    softWrap: false,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  workspace.currentPath.isEmpty ? '我的电脑' : workspace.currentPath,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              if (workspace.parentPath != null)
                OutlinedButton(
                  onPressed: () async {
                    try {
                      await workspace.browse(workspace.parentPath!);
                      if (mounted) {
                        setState(() {
                          _selectedPaths.clear();
                        });
                      }
                    } catch (e) {
                      await _showError(e);
                    }
                  },
                  child: const Text('上一级'),
                ),
            ],
          ),
          if (_showLegacyWorkspaceActions) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: terminalValue,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '终端',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: terminals
                      .map(
                        (item) => DropdownMenuItem<String>(
                          value: item.id,
                          child: Text(item.name, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: terminals.isEmpty
                      ? null
                      : (value) async {
                          setState(() {
                            _selectedTerminalId = value;
                          });
                          await _persistPreferences();
                        },
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: terminals.isEmpty || terminalValue == null || workspace.currentPath.isEmpty
                    ? null
                    : () async {
                        try {
                          await workspace.launchTerminal(
                            terminalId: terminalValue,
                            workingDir: workspace.currentPath,
                          );
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('终端已在 ${workspace.currentPath} 打开'),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        } catch (e) {
                          await _showError(e);
                        }
                      },
                child: const Text('开终端'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _selectedPaths.isEmpty
                    ? null
                    : () async {
                        try {
                          await workspace.copyPaths(_selectedPaths.toList(growable: false));
                        } catch (e) {
                          await _showError(e);
                        }
                      },
                child: const Text('复制'),
              ),
              OutlinedButton(
                onPressed: _selectedPaths.isEmpty
                    ? null
                    : () async {
                        try {
                          await workspace.cutPaths(_selectedPaths.toList(growable: false));
                        } catch (e) {
                          await _showError(e);
                        }
                      },
                child: const Text('剪切'),
              ),
              OutlinedButton(
                onPressed: workspace.currentPath.isEmpty
                    ? null
                    : () async {
                        try {
                          await workspace.pasteToCurrentDirectory();
                          if (mounted) {
                            setState(() {
                              _selectedPaths.clear();
                            });
                          }
                        } catch (e) {
                          await _showError(e);
                        }
                      },
                child: Text(
                  workspace.clipboardCount > 0 ? '粘贴 ${workspace.clipboardCount}' : '粘贴',
                ),
              ),
              FilledButton.tonal(
                onPressed: workspace.downloadingFile || singleSelectedFile == null
                    ? null
                    : () => _downloadEntry(singleSelectedFile),
                child: Text(
                  workspace.downloadingFile
                      ? '${(_safePercent(workspace.downloadProgress) * 100).toStringAsFixed(0)}%'
                      : '下载',
                ),
              ),
            ],
          ),
          ],
        ],
      ),
    );
  }

  ButtonStyle _fileActionButtonStyle() {
    return ButtonStyle(
      minimumSize: WidgetStateProperty.all(const Size(0, 40)),
      padding: WidgetStateProperty.all(
        const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
      ),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      textStyle: WidgetStateProperty.all(
        const TextStyle(fontSize: 13, height: 1),
      ),
    );
  }

  // ignore: unused_element
  Widget _buildFileList(WorkspaceService workspace) {
    if (workspace.entries.isEmpty) {
      return const Center(child: Text('当前目录为空'));
    }

    return ListView.builder(
      itemCount: workspace.entries.length,
      itemBuilder: (context, index) {
        final entry = workspace.entries[index];
        final selected = _selectedPaths.contains(entry.path);
        return ListTile(
          dense: true,
          title: Text(
            entry.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: entry.isDir
              ? Text(entry.path, maxLines: 1, overflow: TextOverflow.ellipsis)
              : Text(_formatSize(entry.size)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!entry.isDir)
                TextButton(
                  onPressed: workspace.downloadingFile ? null : () => _downloadEntry(entry),
                  child: const Text('下载'),
                ),
              Checkbox(
                value: selected,
                onChanged: (value) {
                  setState(() {
                    if (value == true) {
                      _selectedPaths.add(entry.path);
                    } else {
                      _selectedPaths.remove(entry.path);
                    }
                  });
                },
              ),
            ],
          ),
          onTap: () async {
            if (entry.isDir) {
              await _openSelectedEntry(entry);
            } else {
              setState(() {
                if (selected) {
                  _selectedPaths.remove(entry.path);
                } else {
                  _selectedPaths.add(entry.path);
                }
              });
            }
          },
          onLongPress: () {
            setState(() {
              if (selected) {
                _selectedPaths.remove(entry.path);
              } else {
                _selectedPaths.add(entry.path);
              }
            });
          },
        );
      },
    );
  }

  Widget _buildFileListV2(WorkspaceService workspace) {
    if (workspace.entries.isEmpty) {
      return const Center(child: Text('当前目录为空'));
    }

    return ListView.separated(
      itemCount: workspace.entries.length,
      separatorBuilder: (context, index) => Divider(
        height: 1,
        color: Colors.grey.shade200,
      ),
      itemBuilder: (context, index) {
        final entry = workspace.entries[index];
        final selected = _selectedPaths.contains(entry.path);
        return _WorkspaceEntryTile(
          entry: entry,
          selected: selected,
          downloading: workspace.downloadingFile,
          terminalEnabled: _selectedTerminalId != null,
          subtitle: _entrySubtitle(entry),
          onTap: () async {
            if (entry.isDir) {
              await _openSelectedEntry(entry);
            } else {
              _toggleSelection(entry.path);
            }
          },
          onToggleSelected: () => _toggleSelection(entry.path),
          onDownload: entry.isDir || workspace.downloadingFile
              ? null
              : () => _downloadEntry(entry),
          onCopy: () => _copyEntry(workspace, entry),
          onCut: () => _cutEntry(workspace, entry),
          onOpenTerminal: entry.isDir
              ? () => _launchTerminalInPath(
                    workspace,
                    _selectedTerminalId,
                    entry.path,
                  )
              : null,
        );
      },
    );
  }

  void _toggleSelection(String path) {
    setState(() {
      if (_selectedPaths.contains(path)) {
        _selectedPaths.remove(path);
      } else {
        _selectedPaths.add(path);
      }
    });
  }

  String _entrySubtitle(WorkspaceEntry entry) {
    final modified = _formatModifiedAt(entry.modifiedAt);
    if (entry.isDir) {
      return modified == null ? entry.path : '$modified  ·  ${entry.path}';
    }
    final size = _formatSize(entry.size);
    return modified == null ? size : '$size  ·  $modified';
  }

  Widget _buildBottomPanel(WorkspaceService workspace) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _programController,
                      decoration: const InputDecoration(
                        labelText: '程序路径或命令',
                        hintText: '例如：Code.exe',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _argumentsController,
                      decoration: const InputDecoration(
                        labelText: '参数',
                        hintText: '例如：.',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  FilledButton(
                    onPressed: workspace.currentPath.isEmpty
                        ? null
                        : () async {
                            try {
                              await workspace.launchProgram(
                                executable: _programController.text,
                                arguments: _argumentsController.text,
                                workingDir: workspace.currentPath,
                              );
                            } catch (e) {
                              await _showError(e);
                            }
                          },
                    child: const Text('启动程序'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: workspace.currentPath.isEmpty
                        ? null
                        : () async {
                            await _saveCurrentLauncher(workspace);
                          },
                    child: const Text('保存启动器'),
                  ),
                ],
              ),
              if (_savedLaunchers.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _savedLaunchers
                      .map(
                        (item) => InputChip(
                          label: Text(item.name),
                          onPressed: () async {
                            _programController.text = item.executable;
                            _argumentsController.text = item.arguments;
                            try {
                              await workspace.launchProgram(
                                executable: item.executable,
                                arguments: item.arguments,
                                workingDir: item.workingDir.isEmpty ? workspace.currentPath : item.workingDir,
                              );
                            } catch (e) {
                              await _showError(e);
                            }
                          },
                          onDeleted: () async {
                            setState(() {
                              _savedLaunchers = _savedLaunchers
                                  .where((entry) => entry.name != item.name)
                                  .toList(growable: false);
                            });
                            await _persistPreferences();
                          },
                        ),
                      )
                      .toList(growable: false),
                ),
              ],
              const SizedBox(height: 8),
              if (workspace.downloadingFile)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: LinearProgressIndicator(value: _safeProgress(workspace.downloadProgress)),
                ),
              if (workspace.uploadingFile)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: LinearProgressIndicator(value: _safeProgress(workspace.uploadProgress)),
                ),
              Text(
                workspace.statusMessage,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            ],
          ),
        ),
      ),
    );
  }

  double _safeProgress(double value) {
    if (value <= 0) return 0;
    if (value >= 1) return 1;
    return value;
  }

  double _safePercent(double value) => _safeProgress(value);

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  String? _formatModifiedAt(int? seconds) {
    if (seconds == null || seconds <= 0) return null;
    final time = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    final now = DateTime.now();
    final sameYear = time.year == now.year;
    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    if (sameYear) {
      return '$month-$day $hour:$minute';
    }
    return '${time.year}-$month-$day $hour:$minute';
  }
}

class _WorkspaceEntryTile extends StatelessWidget {
  final WorkspaceEntry entry;
  final String subtitle;
  final bool selected;
  final bool downloading;
  final bool terminalEnabled;
  final VoidCallback onTap;
  final VoidCallback onToggleSelected;
  final VoidCallback? onDownload;
  final VoidCallback onCopy;
  final VoidCallback onCut;
  final VoidCallback? onOpenTerminal;

  const _WorkspaceEntryTile({
    required this.entry,
    required this.subtitle,
    required this.selected,
    required this.downloading,
    required this.terminalEnabled,
    required this.onTap,
    required this.onToggleSelected,
    required this.onDownload,
    required this.onCopy,
    required this.onCut,
    required this.onOpenTerminal,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onToggleSelected,
        child: SizedBox(
          height: 66,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.grey.shade700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!entry.isDir)
                  TextButton(
                    onPressed: onDownload,
                    child: Text(downloading ? '...' : '下载'),
                  ),
                Checkbox(
                  value: selected,
                  onChanged: (_) => onToggleSelected(),
                ),
                PopupMenuButton<String>(
                  tooltip: '更多',
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    child: Text('更多'),
                  ),
                  onSelected: (value) {
                    switch (value) {
                      case 'terminal':
                        onOpenTerminal?.call();
                        break;
                      case 'download':
                        onDownload?.call();
                        break;
                      case 'copy':
                        onCopy();
                        break;
                      case 'cut':
                        onCut();
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    if (entry.isDir)
                      PopupMenuItem<String>(
                        value: 'terminal',
                        enabled: terminalEnabled && onOpenTerminal != null,
                        child: const Text('在此打开终端'),
                      ),
                    if (!entry.isDir)
                      PopupMenuItem<String>(
                        value: 'download',
                        enabled: onDownload != null,
                        child: const Text('下载'),
                      ),
                    const PopupMenuItem<String>(
                      value: 'copy',
                      child: Text('复制'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'cut',
                      child: Text('剪切'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SavedLauncher {
  final String name;
  final String executable;
  final String arguments;
  final String workingDir;

  const _SavedLauncher({
    required this.name,
    required this.executable,
    required this.arguments,
    required this.workingDir,
  });

  factory _SavedLauncher.fromJson(Map<String, dynamic> json) {
    return _SavedLauncher(
      name: json['name']?.toString() ?? '',
      executable: json['executable']?.toString() ?? '',
      arguments: json['arguments']?.toString() ?? '',
      workingDir: json['working_dir']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'executable': executable,
        'arguments': arguments,
        'working_dir': workingDir,
      };
}
