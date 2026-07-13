import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:pocketwindow/services/signaling_endpoints_store.dart';
import 'package:pocketwindow/services/signaling_service.dart';

class ResolvedServerEndpoint {
  final String serverUrl;

  const ResolvedServerEndpoint({
    required this.serverUrl,
  });
}

/// Picks the best signaling endpoint URL from the user's configured list.
///
/// The selection mirrors the desktop agent's strategy so both ends end up on
/// the same server: enabled entries first, then ascending priority. Within
/// that order, private-network entries win over public ones because they
/// dominate latency. Each candidate is probed with a short health request
/// before being accepted; the first to answer becomes the active endpoint.
class ServerEndpointResolver {
  const ServerEndpointResolver._();

  static const Duration _failedProbeCooldown = Duration(seconds: 30);
  static final Map<String, DateTime> _failedProbeAt = <String, DateTime>{};

  /// Newer multi-endpoint API. Returns the best reachable endpoint URL.
  /// If [preferred] is empty the resolver returns an empty URL so callers can
  /// surface "未配置" to the user instead of attempting a connection to junk.
  static Future<ResolvedServerEndpoint> resolveBestEndpoint({
    required List<SignalingEndpoint> preferred,
    Duration probeTimeout = const Duration(milliseconds: 1500),
  }) async {
    final candidates = preferred
        .where((entry) => entry.enabled)
        .map((entry) => entry.url)
        .where((url) => url.isNotEmpty)
        .toList(growable: false);
    if (candidates.isEmpty) {
      return const ResolvedServerEndpoint(serverUrl: '');
    }

    try {
      final connectivityResults = await Connectivity().checkConnectivity();
      final hasNetwork =
          connectivityResults.any((item) => item != ConnectivityResult.none);
      if (!hasNetwork) {
        return ResolvedServerEndpoint(serverUrl: candidates.first);
      }
    } catch (_) {
      // Continue probing endpoints even if connectivity check fails.
    }

    // LAN entries first, ties broken by user-provided priority.
    final lanCandidates = <String>[];
    final wanCandidates = <String>[];
    for (final url in candidates) {
      final uri = Uri.tryParse(url);
      if (uri != null && _isPrivateHost(uri.host)) {
        lanCandidates.add(url);
      } else {
        wanCandidates.add(url);
      }
    }
    final ordered = <String>[...lanCandidates, ...wanCandidates];

    for (final url in ordered) {
      if (_isOnCooldown(url)) continue;
      final ok = await _probe(url, probeTimeout);
      if (ok) {
        _failedProbeAt.remove(url);
        return ResolvedServerEndpoint(serverUrl: url);
      }
      _failedProbeAt[url] = DateTime.now();
    }

    // All probes failed (or all cooled down). Fall back to the first ordered
    // candidate so the connection attempt still proceeds; the regular
    // reconnect loop will surface failure to the user.
    return ResolvedServerEndpoint(serverUrl: ordered.first);
  }

  static bool _isOnCooldown(String url) {
    final failedAt = _failedProbeAt[url];
    if (failedAt == null) return false;
    return DateTime.now().difference(failedAt) < _failedProbeCooldown;
  }

  static Future<bool> _probe(String url, Duration timeout) async {
    try {
      final probe = SignalingService(serverUrl: url, roomId: 'probe');
      await probe.fetchAgents().timeout(timeout);
      return true;
    } catch (_) {
      return false;
    }
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
        (nums[0] == 192 && nums[1] == 168) ||
        nums[0] == 127;
  }

  // ---- Legacy single-URL API (kept for now to avoid touching every caller).

  static Future<ResolvedServerEndpoint> resolveEndpoint({
    required String localServerUrl,
    required String fallbackServerUrl,
    Duration probeTimeout = const Duration(milliseconds: 1500),
  }) async {
    final endpoints = <SignalingEndpoint>[];
    void addLegacy(String url, String name, int priority) {
      final normalized = SignalingEndpointsStore.normalizeUrl(url);
      if (normalized == null) return;
      if (endpoints.any((e) => e.url == normalized)) return;
      endpoints.add(SignalingEndpoint(
        id: SignalingEndpointsStore.generateId(),
        name: name,
        url: normalized,
        priority: priority,
        enabled: true,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    addLegacy(localServerUrl, 'local', 0);
    addLegacy(fallbackServerUrl, 'fallback', 10);
    return resolveBestEndpoint(preferred: endpoints, probeTimeout: probeTimeout);
  }

  static Future<String> resolve({
    required String localServerUrl,
    required String fallbackServerUrl,
    Duration probeTimeout = const Duration(milliseconds: 1500),
  }) async {
    final resolved = await resolveEndpoint(
      localServerUrl: localServerUrl,
      fallbackServerUrl: fallbackServerUrl,
      probeTimeout: probeTimeout,
    );
    return resolved.serverUrl;
  }
}
