import 'dart:convert';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';


class PairingService {
  static const _uuid = Uuid();
  static const _clientIdKey = 'pairing.client_id';
  static const _legacyClientIdKey = 'pairing.clientId';
  static const _clientNameKey = 'pairing.client_name';

  Future<String> getOrCreateClientId() async {
    final prefs = await SharedPreferences.getInstance();

    final saved = _normalizeClientId(
      prefs.getString(_clientIdKey) ?? prefs.getString(_legacyClientIdKey),
    );
    if (saved != null) {
      await prefs.setString(_clientIdKey, saved);
      if (prefs.containsKey(_legacyClientIdKey)) {
        await prefs.remove(_legacyClientIdKey);
      }
      return saved;
    }

    final stableId = await _buildStableClientId();
    await prefs.setString(_clientIdKey, stableId);
    if (prefs.containsKey(_legacyClientIdKey)) {
      await prefs.remove(_legacyClientIdKey);
    }
    return stableId;
  }

  Future<String> getClientName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_clientNameKey) ?? '我的手机';
  }

  Future<void> setClientName(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_clientNameKey, value.trim());
  }

  String? _normalizeClientId(String? value) {
    final normalized = value?.trim() ?? '';
    if (normalized.isEmpty) {
      return null;
    }
    return normalized.startsWith('pwcli-') ? normalized : 'pwcli-$normalized';
  }

  String _buildNamespacedClientId(List<String> parts) {
    final raw = parts.map((item) => item.trim()).where((item) => item.isNotEmpty).join('|');
    if (raw.isEmpty) {
      return 'pwcli-${_uuid.v4()}';
    }
    return 'pwcli-${_uuid.v5(Namespace.url.value, raw)}';
  }

  Future<String> _buildStableClientId() async {
    try {
      final info = DeviceInfoPlugin();
      if (defaultTargetPlatform == TargetPlatform.android) {
        final android = await info.androidInfo;
        return _buildNamespacedClientId([
          'android',
          android.brand,
          android.manufacturer,
          android.model,
          android.device,
          android.product,
          android.board,
          android.hardware,
          android.id,
        ]);
      }
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final ios = await info.iosInfo;
        return _buildNamespacedClientId([
          'ios',
          ios.identifierForVendor ?? '',
          ios.modelName,
          ios.model,
        ]);
      }
    } catch (_) {}
    return 'pwcli-${_uuid.v4()}';
  }

  Uri _httpApiUri(String serverUrl, String path) {
    final normalized = serverUrl.trim().startsWith('ws')
        ? serverUrl.trim()
        : 'ws://${serverUrl.trim()}';
    final wsUri = Uri.parse(normalized.endsWith('/ws') ? normalized : '$normalized/ws');
    final scheme = wsUri.scheme == 'wss' ? 'https' : 'http';
    return wsUri.replace(scheme: scheme, path: path, query: '');
  }

  Future<List<Map<String, dynamic>>> fetchTrustedDevices(String serverUrl) async {
    final clientId = await getOrCreateClientId();
    final uri = _httpApiUri(serverUrl, '/api/trusted-devices/$clientId');
    final response = await http.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('加载已绑定设备失败：${response.statusCode}');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final devices = decoded['devices'];
    if (devices is! List) return const [];
    return devices.map((item) => Map<String, dynamic>.from(item as Map)).toList(growable: false);
  }

  Future<String> requestPairing({
    required String serverUrl,
    required String deviceId,
    required String pairCode,
  }) async {
    final clientId = await getOrCreateClientId();
    final clientName = await getClientName();
    final uri = _httpApiUri(serverUrl, '/api/pair/request');
    final response = await http.post(
      uri,
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'device_id': deviceId,
        'pair_code': pairCode,
        'client_id': clientId,
        'client_name': clientName,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = response.body.isEmpty ? response.statusCode.toString() : response.body;
      throw Exception('发起绑定失败：$message');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return decoded['request_id']?.toString() ?? '';
  }

  Future<bool?> pollPairingResult({
    required List<String> serverUrls,
    required String requestId,
    int maxAttempts = 30,
  }) async {
    if (requestId.isEmpty) return null;
    final candidates = serverUrls
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (candidates.isEmpty) return null;

    Object? lastError;
    for (var i = 0; i < maxAttempts; i += 1) {
      for (final serverUrl in candidates) {
        final uri = _httpApiUri(serverUrl, '/api/pair/status/$requestId');
        try {
          final response = await http.get(uri);
          if (response.statusCode >= 200 && response.statusCode < 300) {
            final decoded = jsonDecode(response.body) as Map<String, dynamic>;
            final status = decoded['status']?.toString();
            if (status == 'approved') return true;
            if (status == 'rejected') return false;
          }
        } catch (e) {
          lastError = e;
        }
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (lastError != null) {
      throw lastError;
    }
    return null;
  }
}
