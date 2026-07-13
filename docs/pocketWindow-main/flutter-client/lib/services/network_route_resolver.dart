import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class NetworkRouteResolver {
  const NetworkRouteResolver._();

  static const Duration _failedLanProbeCooldown = Duration(seconds: 30);
  static final Map<String, DateTime> _failedLanProbeAt = <String, DateTime>{};

  static Future<bool> isSameLocalNetwork({
    required String resolvedServerUrl,
    required String deviceLocalIp,
    String? expectedDeviceId,
    List<String> deviceLocalIps = const [],
    int? deviceLanProbePort,
    List<String>? localDeviceIpsOverride,
    bool forceRefresh = false,
  }) async {
    final normalizedServerUrl = resolvedServerUrl.trim();
    if (normalizedServerUrl.isEmpty) {
      return false;
    }

    final serverUri = Uri.tryParse(_normalizeWsUrl(normalizedServerUrl));
    final serverHost = serverUri?.host.trim() ?? '';
    if (_isPrivateIpv4(serverHost)) {
      return true;
    }

    final remoteCandidates = _normalizedPrivateIpv4s([
      deviceLocalIp,
      ...deviceLocalIps,
    ]);
    if (remoteCandidates.isEmpty) {
      return false;
    }

    final probePort = deviceLanProbePort ?? 0;
    if (probePort > 0) {
      for (final remoteIp in remoteCandidates) {
        if (await _probeDesktopLanEndpoint(
          remoteIp,
          probePort,
          expectedDeviceId: expectedDeviceId,
          forceRefresh: forceRefresh,
        )) {
          return true;
        }
      }
    }

    final localCandidates = localDeviceIpsOverride != null
        ? _normalizedPrivateIpv4s(localDeviceIpsOverride)
        : await _privateIpv4s();
    if (localCandidates.isEmpty) {
      return false;
    }

    for (final localIp in localCandidates) {
      for (final remoteIp in remoteCandidates) {
        if (_likelySameLan(localIp, remoteIp)) {
          return true;
        }
      }
    }

    return false;
  }

  static Future<String?> detectClientReachableIp(String serverUrl) async {
    try {
      final uri = _httpApiUri(serverUrl, '/api/network-info');
      final response = await http.get(uri);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final body = response.body.trim();
      if (_isPrivateIpv4(body)) {
        return body;
      }
    } catch (_) {}
    return null;
  }

  static Future<bool> _probeDesktopLanEndpoint(
    String host,
    int port, {
    String? expectedDeviceId,
    bool forceRefresh = false,
  }) async {
    final cacheKey = '$host:$port';
    final failedAt = _failedLanProbeAt[cacheKey];
    if (!forceRefresh &&
        failedAt != null &&
        DateTime.now().difference(failedAt) < _failedLanProbeCooldown) {
      return false;
    }
    if (forceRefresh) {
      _failedLanProbeAt.remove(cacheKey);
    }

    try {
      final normalizedExpectedDeviceId = expectedDeviceId?.trim() ?? '';
      if (normalizedExpectedDeviceId.isNotEmpty) {
        final infoUri = Uri.parse('http://$host:$port/probe/info');
        final infoResponse =
            await http.get(infoUri).timeout(const Duration(milliseconds: 900));
        if (infoResponse.statusCode >= 200 && infoResponse.statusCode < 300) {
          final payload = jsonDecode(infoResponse.body);
          if (payload is Map<String, dynamic> &&
              payload['ok'] == true &&
              payload['protocol'] == 'pocketwindow-lan-probe' &&
              payload['device_id']?.toString().trim() ==
                  normalizedExpectedDeviceId) {
            _failedLanProbeAt.remove(cacheKey);
            return true;
          }
          _failedLanProbeAt[cacheKey] = DateTime.now();
          return false;
        }
      }

      final uri = Uri.parse('http://$host:$port/probe');
      final response =
          await http.get(uri).timeout(const Duration(milliseconds: 900));
      final success = response.statusCode >= 200 &&
          response.statusCode < 300 &&
          response.body.trim() == 'ok';
      if (success) {
        _failedLanProbeAt.remove(cacheKey);
        return true;
      }
    } catch (_) {}
    _failedLanProbeAt[cacheKey] = DateTime.now();
    return false;
  }

  static Future<List<String>> _privateIpv4s() async {
    final results = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final ip = address.address.trim();
          if (_isPrivateIpv4(ip) && !results.contains(ip)) {
            results.add(ip);
          }
        }
      }
    } catch (_) {}
    return results;
  }

  static List<String> _normalizedPrivateIpv4s(List<String> values) {
    final results = <String>[];
    for (final value in values) {
      final ip = value.trim();
      if (_isPrivateIpv4(ip) && !results.contains(ip)) {
        results.add(ip);
      }
    }
    return results;
  }

  static String _normalizeWsUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.startsWith('ws://') || trimmed.startsWith('wss://')) {
      return trimmed;
    }
    return 'ws://$trimmed';
  }

  static Uri _httpApiUri(String serverUrl, String path) {
    final wsUri = Uri.parse(_normalizeWsUrl(serverUrl));
    final scheme = wsUri.scheme == 'wss' ? 'https' : 'http';
    return wsUri.replace(scheme: scheme, path: path, query: '');
  }

  static bool _isPrivateIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;
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

  static bool _likelySameLan(String left, String right) {
    final leftParts = left.split('.');
    final rightParts = right.split('.');
    if (leftParts.length != 4 || rightParts.length != 4) {
      return false;
    }

    final leftA = int.parse(leftParts[0]);
    final leftB = int.parse(leftParts[1]);
    final leftC = int.parse(leftParts[2]);
    final rightA = int.parse(rightParts[0]);
    final rightB = int.parse(rightParts[1]);
    final rightC = int.parse(rightParts[2]);

    if (leftA == 192 && leftB == 168 && rightA == 192 && rightB == 168) {
      return leftC == rightC;
    }
    if (leftA == 10 && rightA == 10) {
      return leftB == rightB && leftC == rightC;
    }
    if (leftA == 172 &&
        rightA == 172 &&
        leftB >= 16 &&
        leftB <= 31 &&
        rightB >= 16 &&
        rightB <= 31) {
      return leftB == rightB && leftC == rightC;
    }
    return false;
  }
}
