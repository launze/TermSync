import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pocketwindow/services/app_update_service.dart';
import 'package:pocketwindow/services/control_service.dart';
import 'package:pocketwindow/services/network_route_resolver.dart';
import 'package:pocketwindow/services/pairing_service.dart';
import 'package:pocketwindow/services/public_direct_client.dart';
import 'package:pocketwindow/services/server_endpoint_resolver.dart';
import 'package:pocketwindow/services/signaling_endpoints_store.dart';
import 'package:pocketwindow/services/signaling_service.dart';
import 'package:pocketwindow/services/terminal_service.dart';
import 'package:pocketwindow/services/workspace_service.dart';
import 'package:pocketwindow/ui/screens/control_screen.dart';
import 'package:pocketwindow/ui/screens/terminal_screen.dart';
import 'package:pocketwindow/ui/screens/workspace_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _TrustedDevicesResult {
  final String serverUrl;
  final List<Map<String, dynamic>> devices;

  const _TrustedDevicesResult({
    required this.serverUrl,
    required this.devices,
  });
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _selectedDeviceIdKey = 'home.selected_device_id';
  static const _pendingInstallerPathKey = 'updates.pending_installer_path';

  final PairingService _pairingService = PairingService();
  final AppUpdateService _appUpdateService = const AppUpdateService();

  bool _loading = false;
  bool _checkingUpdate = false;
  bool _resumingInstaller = false;
  bool _downloadingUpdate = false;
  double? _updateDownloadProgress;
  String? _error;
  List<Map<String, dynamic>> _trustedDevices = const [];
  Map<String, dynamic>? _selectedDevice;
  List<SignalingEndpoint> _signalingEndpoints = const [];

  /// First enabled endpoint URL (used by ControlScreen as the "primary"
  /// connection target). Empty string when nothing is configured yet.
  String get _localServerUrl {
    for (final entry in _signalingEndpoints) {
      if (entry.enabled && entry.url.isNotEmpty) return entry.url;
    }
    return '';
  }

  /// Second enabled endpoint URL if available, else the primary, else empty.
  String get _fallbackServerUrl {
    String? second;
    var foundFirst = false;
    for (final entry in _signalingEndpoints) {
      if (!entry.enabled || entry.url.isEmpty) continue;
      if (!foundFirst) {
        foundFirst = true;
        continue;
      }
      second = entry.url;
      break;
    }
    return second ?? _localServerUrl;
  }

  bool get _busyUpdating =>
      _checkingUpdate || _resumingInstaller || _downloadingUpdate;

  bool get _hasSignalingEndpoints =>
      _signalingEndpoints.any((e) => e.enabled && e.url.isNotEmpty);

  bool _isDeviceOnline(Map<String, dynamic>? device) {
    return device?['online'] == true;
  }

  bool _needsPairing(Map<String, dynamic>? device) {
    return device?['needsPairing'] == true;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadConnectionSettings();
      await _refreshTrustedDevices();
      await _checkForAppUpdate();
      await _resumePendingInstallerIfAllowed();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resumePendingInstallerIfAllowed();
      _checkForInPlaceUpgradeAndRestart();
    }
  }

  Future<void> _checkForInPlaceUpgradeAndRestart() async {
    if (!Platform.isAndroid) return;
    try {
      final liveCode = await AppUpdateService().liveVersionCode();
      if (liveCode == null || liveCode < 0) return;
      final info = await PackageInfo.fromPlatform();
      final runningBuild = int.tryParse(info.buildNumber.trim()) ?? 0;
      if (liveCode > runningBuild) {
        SystemNavigator.pop();
      }
    } catch (_) {}
  }

  Future<ResolvedServerEndpoint> _resolveServerEndpoint() {
    return ServerEndpointResolver.resolveBestEndpoint(
      preferred: _signalingEndpoints,
    );
  }

  Future<bool> _checkIsOnWifi() async {
    final result = await Connectivity().checkConnectivity();
    return result.contains(ConnectivityResult.wifi);
  }

  Future<void> _loadConnectionSettings() async {
    final endpoints = await SignalingEndpointsStore.load();
    if (!mounted) return;
    setState(() {
      _signalingEndpoints = endpoints;
    });
  }

  Future<void> _saveSignalingEndpoints(List<SignalingEndpoint> next) async {
    await SignalingEndpointsStore.save(next);
    if (!mounted) return;
    setState(() {
      _signalingEndpoints = next;
      _error = null;
    });
  }

  Future<void> _openConnectionSettings() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _ConnectionSettingsScreen(
          initialEndpoints: _signalingEndpoints,
          onCommit: _saveSignalingEndpoints,
        ),
      ),
    );
    if (changed == true && mounted) {
      setState(() {
        _error = null;
      });
      await _refreshTrustedDevices();
    }
  }

  String _lanDirectServerUrl(
    String primaryIp,
    List<String> candidateIps,
    int port,
  ) {
    if (port <= 0) return '';
    final candidates = <String>[
      primaryIp,
      ...candidateIps,
    ];
    for (final item in candidates) {
      final value = item.trim();
      if (value.isNotEmpty) {
        return 'ws://$value:$port';
      }
    }
    return '';
  }

  Future<void> _refreshTrustedDevices() async {
    if (!_hasSignalingEndpoints) {
      setState(() {
        _trustedDevices = const [];
        _selectedDevice = null;
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      String serverUrl;
      final isOnWifi = await _checkIsOnWifi();
      if (isOnWifi) {
        final resolvedEndpoint = await _resolveServerEndpoint();
        serverUrl = resolvedEndpoint.serverUrl;
      } else {
        final publicDirectAttempt = await PublicDirectClient.tryPrepare(
          expectedDeviceId: '',
        );
        if (publicDirectAttempt != null) {
          serverUrl = 'http://${publicDirectAttempt.config.host}:${publicDirectAttempt.config.port}';
        } else {
          final resolvedEndpoint = await _resolveServerEndpoint();
          serverUrl = resolvedEndpoint.serverUrl;
        }
      }
      final trustedDevicesResult = await _fetchTrustedDevicesWithLocalRetry(
        serverUrl,
      );
      final devices = trustedDevicesResult.devices.isNotEmpty
          ? trustedDevicesResult.devices
          : await _fetchVisibleAgentsWithLocalRetry(
              trustedDevicesResult.serverUrl,
            );
      final selectedDeviceId = await _loadSelectedDeviceId();
      final initialDevices = devices
          .map((device) => <String, dynamic>{
                ...device,
                'routeLabel': '检测中',
              })
          .toList(growable: false);
      if (!mounted) return;
      setState(() {
        _trustedDevices = initialDevices;
        _selectedDevice = initialDevices.isNotEmpty
            ? _findCurrent(
                initialDevices,
                preferredDeviceId: selectedDeviceId,
              )
            : null;
        _loading = false;
      });

      final normalizedDevices = await Future.wait(
        devices.map((device) async {
          final isLocalNetwork = await NetworkRouteResolver.isSameLocalNetwork(
            resolvedServerUrl: trustedDevicesResult.serverUrl,
            deviceLocalIp: device['localIp']?.toString() ?? '',
            expectedDeviceId: device['deviceId']?.toString(),
            deviceLocalIps: ((device['localIps'] as List?) ?? const [])
                .map((item) => item.toString())
                .toList(growable: false),
            deviceLanProbePort: (device['lanProbePort'] as num?)?.toInt() ?? 0,
          );
          return <String, dynamic>{
            ...device,
            'routeLabel': isLocalNetwork ? '局域网' : '远程',
          };
        }),
      );
      if (!mounted) return;
      setState(() {
        _trustedDevices = normalizedDevices;
        _selectedDevice = normalizedDevices.isNotEmpty
            ? _findCurrent(
                normalizedDevices,
                preferredDeviceId: selectedDeviceId,
              )
            : null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载已绑定设备失败：$e';
        _loading = false;
      });
    }
  }

  Future<_TrustedDevicesResult> _fetchTrustedDevicesWithLocalRetry(
    String resolvedServerUrl,
  ) async {
    final localServerUrl = _localServerUrl;
    try {
      final devices =
          await _pairingService.fetchTrustedDevices(resolvedServerUrl);
      return _TrustedDevicesResult(
        serverUrl: resolvedServerUrl,
        devices: devices,
      );
    } catch (error) {
      final resolved = resolvedServerUrl.trim();
      if (localServerUrl.isEmpty || resolved == localServerUrl) {
        rethrow;
      }
      try {
        final devices =
            await _pairingService.fetchTrustedDevices(localServerUrl);
        return _TrustedDevicesResult(
          serverUrl: localServerUrl,
          devices: devices,
        );
      } catch (_) {
        throw error;
      }
    }
  }

  Future<List<Map<String, dynamic>>> _fetchVisibleAgentsWithLocalRetry(
    String resolvedServerUrl,
  ) async {
    final localServerUrl = _localServerUrl;
    try {
      return await _fetchVisibleAgents(resolvedServerUrl);
    } catch (error) {
      final resolved = resolvedServerUrl.trim();
      if (localServerUrl.isEmpty || resolved == localServerUrl) {
        rethrow;
      }
      try {
        return await _fetchVisibleAgents(localServerUrl);
      } catch (_) {
        throw error;
      }
    }
  }

  Future<List<Map<String, dynamic>>> _fetchVisibleAgents(
      String serverUrl) async {
    final service = SignalingService(serverUrl: serverUrl);
    final agents = await service.fetchAgents();
    return agents
        .map((agent) => <String, dynamic>{
              ...agent,
              'needsPairing': true,
            })
        .toList(growable: false);
  }

  Future<String?> _loadSelectedDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_selectedDeviceIdKey)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> _savePendingInstallerPath(String filePath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingInstallerPathKey, filePath.trim());
  }

  Future<String?> _loadPendingInstallerPath() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_pendingInstallerPathKey)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> _clearPendingInstallerPath() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingInstallerPathKey);
  }

  Future<void> _resumePendingInstallerIfAllowed() async {
    if (_resumingInstaller) return;
    final pendingPath = await _loadPendingInstallerPath();
    if (pendingPath == null || pendingPath.isEmpty) {
      return;
    }

    final canInstall = await _appUpdateService.canRequestPackageInstalls();
    if (!canInstall) {
      return;
    }

    if (!mounted) return;
    setState(() {
      _resumingInstaller = true;
    });

    try {
      final installerStatus =
          await _appUpdateService.openInstaller(pendingPath);
      if (installerStatus == AndroidInstallerLaunchStatus.launched) {
        await _clearPendingInstallerPath();
      }
    } catch (e) {
      await _clearPendingInstallerPath();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('继续安装失败：$e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _resumingInstaller = false;
        });
      }
    }
  }

  Future<void> _uploadDiagnosticsBundle() async {
    // Pull the heartbeat files Kotlin has been writing and ship them to
    // the server. Each file is uploaded as raw body to avoid pulling in a
    // multipart dependency on the server. We do this from the home screen
    // (not the control screen) so the user can hit it after escaping a
    // freeze, when the control screen's networking might still be wedged.
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('正在收集诊断...')));
    try {
      const channel = MethodChannel('pocketwindow/isolate_heartbeat');
      final dirPath = await channel.invokeMethod<String>('getHeartbeatDir');
      if (dirPath == null || dirPath.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('找不到诊断目录')));
        return;
      }
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        messenger.showSnackBar(const SnackBar(content: Text('诊断目录不存在')));
        return;
      }
      final endpoint = await _resolveServerEndpoint();
      final wsUri = Uri.parse(endpoint.serverUrl);
      final baseUrl = 'http://${wsUri.host}:${wsUri.port}';
      final bundleId = DateTime.now().millisecondsSinceEpoch.toString();
      var attached = 0;
      final messages = <String>[];
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        final bytes = await entity.readAsBytes();
        final uri = Uri.parse(
          '$baseUrl/api/diagnostics/upload'
          '?bundle=$bundleId&file_name=${Uri.encodeQueryComponent(name)}',
        );
        final response = await http
            .post(uri,
                headers: {'Content-Type': 'application/octet-stream'},
                body: bytes)
            .timeout(const Duration(seconds: 30));
        messages.add('$name=${response.statusCode}');
        if (response.statusCode == 200) attached++;
      }
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            attached == 0
                ? '诊断上传失败: ${messages.join(",")}'
                : '诊断上传成功 bundle=$bundleId 共 $attached 个文件',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('诊断上传失败: $error')),
      );
    }
  }

  Future<void> _checkForAppUpdate({bool userInitiated = false}) async {
    if (_checkingUpdate) return;
    setState(() {
      _checkingUpdate = true;
    });
    try {
      final resolvedEndpoint = await _resolveServerEndpoint();
      final release = await _appUpdateService
          .fetchLatestAndroidRelease(resolvedEndpoint.serverUrl);
      if (!mounted) return;
      if (release == null) {
        if (userInitiated) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('当前没有可用的新版本')),
          );
        }
        return;
      }

      final isNewer = await _appUpdateService.isNewerThanInstalled(release);
      if (!mounted) return;
      if (!isNewer) {
        if (userInitiated) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('当前已是最新版本 ${release.version}')),
          );
        }
        return;
      }

      final confirmed = await showDialog<bool>(
            context: context,
            barrierDismissible: !release.forceUpdate,
            builder: (dialogContext) => AlertDialog(
              title: Text(
                release.title.isNotEmpty
                    ? release.title
                    : '发现新版本 ${release.version}',
              ),
              content: SingleChildScrollView(
                child: Text(
                  release.notes.trim().isEmpty
                      ? '检测到新版本 ${release.version}，是否现在下载并安装？'
                      : '检测到新版本 ${release.version}\n\n${release.notes}',
                ),
              ),
              actions: [
                if (!release.forceUpdate)
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('稍后'),
                  ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('立即更新'),
                ),
              ],
            ),
          ) ??
          false;
      if (!mounted || !confirmed) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正在下载更新包...')),
      );
      setState(() {
        _downloadingUpdate = true;
        _updateDownloadProgress = 0;
      });
      final updateSourceUrl = await _resolveUpdateDownloadUrl(
        release,
        serverUrl: resolvedEndpoint.serverUrl,
      );
      final result = await _appUpdateService.downloadAndroidRelease(
        release,
        sourceUrlOverride: updateSourceUrl,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _updateDownloadProgress = progress;
          });
        },
      );
      await _savePendingInstallerPath(result.savedPath);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('安装包已保存到 ${result.savedPath}，正在打开安装器')),
      );
      final installerStatus =
          await _appUpdateService.openInstaller(result.savedPath);
      if (!mounted) return;
      if (installerStatus == AndroidInstallerLaunchStatus.permissionRequired) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('请先允许本应用安装未知来源应用，授权后返回将自动继续安装'),
            duration: Duration(seconds: 6),
          ),
        );
      } else {
        await _clearPendingInstallerPath();
      }
    } catch (e) {
      if (!mounted) return;
      final errorStr = e.toString();
      if (errorStr.contains('version_not_newer')) {
        try {
          final pendingPath = await _loadPendingInstallerPath();
          if (pendingPath != null && pendingPath.isNotEmpty) {
            await File(pendingPath).delete();
          }
        } catch (_) {}
        await _clearPendingInstallerPath();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('下载的安装包版本不对，缓存已清除，请重新检查更新'),
            duration: Duration(seconds: 5),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('更新失败：$e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _checkingUpdate = false;
          _downloadingUpdate = false;
          _updateDownloadProgress = null;
        });
      }
    }
  }

  Future<String> _resolveUpdateDownloadUrl(
    AppReleaseInfo release, {
    String? serverUrl,
  }) async {
    // Look at every enabled signaling endpoint that resolves to a private IP.
    // The agent typically hosts the APK on the same machine that runs the
    // signaling server, so a LAN-direct download avoids hitting the WAN.
    for (final entry in _signalingEndpoints) {
      if (!entry.enabled) continue;
      final uri = Uri.tryParse(entry.url);
      if (uri == null) continue;
      if (!_isPrivateHost(uri.host)) continue;
      final lanSourceUrl = _releaseSourceUrlForServer(release, entry.url);
      if (lanSourceUrl == null) continue;
      try {
        final healthUri = _httpApiUri(entry.url, '/api/health');
        final response = await http
            .get(healthUri)
            .timeout(const Duration(milliseconds: 900));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return lanSourceUrl;
        }
      } catch (_) {
        // LAN endpoint unreachable, try the next one.
      }
    }
    final serverUrlStr = (serverUrl ?? '').trim();
    if (serverUrlStr.isNotEmpty) {
      final url = _releaseSourceUrlForServer(release, serverUrlStr);
      if (url != null) return url;
    }
    final fallback = release.sourceUrl.trim();
    return fallback.isNotEmpty ? fallback : release.downloadUrl;
  }

  static bool _isPrivateHost(String host) {
    final parts = host.split('.');
    if (parts.length != 4) {
      final lower = host.toLowerCase();
      return lower == 'localhost' || lower == '127.0.0.1';
    }
    final nums = <int>[];
    for (final part in parts) {
      final parsed = int.tryParse(part);
      if (parsed == null || parsed < 0 || parsed > 255) return false;
      nums.add(parsed);
    }
    return nums[0] == 10 ||
        (nums[0] == 172 && nums[1] >= 16 && nums[1] <= 31) ||
        (nums[0] == 192 && nums[1] == 168);
  }

  String? _releaseSourceUrlForServer(
    AppReleaseInfo release,
    String serverUrl,
  ) {
    final downloadPath = release.downloadUrl.trim().isNotEmpty
        ? release.downloadUrl.trim()
        : Uri.tryParse(release.sourceUrl)?.path;
    if (downloadPath == null || downloadPath.isEmpty) return null;
    final path = downloadPath.startsWith('/') ? downloadPath : '/$downloadPath';
    return _httpApiUri(serverUrl, path).toString();
  }

  Uri _httpApiUri(String serverUrl, String path) {
    final normalized = SignalingEndpointsStore.normalizeUrl(serverUrl) ?? serverUrl;
    final wsUri =
        Uri.parse(normalized.endsWith('/ws') ? normalized : '$normalized/ws');
    final scheme = wsUri.scheme == 'wss' ? 'https' : 'http';
    return wsUri.replace(scheme: scheme, path: path, query: '');
  }

  Future<void> _persistSelectedDeviceId(String? deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = deviceId?.trim() ?? '';
    if (normalized.isEmpty) {
      await prefs.remove(_selectedDeviceIdKey);
      return;
    }
    await prefs.setString(_selectedDeviceIdKey, normalized);
  }

  Map<String, dynamic>? _findCurrent(
    List<Map<String, dynamic>> devices, {
    String? preferredDeviceId,
  }) {
    final currentId = preferredDeviceId?.trim().isNotEmpty == true
        ? preferredDeviceId!.trim()
        : _selectedDevice?['deviceId']?.toString();
    if (currentId == null || currentId.isEmpty) return devices.first;
    for (final item in devices) {
      if (item['deviceId']?.toString() == currentId) {
        return item;
      }
    }
    return devices.first;
  }

  Future<void> _openSession(_LaunchMode mode) async {
    setState(() {
      _error = null;
    });
    if (!_hasSignalingEndpoints) {
      setState(() {
        _error = '请先在“连接设置”里添加至少一个信令服务器（与电脑端一致）';
      });
      return;
    }
    final selected = _selectedDevice;
    if (selected == null) {
      setState(() {
        _error = '请先绑定一台电脑';
      });
      return;
    }
    if (!_isDeviceOnline(selected)) {
      setState(() {
        _error = '当前电脑离线，请先确保电脑端已连接服务器';
      });
      return;
    }

    final roomId = selected['roomId']?.toString() ?? '';
    final deviceId = selected['deviceId']?.toString() ?? '';
    if (roomId.isEmpty || deviceId.isEmpty) {
      setState(() {
        _error = '当前绑定设备信息不完整';
      });
      return;
    }

    if (mode == _LaunchMode.control) {
      final clientId = await _pairingService.getOrCreateClientId();
      final clientName = await _pairingService.getClientName();
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (routeContext) {
            final signalingService = SignalingService();
            final controlService = ControlService();
            return MultiProvider(
              providers: [
                ChangeNotifierProvider.value(value: signalingService),
                ChangeNotifierProvider.value(value: controlService),
              ],
              child: ControlScreen(
                roomId: roomId,
                deviceId: deviceId,
                localServerUrl: _localServerUrl,
                fallbackServerUrl: _fallbackServerUrl,
                deviceLocalIp: selected['localIp']?.toString() ?? '',
                deviceLocalIps: ((selected['localIps'] as List?) ?? const [])
                    .map((item) => item.toString())
                    .toList(growable: false),
                deviceLanProbePort:
                    (selected['lanProbePort'] as num?)?.toInt() ?? 0,
                deviceLanDirectPort:
                    (selected['lanDirectPort'] as num?)?.toInt() ?? 0,
                publicDirectHost:
                    selected['publicDirectHost']?.toString().trim(),
                publicDirectPort:
                    (selected['publicDirectPort'] as num?)?.toInt() ?? 0,
                clientId: clientId,
                clientName: clientName,
              ),
            );
          },
        ),
      );
      return;
    }

    setState(() {
      _loading = true;
    });
    final signalingService = SignalingService();
    try {
      final resolvedEndpoint = await _resolveServerEndpoint();
      final initialIsLocalNetwork =
          await NetworkRouteResolver.isSameLocalNetwork(
        resolvedServerUrl: resolvedEndpoint.serverUrl,
        deviceLocalIp: selected['localIp']?.toString() ?? '',
        expectedDeviceId: deviceId,
        deviceLocalIps: ((selected['localIps'] as List?) ?? const [])
            .map((item) => item.toString())
            .toList(growable: false),
        deviceLanProbePort: (selected['lanProbePort'] as num?)?.toInt() ?? 0,
        forceRefresh: true,
      );
      final lanDirectCandidateUrl = _lanDirectServerUrl(
        selected['localIp']?.toString() ?? '',
        ((selected['localIps'] as List?) ?? const [])
            .map((item) => item.toString())
            .toList(growable: false),
        (selected['lanDirectPort'] as num?)?.toInt() ?? 0,
      );
      final lanDirectUrl = initialIsLocalNetwork ? lanDirectCandidateUrl : '';
      final publicDirectHost = selected['publicDirectHost']?.toString().trim() ?? '';
      final publicDirectPort = (selected['publicDirectPort'] as num?)?.toInt() ?? 0;
      String? publicDirectUrl;
      if (!initialIsLocalNetwork && publicDirectHost.isNotEmpty && publicDirectPort > 0) {
        publicDirectUrl = 'ws://$publicDirectHost:$publicDirectPort';
      }
      final publicDirectAttempt = await PublicDirectClient.tryPrepare(
        expectedDeviceId: deviceId,
      );
      final effectivePublicDirect = publicDirectAttempt != null
          ? publicDirectAttempt
          : (publicDirectUrl != null
              ? PublicDirectAttempt(
                  serverUrl: publicDirectUrl,
                  totpCode: '',
                  totpNonce: '',
                  config: PublicDirectConfig(
                    host: publicDirectHost,
                    port: publicDirectPort,
                    deviceId: deviceId,
                    totpSecret: '',
                  ),
                )
              : null);
      final clientIdValue = await _pairingService.getOrCreateClientId();
      final clientNameValue = await _pairingService.getClientName();
      if (effectivePublicDirect != null) {
        signalingService.serverUrl = effectivePublicDirect.serverUrl;
        signalingService.setPublicDirectAuth(
          totpCode: effectivePublicDirect.totpCode,
          totpNonce: effectivePublicDirect.totpNonce,
        );
      } else {
        signalingService.serverUrl =
            lanDirectUrl.isNotEmpty ? lanDirectUrl : resolvedEndpoint.serverUrl;
        signalingService.clearPublicDirectAuth();
      }
      signalingService.roomId = roomId;
      signalingService.clientId = clientIdValue;
      signalingService.clientName = clientNameValue;
      signalingService.deviceId = deviceId;
      try {
        await signalingService.connect();
      } catch (_) {
        // Cascade: public-direct → LAN-direct → signaling relay.
        if (effectivePublicDirect != null) {
          signalingService.disconnect();
          signalingService.clearPublicDirectAuth();
          final fallbackUrl = lanDirectUrl.isNotEmpty
              ? lanDirectUrl
              : resolvedEndpoint.serverUrl;
          signalingService.serverUrl = fallbackUrl;
          signalingService.roomId = roomId;
          signalingService.clientId = clientIdValue;
          signalingService.clientName = clientNameValue;
          signalingService.deviceId = deviceId;
          try {
            await signalingService.connect();
          } catch (_) {
            if (lanDirectUrl.isEmpty || fallbackUrl == resolvedEndpoint.serverUrl) {
              rethrow;
            }
            signalingService.disconnect();
            signalingService.serverUrl = resolvedEndpoint.serverUrl;
            signalingService.roomId = roomId;
            signalingService.clientId = clientIdValue;
            signalingService.clientName = clientNameValue;
            signalingService.deviceId = deviceId;
            await signalingService.connect();
          }
        } else {
          if (lanDirectUrl.isEmpty) rethrow;
          signalingService.disconnect();
          signalingService.serverUrl = resolvedEndpoint.serverUrl;
          signalingService.roomId = roomId;
          signalingService.clientId = clientIdValue;
          signalingService.clientName = clientNameValue;
          signalingService.deviceId = deviceId;
          await signalingService.connect();
        }
      }

      if (!mounted) {
        signalingService.disconnect();
        setState(() {
          _loading = false;
        });
        return;
      }

      if (mode == _LaunchMode.terminal) {
        final terminalService = TerminalService();
        terminalService.attachSignalingService(signalingService);
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => MultiProvider(
              providers: [
                ChangeNotifierProvider.value(value: signalingService),
                ChangeNotifierProvider.value(value: terminalService),
              ],
              child: TerminalScreen(roomId: roomId),
            ),
          ),
        );
        terminalService.dispose();
        signalingService.disconnect();
        setState(() {
          _loading = false;
        });
        return;
      }

      final workspaceService = WorkspaceService();
      workspaceService.setSignalingService(signalingService);
      workspaceService.setLanFileServerUrl(lanDirectCandidateUrl);
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: signalingService),
              ChangeNotifierProvider.value(value: workspaceService),
            ],
            child: WorkspaceScreen(roomId: roomId),
          ),
        ),
      );
      workspaceService.dispose();
      signalingService.disconnect();
      setState(() {
        _loading = false;
      });
    } catch (e) {
      signalingService.disconnect();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '连接失败：$e';
      });
    }
  }

  Future<void> _startPairingFlow() async {
    final result = await Navigator.push<_PairPayload>(
      context,
      MaterialPageRoute(
        builder: (_) => const _ScanPairScreen(),
      ),
    );

    if (!mounted || result == null) return;

    // If the QR carried signaling endpoints (new pw-pair format), import them
    // before the pairing request so _resolveServerEndpoint() has somewhere
    // to look. Existing entries with the same URL are kept; new ones append.
    if (result.endpoints.isNotEmpty) {
      final byUrl = <String, SignalingEndpoint>{};
      for (final entry in _signalingEndpoints) {
        byUrl[entry.url] = entry;
      }
      var nextPriority = _signalingEndpoints.length;
      for (final scanned in result.endpoints) {
        if (byUrl.containsKey(scanned.url)) {
          byUrl[scanned.url] = byUrl[scanned.url]!.copyWith(
            name: scanned.name,
            enabled: true,
          );
        } else {
          byUrl[scanned.url] = scanned.copyWith(priority: nextPriority);
          nextPriority += 1;
        }
      }
      final merged = byUrl.values.toList(growable: true)
        ..sort((a, b) => a.priority.compareTo(b.priority));
      await _saveSignalingEndpoints(merged);
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final resolvedEndpoint = await _resolveServerEndpoint();
      final requestId = await _pairingService.requestPairing(
        serverUrl: resolvedEndpoint.serverUrl,
        deviceId: result.deviceId,
        pairCode: result.pairCode,
      );
      final approved = await _pairingService.pollPairingResult(
        serverUrls: [
          _localServerUrl,
          _fallbackServerUrl,
          resolvedEndpoint.serverUrl,
        ],
        requestId: requestId,
      );
      if (!mounted) return;
      if (approved == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('绑定成功，已加入受信设备列表')),
        );
        await _refreshTrustedDevices();
      } else if (approved == false) {
        setState(() {
          _loading = false;
          _error = '电脑端拒绝了本次绑定申请';
        });
      } else {
        setState(() {
          _loading = false;
          _error = '等待电脑端确认超时，请重试';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '绑定失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      appBar: AppBar(
        title: const Text('PocketWindow'),
        actions: [
          IconButton(
            tooltip: '检查更新',
            onPressed: _busyUpdating
                ? null
                : () => _checkForAppUpdate(userInitiated: true),
            icon: const Icon(Icons.system_update),
          ),
          IconButton(
            tooltip: '上传诊断',
            onPressed: _busyUpdating ? null : _uploadDiagnosticsBundle,
            icon: const Icon(Icons.bug_report),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _refreshTrustedDevices,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '连接设置',
            onPressed: _openConnectionSettings,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + keyboardInset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '已绑定设备',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '只有经过电脑端确认绑定的手机，才会出现在这里并允许连接。',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey[700],
                  ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _loading ? null : _startPairingFlow,
              child: const Text('扫码绑定新电脑'),
            ),
            const SizedBox(height: 10),
            _UpdateButton(
              onPressed: _busyUpdating
                  ? null
                  : () => _checkForAppUpdate(userInitiated: true),
              progress: _downloadingUpdate ? _updateDownloadProgress : null,
              icon: _resumingInstaller
                  ? Icons.install_mobile
                  : Icons.system_update_alt,
              label: _resumingInstaller
                  ? '正在继续安装...'
                  : _downloadingUpdate
                      ? '正在下载更新...'
                      : _checkingUpdate
                          ? '正在检查更新...'
                          : '检查更新',
            ),
            const SizedBox(height: 14),
            if (!_hasSignalingEndpoints)
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.dns_outlined,
                            size: 56, color: Colors.grey),
                        const SizedBox(height: 8),
                        const Text('还没有配置信令服务器',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 6),
                        Text(
                          '请进入“连接设置”填写电脑端使用的信令服务器，或扫描电脑端二维码导入。',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey[700]),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _openConnectionSettings,
                          icon: const Icon(Icons.settings),
                          label: const Text('连接设置'),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else if (_loading)
              const Expanded(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_trustedDevices.isEmpty)
              Expanded(
                child: Center(
                  child: Text(
                    '还没有已绑定电脑。\n请先在电脑端打开配对窗口，再用手机扫码绑定。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey[700]),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView(
                  children: _trustedDevices.map(
                    (device) {
                      final online = _isDeviceOnline(device);
                      return _TrustedDeviceCard(
                        title: (device['deviceName'] ??
                                device['hostName'] ??
                                '未命名电脑')
                            .toString(),
                        subtitle: _subtitleFor(device),
                        selected:
                            _selectedDevice?['deviceId'] == device['deviceId'],
                        online: online,
                        onTap: online && !_needsPairing(device)
                            ? () {
                                setState(() {
                                  _selectedDevice = device;
                                });
                                _persistSelectedDeviceId(
                                  device['deviceId']?.toString(),
                                );
                              }
                            : null,
                      );
                    },
                  ).toList(growable: false),
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _selectedDevice == null ||
                            _loading ||
                            !_isDeviceOnline(_selectedDevice) ||
                            _needsPairing(_selectedDevice)
                        ? null
                        : () => _openSession(_LaunchMode.workspace),
                    child: const Text('文件与启动'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: _selectedDevice == null ||
                            _loading ||
                            !_isDeviceOnline(_selectedDevice) ||
                            _needsPairing(_selectedDevice)
                        ? null
                        : () => _openSession(_LaunchMode.control),
                    child: const Text('远程控制'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _selectedDevice == null ||
                        _loading ||
                        !_isDeviceOnline(_selectedDevice) ||
                        _needsPairing(_selectedDevice)
                    ? null
                    : () => _openSession(_LaunchMode.terminal),
                icon: const Icon(Icons.terminal),
                label: const Text('终端'),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: SelectableText(
                  _error!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _subtitleFor(Map<String, dynamic> device) {
    if (_needsPairing(device)) {
      final pairCode = (device['pairCode'] ?? '').toString();
      return pairCode.isEmpty ? '需要重新绑定' : '需要重新绑定 | 配对码 $pairCode';
    }
    final routeLabel =
        device['routeLabel']?.toString().trim().isNotEmpty == true
            ? device['routeLabel']!.toString()
            : '远程';
    final parts = <String>[
      device['online'] == true ? '在线' : '离线',
      routeLabel,
      '房间号 ${device['roomId'] ?? ''}',
    ];
    final localIp = (device['localIp'] ?? '').toString();
    final platform = (device['platform'] ?? '').toString();
    if (localIp.isNotEmpty) parts.add(localIp);
    if (platform.isNotEmpty) parts.add(platform);
    return parts.join(' | ');
  }
}

class _UpdateButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final double? progress;
  final IconData icon;
  final String label;

  const _UpdateButton({
    required this.onPressed,
    required this.progress,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeProgress = progress;
    return SizedBox(
      height: 40,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (activeProgress != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: LinearProgressIndicator(
                value: activeProgress,
                minHeight: 40,
                backgroundColor: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.18),
                color: theme.colorScheme.primary.withValues(alpha: 0.22),
              ),
            ),
          OutlinedButton.icon(
            onPressed: onPressed,
            icon: Icon(icon),
            label: Text(label),
          ),
        ],
      ),
    );
  }
}

class _ConnectionSettingsScreen extends StatefulWidget {
  final List<SignalingEndpoint> initialEndpoints;
  final Future<void> Function(List<SignalingEndpoint>) onCommit;

  const _ConnectionSettingsScreen({
    required this.initialEndpoints,
    required this.onCommit,
  });

  @override
  State<_ConnectionSettingsScreen> createState() =>
      _ConnectionSettingsScreenState();
}

class _ConnectionSettingsScreenState extends State<_ConnectionSettingsScreen> {
  late List<SignalingEndpoint> _endpoints;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _endpoints = List<SignalingEndpoint>.from(widget.initialEndpoints);
  }

  Future<void> _commit({bool popOnSuccess = false}) async {
    setState(() => _saving = true);
    try {
      // Renumber priorities so visible order maps to routing priority.
      final reindexed = <SignalingEndpoint>[];
      for (var i = 0; i < _endpoints.length; i += 1) {
        reindexed.add(_endpoints[i].copyWith(priority: i));
      }
      await widget.onCommit(reindexed);
      if (!mounted) return;
      setState(() {
        _endpoints = reindexed;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('信令服务器已保存')),
      );
      if (popOnSuccess) {
        Navigator.of(context).pop(true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addOrEdit({SignalingEndpoint? existing}) async {
    final result = await showDialog<_EndpointDraft>(
      context: context,
      builder: (_) => _EndpointEditorDialog(
        initialName: existing?.name ?? '',
        initialUrl: existing?.url ?? '',
      ),
    );
    if (result == null) return;
    final normalizedUrl = SignalingEndpointsStore.normalizeUrl(result.url);
    if (normalizedUrl == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('地址格式不正确')),
      );
      return;
    }
    setState(() {
      if (existing != null) {
        _endpoints = _endpoints
            .map((entry) => entry.id == existing.id
                ? entry.copyWith(name: result.name, url: normalizedUrl)
                : entry)
            .toList(growable: true);
      } else {
        _endpoints = [
          ..._endpoints,
          SignalingEndpoint(
            id: SignalingEndpointsStore.generateId(),
            name: result.name.isNotEmpty
                ? result.name
                : SignalingEndpointsStore.displayAddress(normalizedUrl),
            url: normalizedUrl,
            priority: _endpoints.length,
            enabled: true,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        ];
      }
    });
  }

  void _delete(SignalingEndpoint entry) {
    setState(() {
      _endpoints = _endpoints
          .where((item) => item.id != entry.id)
          .toList(growable: true);
    });
  }

  void _toggleEnabled(SignalingEndpoint entry) {
    setState(() {
      _endpoints = _endpoints
          .map((item) =>
              item.id == entry.id ? item.copyWith(enabled: !item.enabled) : item)
          .toList(growable: true);
    });
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final updated = [..._endpoints];
      final actualNew = newIndex > oldIndex ? newIndex - 1 : newIndex;
      final entry = updated.removeAt(oldIndex);
      updated.insert(actualNew, entry);
      _endpoints = updated;
    });
  }

  Future<void> _scanQrToImport() async {
    final imported = await Navigator.of(context).push<List<SignalingEndpoint>>(
      MaterialPageRoute(builder: (_) => const _EndpointQrScannerScreen()),
    );
    if (imported == null || imported.isEmpty) return;
    setState(() {
      // Replace any existing entries with the same URL; append the rest.
      final byUrl = <String, SignalingEndpoint>{};
      for (final entry in _endpoints) {
        byUrl[entry.url] = entry;
      }
      var nextPriority = _endpoints.length;
      for (final scanned in imported) {
        if (byUrl.containsKey(scanned.url)) {
          byUrl[scanned.url] = byUrl[scanned.url]!.copyWith(
            name: scanned.name,
            enabled: true,
          );
        } else {
          byUrl[scanned.url] = scanned.copyWith(priority: nextPriority);
          nextPriority += 1;
        }
      }
      _endpoints = byUrl.values.toList(growable: true)
        ..sort((a, b) => a.priority.compareTo(b.priority));
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已从二维码导入 ${imported.length} 个信令服务器')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('连接设置'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: '扫码导入',
            onPressed: _saving ? null : _scanQrToImport,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('信令服务器列表',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              '电脑和手机必须连到同一个信令服务器才能互相发现。同 WiFi 下会自动尝试局域网直连，不需要单独配置内网地址。可以扫描电脑端生成的二维码一键导入。',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: Colors.grey[700]),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _endpoints.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.dns_outlined,
                              size: 56, color: Colors.grey[500]),
                          const SizedBox(height: 8),
                          Text('尚未添加任何服务器',
                              style: theme.textTheme.titleSmall),
                          const SizedBox(height: 6),
                          Text(
                            '点击下方“新增”手动填写，或扫描电脑端二维码导入。',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    )
                  : ReorderableListView.builder(
                      itemCount: _endpoints.length,
                      onReorder: _reorder,
                      buildDefaultDragHandles: false,
                      itemBuilder: (context, index) {
                        final entry = _endpoints[index];
                        return Card(
                          key: ValueKey(entry.id),
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: ListTile(
                            leading: ReorderableDragStartListener(
                              index: index,
                              child: const Icon(Icons.drag_handle),
                            ),
                            title: Text(
                              entry.name,
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: entry.enabled ? null : Colors.grey,
                              ),
                            ),
                            subtitle: Text(
                              SignalingEndpointsStore.displayAddress(entry.url),
                              style: theme.textTheme.bodySmall,
                            ),
                            trailing: PopupMenuButton<String>(
                              onSelected: (value) {
                                switch (value) {
                                  case 'edit':
                                    _addOrEdit(existing: entry);
                                    break;
                                  case 'toggle':
                                    _toggleEnabled(entry);
                                    break;
                                  case 'delete':
                                    _delete(entry);
                                    break;
                                }
                              },
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                    value: 'edit', child: Text('编辑')),
                                PopupMenuItem(
                                  value: 'toggle',
                                  child:
                                      Text(entry.enabled ? '停用' : '启用'),
                                ),
                                const PopupMenuItem(
                                    value: 'delete', child: Text('删除')),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.add),
                    onPressed: _saving ? null : () => _addOrEdit(),
                    label: const Text('新增'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed:
                        _saving ? null : () => _commit(popOnSuccess: true),
                    child: const Text('保存并返回'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EndpointDraft {
  final String name;
  final String url;
  const _EndpointDraft({required this.name, required this.url});
}

class _EndpointEditorDialog extends StatefulWidget {
  final String initialName;
  final String initialUrl;

  const _EndpointEditorDialog({
    required this.initialName,
    required this.initialUrl,
  });

  @override
  State<_EndpointEditorDialog> createState() => _EndpointEditorDialogState();
}

class _EndpointEditorDialogState extends State<_EndpointEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
    _urlController = TextEditingController(
      text: SignalingEndpointsStore.displayAddress(widget.initialUrl),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initialUrl.isEmpty ? '新增信令服务器' : '编辑信令服务器'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: '名称（可选）',
              hintText: '例：家里 NAS',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '地址',
              hintText: 'signal.example.com 或 192.168.1.10:58080',
            ),
            autofocus: true,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final url = _urlController.text.trim();
            if (url.isEmpty) return;
            Navigator.of(context).pop(_EndpointDraft(
              name: _nameController.text.trim(),
              url: url,
            ));
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _EndpointQrScannerScreen extends StatefulWidget {
  const _EndpointQrScannerScreen();

  @override
  State<_EndpointQrScannerScreen> createState() =>
      _EndpointQrScannerScreenState();
}

class _EndpointQrScannerScreenState extends State<_EndpointQrScannerScreen> {
  final MobileScannerController _scannerController = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  void _handleDetection(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue?.trim();
      if (raw == null || raw.isEmpty) continue;
      final endpoints = _parsePayload(raw);
      if (endpoints.isEmpty) continue;
      _handled = true;
      Navigator.of(context).pop(endpoints);
      return;
    }
  }

  /// Decode the desktop UI's QR payload. Accepts both the new pair payload
  /// (`type: "pw-pair"`, also carries device_id/pair_code) and the legacy
  /// config-only payload (`type: "pw-config"`). Either way we only return the
  /// endpoint list because this screen is reached from the connection-settings
  /// page; pairing is handled by the dedicated pair scanner.
  List<SignalingEndpoint> _parsePayload(String raw) {
    try {
      // ignore: avoid_dynamic_calls
      final dynamic decoded = const JsonDecoder().convert(raw);
      if (decoded is! Map) return const [];
      final type = decoded['type']?.toString();
      if (type != 'pw-config' && type != 'pw-pair') return const [];
      final list = decoded['endpoints'];
      if (list is! List) return const [];
      final results = <SignalingEndpoint>[];
      for (final item in list) {
        final entry = SignalingEndpoint.fromJson(item);
        if (entry != null) results.add(entry);
      }
      return results;
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫描配置二维码')),
      body: Stack(
        children: [
          MobileScanner(
            controller: _scannerController,
            onDetect: _handleDetection,
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  '将摄像头对准电脑端的“配置二维码”',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrustedDeviceCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool selected;
  final bool online;
  final VoidCallback? onTap;

  const _TrustedDeviceCard({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.online,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foregroundColor = online ? null : Colors.grey.shade500;
    final borderColor = selected
        ? theme.colorScheme.primary
        : online
            ? Colors.grey.shade300
            : Colors.grey.shade200;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: online ? null : Colors.grey.shade100,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: borderColor,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 82,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                SizedBox(
                  width: 38,
                  child: Icon(
                    Icons.computer,
                    color: online ? null : Colors.grey.shade500,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: foregroundColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: foregroundColor,
                          fontSize: 12,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 28,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: selected
                        ? Icon(
                            Icons.check_circle,
                            color: online ? Colors.green : Colors.grey.shade500,
                          )
                        : Icon(
                            online ? Icons.circle : Icons.circle_outlined,
                            size: 12,
                            color: online ? Colors.green : Colors.grey.shade500,
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PairPayload {
  final String deviceId;
  final String pairCode;
  /// Optional signaling endpoints carried in newer pw-pair QR codes. Empty
  /// when the QR is in the legacy `pocketwindow://pair?...` URI form.
  final List<SignalingEndpoint> endpoints;

  const _PairPayload({
    required this.deviceId,
    required this.pairCode,
    this.endpoints = const [],
  });
}

class _ScanPairScreen extends StatefulWidget {
  const _ScanPairScreen();

  @override
  State<_ScanPairScreen> createState() => _ScanPairScreenState();
}

class _ScanPairScreenState extends State<_ScanPairScreen> {
  bool _handled = false;
  bool _importingImage = false;
  final TextEditingController _deviceIdController = TextEditingController();
  final TextEditingController _pairCodeController = TextEditingController();
  final MobileScannerController _scannerController = MobileScannerController();
  final ImagePicker _imagePicker = ImagePicker();

  @override
  void dispose() {
    _deviceIdController.dispose();
    _pairCodeController.dispose();
    _scannerController.dispose();
    super.dispose();
  }

  void _submitManual() {
    final deviceId = _deviceIdController.text.trim();
    final pairCode = _pairCodeController.text.trim();
    if (deviceId.isEmpty || pairCode.isEmpty) return;
    Navigator.pop(
      context,
      _PairPayload(deviceId: deviceId, pairCode: pairCode),
    );
  }

  void _handleRaw(String raw) {
    if (_handled) return;
    final trimmed = raw.trim();

    // Newer desktop builds emit a JSON payload that carries pairing info plus
    // the desktop's preferred signaling endpoints. Old builds still emit the
    // legacy `pocketwindow://pair?...` URI; we accept both.
    if (trimmed.startsWith('{')) {
      try {
        // ignore: avoid_dynamic_calls
        final dynamic decoded = const JsonDecoder().convert(trimmed);
        if (decoded is Map && decoded['type'] == 'pw-pair') {
          final deviceId = decoded['device_id']?.toString().trim() ?? '';
          final pairCode = decoded['pair_code']?.toString().trim() ?? '';
          if (deviceId.isEmpty || pairCode.isEmpty) return;
          final endpointsRaw = decoded['endpoints'];
          final endpoints = <SignalingEndpoint>[];
          if (endpointsRaw is List) {
            for (final item in endpointsRaw) {
              final entry = SignalingEndpoint.fromJson(item);
              if (entry != null) endpoints.add(entry);
            }
          }
          _handled = true;
          Navigator.pop(
            context,
            _PairPayload(
              deviceId: deviceId,
              pairCode: pairCode,
              endpoints: endpoints,
            ),
          );
          return;
        }
        // Public-direct config QR. Saves the host/port/totp_secret locally so
        // future connect() calls can try the public-direct URL first before
        // falling back to the signaling relay. Pairing state is left
        // untouched; the user is expected to have already paired.
        if (decoded is Map && decoded['type'] == 'pw-direct') {
          final config = PublicDirectConfig.fromQrPayload(
            Map<String, dynamic>.from(decoded),
          );
          if (config == null) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('公网直连二维码缺少必要字段，已忽略')),
              );
            }
            return;
          }
          _handled = true;
          // Fire-and-forget save; we do not block the UI on SharedPreferences.
          // The screen pops immediately so the user returns to the previous
          // page and can try connecting straight away.
          // ignore: discarded_futures
          _persistPublicDirectConfig(config);
          return;
        }
      } catch (_) {
        // Not a valid JSON payload; fall through to legacy URI parsing.
      }
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.scheme != 'pocketwindow') return;
    final deviceId = uri.queryParameters['device_id']?.trim() ?? '';
    final pairCode = uri.queryParameters['pair_code']?.trim() ?? '';
    if (deviceId.isEmpty || pairCode.isEmpty) return;
    _handled = true;
    Navigator.pop(
      context,
      _PairPayload(deviceId: deviceId, pairCode: pairCode),
    );
  }

  Future<void> _persistPublicDirectConfig(PublicDirectConfig config) async {
    final messengerState = mounted ? ScaffoldMessenger.maybeOf(context) : null;
    try {
      final client = PublicDirectClient();
      await client.save(config);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('公网直连已配置：${config.host}:${config.port}'),
        ),
      );
      Navigator.pop(context);
    } catch (e) {
      messengerState?.showSnackBar(
        SnackBar(content: Text('保存公网直连配置失败：$e')),
      );
    }
  }

  Future<void> _pickScreenshotAndScan() async {
    if (_handled || _importingImage) return;
    setState(() {
      _importingImage = true;
    });

    try {
      final file = await _imagePicker.pickImage(source: ImageSource.gallery);
      if (!mounted) return;
      if (file == null) {
        setState(() {
          _importingImage = false;
        });
        return;
      }

      final capture = await _scannerController.analyzeImage(file.path);
      if (!mounted || _handled) return;

      if (capture == null || capture.barcodes.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('这张截图里没有识别到 PocketWindow 二维码')),
        );
        return;
      }

      for (final code in capture.barcodes) {
        final raw = code.rawValue;
        if (raw != null) {
          _handleRaw(raw);
          if (_handled) break;
        }
      }

      if (!_handled && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('识别到了二维码，但不是 PocketWindow 配对码')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入截图识别失败：$e')),
      );
    } finally {
      if (mounted && !_handled) {
        setState(() {
          _importingImage = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('扫码绑定电脑'),
        actions: [
          TextButton(
            onPressed: _importingImage ? null : _pickScreenshotAndScan,
            child: Text(_importingImage ? '识别中...' : '导入截图'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: _scannerController,
              onDetect: (capture) {
                for (final code in capture.barcodes) {
                  final raw = code.rawValue;
                  if (raw != null) {
                    _handleRaw(raw);
                  }
                }
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _importingImage ? null : _pickScreenshotAndScan,
                    child: Text(_importingImage ? '正在识别截图...' : '从截图/相册导入二维码'),
                  ),
                ),
                const SizedBox(height: 10),
                const Text('如果手机不能直接扫电脑屏幕，可以先截屏，再从上面的按钮导入识别。'),
                const SizedBox(height: 10),
                const Text('如果扫码不可用，也可以手动输入电脑端显示的设备 ID 和 6 位配对码。'),
                const SizedBox(height: 10),
                TextField(
                  controller: _deviceIdController,
                  decoration: const InputDecoration(
                    labelText: '设备 ID',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _pairCodeController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '配对码',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _submitManual,
                  child: const Text('手动发起绑定'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _LaunchMode {
  control,
  workspace,
  terminal,
}
