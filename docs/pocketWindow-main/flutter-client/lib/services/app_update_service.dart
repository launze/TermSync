import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

typedef AppUpdateProgressCallback = void Function(double? progress);

class AppReleaseInfo {
  final String platform;
  final String version;
  final int build;
  final String channel;
  final String title;
  final String notes;
  final String fileName;
  final int fileSize;
  final String sha256;
  final bool forceUpdate;
  final String minSupportedVersion;
  final String downloadUrl;
  final String sourceUrl;

  const AppReleaseInfo({
    required this.platform,
    required this.version,
    required this.build,
    required this.channel,
    required this.title,
    required this.notes,
    required this.fileName,
    required this.fileSize,
    required this.sha256,
    required this.forceUpdate,
    required this.minSupportedVersion,
    required this.downloadUrl,
    required this.sourceUrl,
  });

  factory AppReleaseInfo.fromJson(Map<String, dynamic> json) {
    return AppReleaseInfo(
      platform: json['platform']?.toString() ?? '',
      version: json['version']?.toString() ?? '',
      build: json['build'] is num ? (json['build'] as num).toInt() : 0,
      channel: json['channel']?.toString() ?? 'stable',
      title: json['title']?.toString() ?? '',
      notes: json['notes']?.toString() ?? '',
      fileName: json['file_name']?.toString() ?? '',
      fileSize:
          json['file_size'] is num ? (json['file_size'] as num).toInt() : 0,
      sha256: json['sha256']?.toString() ?? '',
      forceUpdate: json['force_update'] == true,
      minSupportedVersion: json['min_supported_version']?.toString() ?? '',
      downloadUrl: json['download_url']?.toString() ?? '',
      sourceUrl: json['source_url']?.toString() ?? '',
    );
  }
}

class AppUpdateResult {
  final AppReleaseInfo release;
  final String savedPath;

  const AppUpdateResult({
    required this.release,
    required this.savedPath,
  });
}

enum AndroidInstallerLaunchStatus {
  launched,
  permissionRequired,
}

class AppUpdateService {
  static const MethodChannel _installerChannel =
      MethodChannel('pocketwindow/app_update');

  const AppUpdateService();

  Future<PackageInfo> packageInfo() => PackageInfo.fromPlatform();

  Future<AppReleaseInfo?> fetchLatestAndroidRelease(String serverUrl) async {
    final uri = _httpApiUri(serverUrl, '/api/releases/latest').replace(
      queryParameters: const {'platform': 'android'},
    );
    final response = await http.get(uri);
    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('下载更新失败: ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final release = decoded['release'];
    if (release is! Map) {
      return null;
    }
    return AppReleaseInfo.fromJson(Map<String, dynamic>.from(release));
  }

  Future<bool> isNewerThanInstalled(AppReleaseInfo release) async {
    // Use the platform-side versionCode rather than the cached PackageInfo
    // so we always see the *currently installed* APK after an in-place
    // upgrade. package_info_plus caches PackageInfo for the lifetime of
    // the Dart isolate, which made the app keep claiming "update available"
    // even after a successful install: the next install attempt then hit
    // Android's "already installed" error, and the user got stuck.
    final info = await packageInfo();
    final currentVersion = info.version.trim();
    final currentBuild = await liveVersionCode() ??
        int.tryParse(info.buildNumber.trim()) ??
        0;
    final versionCompare = _compareVersions(release.version, currentVersion);
    if (versionCompare > 0) {
      return true;
    }
    if (versionCompare < 0) {
      return false;
    }
    return release.build > currentBuild;
  }

  /// Asks the Android side for the live PackageInfo.versionCode every time.
  /// Returns null on any platform other than Android, or on error.
  Future<int?> liveVersionCode() async {
    if (!Platform.isAndroid) return null;
    try {
      final value =
          await _installerChannel.invokeMethod<int>('currentVersionCode');
      if (value == null || value < 0) return null;
      return value;
    } catch (_) {
      return null;
    }
  }

  Future<AppUpdateResult> downloadAndroidRelease(
    AppReleaseInfo release, {
    AppUpdateProgressCallback? onProgress,
    String? sourceUrlOverride,
  }) async {
    if (!Platform.isAndroid) {
      throw Exception('当前平台不支持安装 Android 更新包');
    }
    final targetDir = Directory(
      '${(await getApplicationSupportDirectory()).path}'
      '${Platform.pathSeparator}updates',
    );
    final rawFileName = release.fileName.trim().isEmpty
        ? 'pocketwindow-update.apk'
        : release.fileName.trim();
    // Make the cache file name version-specific so two releases that happen to
    // have the *same byte size* (e.g. 1.3.2 vs 1.3.3, both 69420400 bytes) can
    // never collide on the fixed "PocketWindow.apk" name and get served a stale
    // cached/partial file. The previous shared name made resume logic splice a
    // new download onto an old body, or skip the download entirely.
    final dotIndex = rawFileName.lastIndexOf('.');
    final fileName = dotIndex > 0
        ? '${rawFileName.substring(0, dotIndex)}-${release.build}${rawFileName.substring(dotIndex)}'
        : '$rawFileName-${release.build}';
    final targetFile =
        File('${targetDir.path}${Platform.pathSeparator}$fileName');

    final partialFile = File('${targetFile.path}.part');

    final client = http.Client();
    try {
      await targetFile.parent.create(recursive: true);
      // Purge stale update artifacts from previous versions so the updates
      // directory never grows unbounded and never confuses the resume logic.
      await _purgeStaleUpdateFiles(targetDir, keepFileName: fileName);
      if (await targetFile.exists() &&
          await _isCompleteReleaseFile(targetFile, release)) {
        onProgress?.call(1.0);
        return AppUpdateResult(
          release: release,
          savedPath: targetFile.path,
        );
      }
      // A leftover partial that no longer matches the target size must be
      // discarded outright; resuming across a size-identical release would
      // corrupt the package and only fail later at the sha256 check.
      if (await partialFile.exists()) {
        final partLen = await partialFile.length();
        if (release.fileSize > 0 && partLen > release.fileSize) {
          await _deleteIfExists(partialFile);
        }
      }


      var resumeBytes = 0;
      if (await partialFile.exists()) {
        resumeBytes = await partialFile.length();
        if (release.fileSize > 0 && resumeBytes >= release.fileSize) {
          await _deleteIfExists(partialFile);
          resumeBytes = 0;
        }
      }

      final sourceUrl = sourceUrlOverride?.trim().isNotEmpty == true
          ? sourceUrlOverride!.trim()
          : release.sourceUrl;
      final request = http.Request('GET', Uri.parse(sourceUrl));
      if (resumeBytes > 0) {
        request.headers['Range'] = 'bytes=$resumeBytes-';
      }
      final response = await client.send(request);
      final canResume = resumeBytes > 0 && response.statusCode == 206;
      if (resumeBytes > 0 && response.statusCode == 200) {
        await _deleteIfExists(partialFile);
        resumeBytes = 0;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('下载更新失败: ${response.statusCode}');
      }
      final expectedBytes =
          release.fileSize > 0
              ? release.fileSize
              : response.contentLength != null && response.contentLength! > 0
                  ? response.contentLength! + (canResume ? resumeBytes : 0)
                  : null;

      await _deleteIfExists(targetFile);

      final sink = partialFile.openWrite(
        mode: canResume ? FileMode.append : FileMode.write,
      );
      var receivedBytes = canResume ? resumeBytes : 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          receivedBytes += chunk.length;
          if (expectedBytes != null && expectedBytes > 0) {
            onProgress?.call((receivedBytes / expectedBytes).clamp(0.0, 1.0));
          } else {
            onProgress?.call(null);
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      if (expectedBytes != null &&
          expectedBytes > 0 &&
          receivedBytes != expectedBytes) {
        throw Exception('Update package is incomplete');
      }
      if (release.sha256.trim().isNotEmpty) {
        final actualSha256 = await _sha256OfFile(partialFile);
        if (actualSha256.toLowerCase() !=
            release.sha256.trim().toLowerCase()) {
          await _deleteIfExists(partialFile);
          throw Exception('Update package checksum failed');
        }
      }
      await _deleteIfExists(targetFile);
      await partialFile.rename(targetFile.path);
      onProgress?.call(1.0);
      return AppUpdateResult(
        release: release,
        savedPath: targetFile.path,
      );
    } finally {
      client.close();
    }
  }

  Future<bool> _isCompleteReleaseFile(
    File file,
    AppReleaseInfo release,
  ) async {
    if (!await file.exists()) return false;
    if (release.fileSize > 0 && await file.length() != release.fileSize) {
      return false;
    }
    if (release.sha256.trim().isEmpty) {
      return true;
    }
    final actualSha256 = await _sha256OfFile(file);
    return actualSha256.toLowerCase() == release.sha256.trim().toLowerCase();
  }

  Future<String> _sha256OfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<void> _purgeStaleUpdateFiles(
    Directory dir, {
    required String keepFileName,
  }) async {
    try {
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.isNotEmpty
            ? entity.uri.pathSegments.last
            : '';
        if (name.isEmpty) continue;
        // Keep the current target and its in-progress part; drop everything
        // else (old-version apks and their leftover .part files).
        if (name == keepFileName || name == '$keepFileName.part') continue;
        if (name.endsWith('.apk') || name.endsWith('.apk.part')) {
          await _deleteIfExists(entity);
        }
      }
    } catch (_) {
      // Best-effort cleanup; a failure here must never block the download.
    }
  }

  Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) {
        return;
      }
      rethrow;
    }
  }

  Future<AndroidInstallerLaunchStatus> openInstaller(String filePath) async {
    if (!Platform.isAndroid) {
      throw Exception('当前平台不支持 APK 安装');
    }
    try {
      final result = await _installerChannel.invokeMethod<String>(
        'installApk',
        <String, dynamic>{'filePath': filePath},
      );
      if (result == 'permission_required') {
        return AndroidInstallerLaunchStatus.permissionRequired;
      }
      if (result != 'launched') {
        throw Exception(result == null || result.isEmpty ? '无法打开安装器' : result);
      }
      return AndroidInstallerLaunchStatus.launched;
    } on PlatformException catch (e) {
      if (e.code == 'permission_required') {
        return AndroidInstallerLaunchStatus.permissionRequired;
      }
      final message = (e.message ?? '').trim();
      throw Exception(message.isEmpty ? '无法打开安装器' : message);
    }
  }

  Future<bool> canRequestPackageInstalls() async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      final result = await _installerChannel.invokeMethod<bool>(
        'canRequestPackageInstalls',
      );
      return result == true;
    } on PlatformException {
      return false;
    }
  }

  Uri _httpApiUri(String serverUrl, String path) {
    final normalized = serverUrl.trim().startsWith('ws')
        ? serverUrl.trim()
        : 'ws://${serverUrl.trim()}';
    final wsUri =
        Uri.parse(normalized.endsWith('/ws') ? normalized : '$normalized/ws');
    final scheme = wsUri.scheme == 'wss' ? 'https' : 'http';
    return wsUri.replace(scheme: scheme, path: path, query: '');
  }

  int _compareVersions(String left, String right) {
    final leftParts = _normalizeVersionParts(left);
    final rightParts = _normalizeVersionParts(right);
    final maxLength = leftParts.length > rightParts.length
        ? leftParts.length
        : rightParts.length;
    for (var i = 0; i < maxLength; i += 1) {
      final leftValue = i < leftParts.length ? leftParts[i] : 0;
      final rightValue = i < rightParts.length ? rightParts[i] : 0;
      if (leftValue > rightValue) return 1;
      if (leftValue < rightValue) return -1;
    }
    return 0;
  }

  List<int> _normalizeVersionParts(String version) {
    return version
        .trim()
        .split(RegExp(r'[.+-]'))
        .map((part) => int.tryParse(part) ?? 0)
        .toList(growable: false);
  }
}
