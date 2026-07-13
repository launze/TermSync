import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pocketwindow/services/signaling_service.dart';

class WorkspaceEntry {
  final String name;
  final String path;
  final bool isDir;
  final int size;
  final int? modifiedAt;

  const WorkspaceEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.modifiedAt,
  });

  factory WorkspaceEntry.fromJson(Map<String, dynamic> json) {
    return WorkspaceEntry(
      name: json['name']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      isDir: json['is_dir'] == true,
      size: json['size'] is num ? (json['size'] as num).toInt() : 0,
      modifiedAt: json['modified_at'] is num
          ? (json['modified_at'] as num).toInt()
          : null,
    );
  }
}

class TerminalProfile {
  final String id;
  final String name;
  final String executable;
  final String description;

  const TerminalProfile({
    required this.id,
    required this.name,
    required this.executable,
    required this.description,
  });

  factory TerminalProfile.fromJson(Map<String, dynamic> json) {
    return TerminalProfile(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      executable: json['executable']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
    );
  }
}

class FileDownloadResult {
  final String fileName;
  final String savedPath;
  final int bytes;

  const FileDownloadResult({
    required this.fileName,
    required this.savedPath,
    required this.bytes,
  });
}

class WorkspaceService with ChangeNotifier {
  WorkspaceService();

  SignalingService? _signalingService;
  String _lanFileServerUrl = '';
  Function(Map<String, dynamic>)? _responseBridge;
  Function(Map<String, dynamic>)? _originalControlResponseCallback;
  Completer<void>? _reconnectCompleter;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};

  String _currentPath = '';
  String? _parentPath;
  List<WorkspaceEntry> _entries = const [];
  List<TerminalProfile> _terminalProfiles = const [];
  bool _loadingDirectory = false;
  bool _loadingTerminals = false;
  bool _downloadingFile = false;
  bool _uploadingFile = false;
  double _downloadProgress = 0;
  double _uploadProgress = 0;
  String _statusMessage = '未连接';
  String? _clipboardMode;
  int _clipboardCount = 0;

  String get currentPath => _currentPath;
  String? get parentPath => _parentPath;
  List<WorkspaceEntry> get entries => _entries;
  List<TerminalProfile> get terminalProfiles => _terminalProfiles;
  bool get loadingDirectory => _loadingDirectory;
  bool get loadingTerminals => _loadingTerminals;
  bool get downloadingFile => _downloadingFile;
  bool get uploadingFile => _uploadingFile;
  double get downloadProgress => _downloadProgress;
  double get uploadProgress => _uploadProgress;
  String get statusMessage => _statusMessage;
  String? get clipboardMode => _clipboardMode;
  int get clipboardCount => _clipboardCount;

  void setSignalingService(SignalingService service) {
    _signalingService = service;
    _originalControlResponseCallback = service.onControlResponse;
    _responseBridge = (data) {
      _handleControlResponse(data);
      _originalControlResponseCallback?.call(data);
    };
    service.onControlResponse = _responseBridge;
  }

  void setLanFileServerUrl(String value) {
    _lanFileServerUrl = value.trim();
  }

  Future<void> initialize({String initialPath = ''}) async {
    await Future.wait([
      browse(initialPath),
      loadTerminalProfiles(),
    ]);
  }

  Future<Map<String, dynamic>> _sendCommand(
      String command, Map<String, dynamic> params,
      {Duration timeout = const Duration(seconds: 12)}) async {
    final signaling = await _ensureControlConnected();
    if (signaling == null) {
      throw Exception('当前未连接到电脑');
    }

    if (_pending.containsKey(command)) {
      throw Exception('命令仍在执行中: $command');
    }

    final completer = Completer<Map<String, dynamic>>();
    _pending[command] = completer;
    var activeSignaling = signaling;
    if (!activeSignaling.sendControl(command, params)) {
      _pending.remove(command);
      final reconnected = await _reconnectControl();
      if (reconnected == null) {
        throw Exception('当前未连接到电脑');
      }
      activeSignaling = reconnected;
      _pending[command] = completer;
      if (!activeSignaling.sendControl(command, params)) {
        _pending.remove(command);
        throw Exception('当前未连接到电脑');
      }
    }

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(command);
      throw Exception('请求超时: $command');
    }
  }

  Future<SignalingService?> _ensureControlConnected() async {
    final signaling = _signalingService;
    if (signaling == null) return null;
    if (signaling.isConnected) return signaling;
    return _reconnectControl();
  }

  Future<SignalingService?> _reconnectControl() async {
    final signaling = _signalingService;
    if (signaling == null) return null;

    final existing = _reconnectCompleter;
    if (existing != null && !existing.isCompleted) {
      await existing.future;
      return signaling.isConnected ? signaling : null;
    }

    final completer = Completer<void>();
    _reconnectCompleter = completer;
    _statusMessage = '连接已断开，正在重新连接电脑...';
    notifyListeners();
    try {
      signaling.disconnect();
      await signaling.connect().timeout(const Duration(seconds: 8));
      _statusMessage = '已重新连接电脑';
      completer.complete();
      notifyListeners();
      return signaling;
    } catch (e) {
      _statusMessage = '重新连接失败: $e';
      if (!completer.isCompleted) completer.complete();
      notifyListeners();
      return null;
    } finally {
      if (identical(_reconnectCompleter, completer)) {
        _reconnectCompleter = null;
      }
    }
  }

  Future<void> browse(String path) async {
    _loadingDirectory = true;
    _statusMessage = '正在读取目录...';
    notifyListeners();

    try {
      final response = await _sendCommand('list_directory', {'path': path});
      final list = response['entries'];
      _currentPath = response['path']?.toString() ?? '';
      final parent = response['parent']?.toString();
      _parentPath = parent == null || (parent.isEmpty && _currentPath.isEmpty)
          ? null
          : parent;
      _entries = list is List
          ? list
              .map((item) => WorkspaceEntry.fromJson(
                  Map<String, dynamic>.from(item as Map)))
              .toList(growable: false)
          : const [];
      _statusMessage = _currentPath.isEmpty ? '已加载磁盘列表' : '当前目录: $_currentPath';
    } catch (e) {
      _statusMessage = '读取目录失败: $e';
      rethrow;
    } finally {
      _loadingDirectory = false;
      notifyListeners();
    }
  }

  Future<void> refresh() => browse(_currentPath);

  Future<void> loadTerminalProfiles() async {
    _loadingTerminals = true;
    notifyListeners();
    try {
      final response = await _sendCommand('get_terminal_profiles', {});
      final profiles = response['profiles'];
      _terminalProfiles = profiles is List
          ? profiles
              .map((item) => TerminalProfile.fromJson(
                  Map<String, dynamic>.from(item as Map)))
              .toList(growable: false)
          : const [];
      _statusMessage = _terminalProfiles.isEmpty
          ? '没有检测到可用终端'
          : '已检测到 ${_terminalProfiles.length} 个终端';
    } catch (e) {
      _statusMessage = '检测终端失败: $e';
      rethrow;
    } finally {
      _loadingTerminals = false;
      notifyListeners();
    }
  }

  Future<void> copyPaths(List<String> paths) => _setClipboard('copy', paths);

  Future<void> cutPaths(List<String> paths) => _setClipboard('cut', paths);

  Future<void> _setClipboard(String mode, List<String> paths) async {
    final response = await _sendCommand('set_file_clipboard', {
      'mode': mode,
      'paths': paths,
    });
    _clipboardMode = response['clipboard_mode']?.toString();
    _clipboardCount = response['clipboard_count'] is num
        ? (response['clipboard_count'] as num).toInt()
        : 0;
    _statusMessage = response['message']?.toString() ?? '剪贴板已更新';
    notifyListeners();
  }

  Future<void> pasteToCurrentDirectory() async {
    final response = await _sendCommand('paste_file_clipboard', {
      'destination': _currentPath,
    });
    _clipboardMode = response['clipboard_mode']?.toString();
    _clipboardCount = response['clipboard_count'] is num
        ? (response['clipboard_count'] as num).toInt()
        : 0;
    _statusMessage = response['message']?.toString() ?? '粘贴完成';
    await refresh();
  }

  Future<void> createFolder(String name) async {
    final response = await _sendCommand('create_folder', {
      'parent': _currentPath,
      'name': name,
    });
    _statusMessage = response['message']?.toString() ?? '已新建文件夹';
    await refresh();
  }

  Future<void> launchTerminal({
    required String terminalId,
    required String workingDir,
  }) async {
    final response = await _sendCommand('launch_terminal', {
      'terminal_id': terminalId,
      'working_dir': workingDir,
    });
    _statusMessage = response['message']?.toString() ?? '终端已启动';
    notifyListeners();
  }

  Future<void> executeCommand({
    required String commandText,
    required bool autoEnter,
  }) async {
    final response = await _sendCommand('execute_command', {
      'command_text': commandText,
      'auto_enter': autoEnter,
    });
    _statusMessage = response['message']?.toString() ?? '命令已发送';
    notifyListeners();
  }

  Future<void> launchProgram({
    required String executable,
    required String arguments,
    required String workingDir,
  }) async {
    final response = await _sendCommand('launch_program', {
      'executable': executable,
      'arguments': arguments,
      'working_dir': workingDir,
    });
    _statusMessage = response['message']?.toString() ?? '程序已启动';
    notifyListeners();
  }

  Future<FileDownloadResult> downloadFileToPhone(WorkspaceEntry entry) async {
    if (entry.isDir) {
      throw Exception('暂不支持直接传输文件夹');
    }

    final signaling = _signalingService;
    if (signaling == null) {
      throw Exception('当前未连接到电脑');
    }
    final directDownloadUri = _directFileDownloadUri(signaling, entry.path);
    if (directDownloadUri == null && !signaling.isConnected) {
      throw Exception('当前未连接到电脑');
    }

    _downloadingFile = true;
    _downloadProgress = 0;
    _statusMessage = '正在准备传输 ${entry.name}...';
    notifyListeners();

    try {
      final String fileName;
      final int fileSize;
      final Uri uri;
      if (directDownloadUri != null) {
        fileName = entry.name;
        fileSize = entry.size;
        uri = directDownloadUri;
        _statusMessage = '正在通过局域网直连下载 ${entry.name}...';
        notifyListeners();
      } else {
        final response = await _sendCommand('prepare_file_download', {
          'path': entry.path,
          'client_id': signaling.clientId,
        });

        final absoluteDownloadUrl = response['download_url']?.toString() ?? '';
        final relativeDownloadUrl =
            response['relative_download_url']?.toString() ?? '';
        fileName = response['file_name']?.toString() ?? entry.name;
        fileSize = response['file_size'] is num
            ? (response['file_size'] as num).toInt()
            : entry.size;
        if (absoluteDownloadUrl.isEmpty && relativeDownloadUrl.isEmpty) {
          throw Exception('服务端未返回下载地址');
        }
        uri = _resolveDownloadUri(
          signaling.serverUrl,
          absoluteDownloadUrl: absoluteDownloadUrl,
          relativeDownloadUrl: relativeDownloadUrl,
        );
      }
      final outputFile = await _resolveDownloadTarget(fileName);
      await outputFile.parent.create(recursive: true);
      if (outputFile.existsSync()) {
        outputFile.deleteSync();
      }

      final request = http.Request('GET', uri);
      final streamed = await request.send();
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        final body = await streamed.stream.bytesToString();
        throw Exception('下载失败: ${streamed.statusCode} ${body.trim()}');
      }

      final sink = outputFile.openWrite();
      var received = 0;
      final total = streamed.contentLength ?? fileSize;
      await for (final chunk in streamed.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          _downloadProgress = received / total;
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();

      _downloadProgress = 1;
      _statusMessage = '已保存到手机: ${outputFile.path}';
      notifyListeners();
      return FileDownloadResult(
        fileName: fileName,
        savedPath: outputFile.path,
        bytes: received,
      );
    } catch (e) {
      _statusMessage = '下载失败: $e';
      notifyListeners();
      rethrow;
    } finally {
      _downloadingFile = false;
      notifyListeners();
    }
  }

  Future<void> uploadFileToComputer(File file) async {
    final signaling = _signalingService;
    if (signaling == null) {
      throw Exception('当前未连接到电脑');
    }
    if (_currentPath.isEmpty) {
      throw Exception('请先进入一个电脑目录');
    }
    final fileName = file.uri.pathSegments.isNotEmpty
        ? Uri.decodeComponent(file.uri.pathSegments.last)
        : 'upload.bin';
    final fileSize = await file.length();
    if (fileSize <= 0) {
      throw Exception('文件为空，无法上传');
    }
    final directUploadUri = _directFileUploadUri(
      signaling,
      destination: _currentPath,
      fileName: fileName,
      fileSize: fileSize,
    );
    _uploadingFile = true;
    _uploadProgress = 0;
    _statusMessage = '正在上传到电脑: $fileName';
    notifyListeners();

    try {
      if (directUploadUri != null) {
        try {
          final response = await _uploadFileViaHttp(
            file,
            directUploadUri,
            fileSize,
            progressCeiling: 1.0,
          );
          final responseBody = await response.stream.bytesToString();
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw Exception(
                '局域网上传失败: ${response.statusCode} ${responseBody.trim()}');
          }
          _uploadProgress = 1;
          _statusMessage = '已通过局域网直传到电脑';
          await _refreshIfControlConnected();
          return;
        } catch (e) {
          if (!signaling.isConnected) {
            throw Exception('局域网直传失败，且当前未连接到电脑: $e');
          }
          _uploadProgress = 0;
          _statusMessage = '局域网直传失败，改用服务器中转...';
          notifyListeners();
        }
      } else if (!signaling.isConnected) {
        throw Exception('当前未连接到电脑');
      }

      final uploadUri =
          _httpApiUri(signaling.serverUrl, '/api/file-transfer/upload').replace(
        queryParameters: {
          'device_id': signaling.deviceId,
          'client_id': signaling.clientId,
          'file_name': fileName,
          'file_size': fileSize.toString(),
        },
      );
      final response = await _uploadFileViaHttp(
        file,
        uploadUri,
        fileSize,
        progressCeiling: 0.98,
      );
      final responseBody = await response.stream.bytesToString();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('上传失败: ${response.statusCode} ${responseBody.trim()}');
      }
      final payload = responseBody.trim().isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(responseBody) as Map);
      _statusMessage = '文件已上传到服务器，正在等待电脑保存...';
      notifyListeners();
      final saveResponse = await _sendCommand('save_uploaded_file', {
        'destination': _currentPath,
        'file_name': payload['file_name']?.toString() ?? fileName,
        'download_url': payload['download_url']?.toString() ?? '',
        'relative_download_url':
            payload['relative_download_url']?.toString() ?? '',
      }, timeout: const Duration(minutes: 10));
      _uploadProgress = 1;
      _statusMessage = saveResponse['message']?.toString() ?? '已上传到电脑';
      await refresh();
    } catch (e) {
      _statusMessage = '上传失败: $e';
      notifyListeners();
      rethrow;
    } finally {
      _uploadingFile = false;
      notifyListeners();
    }
  }

  Future<void> _refreshIfControlConnected() async {
    final signaling = _signalingService;
    if (signaling == null || !signaling.isConnected) return;
    try {
      await refresh();
    } catch (_) {
      // File transfer already succeeded; directory refresh should not turn it
      // into a failed upload when the control channel is temporarily offline.
    }
  }

  Future<http.StreamedResponse> _uploadFileViaHttp(
    File file,
    Uri uploadUri,
    int fileSize, {
    required double progressCeiling,
  }) async {
    final request = http.StreamedRequest('POST', uploadUri);
    request.headers['Content-Type'] = 'application/octet-stream';
    request.contentLength = fileSize;
    var sent = 0;
    final responseFuture = request.send();
    await for (final chunk in file.openRead()) {
      request.sink.add(chunk);
      sent += chunk.length;
      _uploadProgress = (sent / fileSize).clamp(0.01, progressCeiling);
      notifyListeners();
    }
    await request.sink.close();
    return responseFuture;
  }

  Uri? _directFileDownloadUri(SignalingService signaling, String remotePath) {
    final wsUri = _lanFileServerUri(signaling);
    if (wsUri == null || wsUri.host.isEmpty) return null;
    return wsUri.replace(
      scheme: 'http',
      path: '/file/download',
      queryParameters: {
        'device_id': signaling.deviceId,
        'client_id': signaling.clientId,
        'path': remotePath,
      },
    );
  }

  Uri? _directFileUploadUri(
    SignalingService signaling, {
    required String destination,
    required String fileName,
    required int fileSize,
  }) {
    final wsUri = _lanFileServerUri(signaling);
    if (wsUri == null || wsUri.host.isEmpty) return null;
    return wsUri.replace(
      scheme: 'http',
      path: '/file/upload',
      queryParameters: {
        'device_id': signaling.deviceId,
        'client_id': signaling.clientId,
        'destination': destination,
        'file_name': fileName,
        'file_size': fileSize.toString(),
      },
    );
  }

  Uri? _lanFileServerUri(SignalingService signaling) {
    final url = _lanFileServerUrl.isNotEmpty
        ? _lanFileServerUrl
        : signaling.isLanDirectConnection
            ? signaling.serverUrl
            : '';
    if (url.isEmpty) return null;
    return Uri.tryParse(_normalizeWsUrl(url));
  }

  Future<File> _resolveDownloadTarget(String fileName) async {
    final normalizedFileName =
        fileName.trim().isEmpty ? 'download.bin' : fileName.trim();
    Directory? baseDir;

    if (!kIsWeb) {
      if (Platform.isAndroid) {
        final downloadDir = Directory('/storage/emulated/0/Download');
        if (await downloadDir.exists()) {
          baseDir = downloadDir;
        }
      }
      baseDir ??= await getDownloadsDirectory();
      baseDir ??= await getApplicationDocumentsDirectory();
    } else {
      throw Exception('当前平台不支持保存到本地文件系统');
    }

    final candidate =
        File('${baseDir.path}${Platform.pathSeparator}$normalizedFileName');
    if (!await candidate.exists()) {
      return candidate;
    }

    final extensionIndex = normalizedFileName.lastIndexOf('.');
    final hasExtension = extensionIndex > 0;
    final prefix = hasExtension
        ? normalizedFileName.substring(0, extensionIndex)
        : normalizedFileName;
    final suffix =
        hasExtension ? normalizedFileName.substring(extensionIndex) : '';
    for (var i = 1; i <= 999; i += 1) {
      final next =
          File('${baseDir.path}${Platform.pathSeparator}$prefix ($i)$suffix');
      if (!await next.exists()) {
        return next;
      }
    }
    throw Exception('无法为下载文件分配保存路径');
  }

  Uri _resolveDownloadUri(
    String serverUrl, {
    required String absoluteDownloadUrl,
    required String relativeDownloadUrl,
  }) {
    final absolute = absoluteDownloadUrl.trim();
    if (absolute.isNotEmpty) {
      final parsed = Uri.tryParse(absolute);
      if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
        return parsed;
      }
    }

    final relative = relativeDownloadUrl.trim();
    if (relative.isEmpty) {
      throw Exception('下载地址为空');
    }

    final wsUri = Uri.parse(_normalizeWsUrl(serverUrl));
    final scheme = wsUri.scheme == 'wss' ? 'https' : 'http';
    final baseUri = wsUri.replace(scheme: scheme, path: '/', query: '');
    return baseUri.resolve(relative);
  }

  Uri _httpApiUri(String serverUrl, String path) {
    final wsUri = Uri.parse(_normalizeWsUrl(serverUrl));
    final scheme = wsUri.scheme == 'wss' ? 'https' : 'http';
    return wsUri.replace(scheme: scheme, path: path, query: '');
  }

  String _normalizeWsUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Server URL is required');
    }
    final withScheme =
        trimmed.startsWith('ws://') || trimmed.startsWith('wss://')
            ? trimmed
            : 'ws://$trimmed';
    final uri = Uri.parse(withScheme);
    if (uri.path.isEmpty || uri.path == '/') {
      return uri.replace(path: '/ws').toString();
    }
    return uri.toString();
  }

  void _handleControlResponse(Map<String, dynamic> data) {
    final command = data['command']?.toString();
    if (command == null || !_pending.containsKey(command)) {
      return;
    }

    final completer = _pending.remove(command)!;
    final success = data['success'] == true;
    if (success) {
      completer.complete(data);
    } else {
      completer.completeError(
        Exception(data['message']?.toString() ?? '$command 执行失败'),
      );
    }
  }

  @override
  void dispose() {
    final signaling = _signalingService;
    if (signaling != null &&
        identical(signaling.onControlResponse, _responseBridge)) {
      signaling.onControlResponse = _originalControlResponseCallback;
    }
    super.dispose();
  }
}
