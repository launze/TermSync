import 'package:flutter_test/flutter_test.dart';
import 'package:pocketwindow/services/network_route_resolver.dart';

void main() {
  group('NetworkRouteResolver', () {
    test('treats private signaling host as local network', () async {
      final result = await NetworkRouteResolver.isSameLocalNetwork(
        resolvedServerUrl: 'ws://192.168.31.77:58080',
        deviceLocalIp: '',
        localDeviceIpsOverride: const [],
      );

      expect(result, isTrue);
    });

    test('matches one of multiple desktop private IPs on same subnet', () async {
      final result = await NetworkRouteResolver.isSameLocalNetwork(
        resolvedServerUrl: 'ws://ha.wwszxc.tax:16900',
        deviceLocalIp: '10.0.0.15',
        deviceLocalIps: const ['192.168.31.77', '10.8.0.2'],
        deviceLanProbePort: 0,
        localDeviceIpsOverride: const ['172.20.10.3'],
      );

      expect(result, isFalse);
    });

    test('stays conservative for fallback server and mismatched private ranges', () async {
      final result = await NetworkRouteResolver.isSameLocalNetwork(
        resolvedServerUrl: 'ws://ha.wwszxc.tax:16900',
        deviceLocalIp: '192.168.31.77',
        deviceLocalIps: const ['172.20.10.3'],
        deviceLanProbePort: 0,
        localDeviceIpsOverride: const ['10.8.0.2'],
      );

      expect(result, isFalse);
    });
  });
}
