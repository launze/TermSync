import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A user-configured signaling server entry. The URL is stored in
/// canonical `ws://host:port` form; default ports are filled in when
/// the user omits them.
class SignalingEndpoint {
  final String id;
  final String name;
  final String url;
  final int priority;
  final bool enabled;
  final int createdAt;

  const SignalingEndpoint({
    required this.id,
    required this.name,
    required this.url,
    required this.priority,
    required this.enabled,
    required this.createdAt,
  });

  SignalingEndpoint copyWith({
    String? id,
    String? name,
    String? url,
    int? priority,
    bool? enabled,
    int? createdAt,
  }) =>
      SignalingEndpoint(
        id: id ?? this.id,
        name: name ?? this.name,
        url: url ?? this.url,
        priority: priority ?? this.priority,
        enabled: enabled ?? this.enabled,
        createdAt: createdAt ?? this.createdAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'url': url,
        'priority': priority,
        'enabled': enabled,
        'created_at': createdAt,
      };

  static SignalingEndpoint? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final url = (raw['url'] ?? '').toString().trim();
    if (url.isEmpty) return null;
    final normalized = SignalingEndpointsStore.normalizeUrl(url);
    if (normalized == null) return null;
    final id = (raw['id'] ?? '').toString().trim().isEmpty
        ? SignalingEndpointsStore.generateId()
        : (raw['id'] ?? '').toString().trim();
    final priority = raw['priority'] is num ? (raw['priority'] as num).toInt() : 0;
    final createdAt = raw['created_at'] is num
        ? (raw['created_at'] as num).toInt()
        : DateTime.now().millisecondsSinceEpoch;
    final name = (raw['name'] ?? '').toString().trim().isEmpty
        ? normalized
        : (raw['name'] ?? '').toString().trim();
    final enabled = raw['enabled'] is bool ? raw['enabled'] as bool : true;
    return SignalingEndpoint(
      id: id,
      name: name,
      url: normalized,
      priority: priority,
      enabled: enabled,
      createdAt: createdAt,
    );
  }
}

/// Persists the user's signaling endpoint list and migrates legacy
/// single-URL configurations into the new multi-entry shape.
class SignalingEndpointsStore {
  static const _endpointsKey = 'home.signaling_endpoints';
  // Legacy keys (single-URL world). Read once for migration, never written.
  static const _legacyLocalUrlKey = 'home.local_server_url';
  static const _legacyFallbackUrlKey = 'home.fallback_server_url';
  static const _defaultWsPort = 80;
  static const _defaultWssPort = 443;
  static int _idSequence = 0;

  /// Loads the saved endpoints, performing one-time migration from the
  /// legacy single-URL keys when no new-style list is present yet.
  static Future<List<SignalingEndpoint>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_endpointsKey)?.trim();
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = json.decode(raw);
        if (decoded is List) {
          final list = decoded
              .map(SignalingEndpoint.fromJson)
              .whereType<SignalingEndpoint>()
              .toList(growable: false);
          return _sortForRouting(list);
        }
      } catch (_) {
        // Corrupt stored payload; fall through to migration / empty.
      }
    }
    // Migrate legacy single-URL settings if present.
    final migrated = <SignalingEndpoint>[];
    final legacyLocal = prefs.getString(_legacyLocalUrlKey)?.trim();
    final legacyFallback = prefs.getString(_legacyFallbackUrlKey)?.trim();
    void addLegacy(String? url, String defaultName, int priority) {
      if (url == null || url.isEmpty) return;
      final normalized = normalizeUrl(url);
      if (normalized == null) return;
      if (migrated.any((e) => e.url == normalized)) return;
      migrated.add(SignalingEndpoint(
        id: generateId(),
        name: defaultName,
        url: normalized,
        priority: priority,
        enabled: true,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    addLegacy(legacyLocal, '主服务器', 0);
    addLegacy(legacyFallback, '备用服务器', 10);
    if (migrated.isNotEmpty) {
      await save(migrated);
      return migrated;
    }
    // No saved list and nothing to migrate: pre-fill the built-in seeds so
    // a fresh install can pair immediately. The user can edit/delete any of
    // these from the connection-settings page like any other endpoint.
    final seeds = _builtInSeeds();
    if (seeds.isNotEmpty) {
      await save(seeds);
    }
    return seeds;
  }

  /// Default endpoints for a fresh install. Mirrors the desktop agent's
  /// `BUILTIN_SEED_ENDPOINTS`. Removing this list (or any item in it) only
  /// changes the *defaults*: the stored list is fully user-editable.
  static List<SignalingEndpoint> _builtInSeeds() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final raw = <List<Object>>[
      [r'局域网 NAS', 'ws://192.168.31.77:58080', 0],
      [r'主公网', 'ws://signal.167183.xyz:80', 1],
      [r'备用公网', 'ws://ha.wwszxc.tax:16900', 2],
    ];
    final seeds = <SignalingEndpoint>[];
    for (final row in raw) {
      final normalized = normalizeUrl(row[1] as String);
      if (normalized == null) continue;
      seeds.add(SignalingEndpoint(
        id: generateId(),
        name: row[0] as String,
        url: normalized,
        priority: row[2] as int,
        enabled: true,
        createdAt: now,
      ));
    }
    return seeds;
  }

  static Future<void> save(List<SignalingEndpoint> endpoints) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded =
        json.encode(endpoints.map((e) => e.toJson()).toList(growable: false));
    await prefs.setString(_endpointsKey, encoded);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_endpointsKey);
  }

  /// Generates a 16-char id without depending on a uuid package.
  static String generateId() {
    _idSequence += 1;
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final seq = _idSequence.toRadixString(16).padLeft(4, '0');
    return '$ts$seq';
  }

  /// Normalize "host", "host:port", "ws://host", "wss://host:port" etc.
  /// Returns null when the URL is unusable.
  static String? normalizeUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    String withScheme;
    if (trimmed.startsWith('ws://') || trimmed.startsWith('wss://')) {
      withScheme = trimmed;
    } else if (trimmed.startsWith('http://')) {
      withScheme = 'ws://${trimmed.substring('http://'.length)}';
    } else if (trimmed.startsWith('https://')) {
      withScheme = 'wss://${trimmed.substring('https://'.length)}';
    } else {
      withScheme = 'ws://$trimmed';
    }
    final uri = Uri.tryParse(withScheme);
    if (uri == null ||
        (uri.scheme != 'ws' && uri.scheme != 'wss') ||
        uri.host.trim().isEmpty) {
      return null;
    }
    if (uri.path.isNotEmpty && uri.path != '/') {
      return null;
    }
    final port = uri.hasPort
        ? uri.port
        : (uri.scheme == 'wss' ? _defaultWssPort : _defaultWsPort);
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: port,
    ).toString();
  }

  /// Display form ("host:port" without scheme) for the connection settings UI.
  static String displayAddress(String url) {
    final normalized = normalizeUrl(url) ?? url;
    if (normalized.startsWith('ws://')) {
      return normalized.substring('ws://'.length);
    }
    if (normalized.startsWith('wss://')) {
      return normalized.substring('wss://'.length);
    }
    return normalized;
  }

  static List<SignalingEndpoint> _sortForRouting(List<SignalingEndpoint> list) {
    final sorted = [...list];
    sorted.sort((a, b) {
      final enabledCompare = (a.enabled ? 0 : 1).compareTo(b.enabled ? 0 : 1);
      if (enabledCompare != 0) return enabledCompare;
      return a.priority.compareTo(b.priority);
    });
    return sorted;
  }
}
