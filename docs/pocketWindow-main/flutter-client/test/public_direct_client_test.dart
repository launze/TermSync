// Cross-language TOTP regression test for PublicDirectClient.
//
// Run with: flutter test test/public_direct_client_test.dart
//
// These test vectors are produced by control-agent/src/totp_auth.py
// (HMAC-SHA1, 30-second step, 6 digits, base32 secret) and must
// match on both sides. If a future change to the algorithm breaks
// compatibility with the desktop, this test will fail.

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketwindow/services/public_direct_client.dart';

void main() {
  // Reference values produced by .codex_tmp/print_totp_vectors.py using
  // control-agent/src/totp_auth.py (HMAC-SHA1, 30-second step, 6
  // digits, base32 secret 'JBSWY3DPEHPK3PXP'). If the Python output
  // ever changes, regenerate the table and update here.
  const referenceSecret = 'JBSWY3DPEHPK3PXP';
  const referenceVectors = <int, String>{
    1700000000: '324550',
    1700000030: '367665',
    1700000060: '870960',
    1700000090: '656781',
  };

  test('TOTP matches Python reference vectors', () {
    final client = PublicDirectClient();
    for (final entry in referenceVectors.entries) {
      final ts = DateTime.fromMillisecondsSinceEpoch(entry.key * 1000);
      final code = client.currentCode(secret: referenceSecret, atTime: ts);
      expect(code, entry.value,
          reason: 'TOTP mismatch at unix=${entry.key} (Dart=$code expected=${entry.value})');
    }
  });

  test('currentCode returns 6 digits and is non-empty for known secret', () {
    final client = PublicDirectClient();
    final code = client.currentCode(secret: referenceSecret);
    expect(code.length, 6);
    expect(int.tryParse(code), isNotNull);
  });

  test('currentCode returns empty string for empty secret', () {
    final client = PublicDirectClient();
    expect(client.currentCode(secret: ''), '');
  });

  test('newNonce produces 16+ char unique values', () {
    final client = PublicDirectClient();
    final a = client.newNonce();
    final b = client.newNonce();
    expect(a.length, greaterThanOrEqualTo(16));
    expect(b.length, greaterThanOrEqualTo(16));
    expect(a, isNot(equals(b)));
  });

  test('signedHeaders includes code and nonce', () {
    final client = PublicDirectClient();
    final headers = client.signedHeaders(secret: referenceSecret, nonce: 'fixed-nonce-12345678');
    expect(headers['X-PW-Code']?.length, 6);
    expect(headers['X-PW-Nonce'], 'fixed-nonce-12345678');
  });

  test('Config roundtrips through JSON', () {
    final cfg = PublicDirectConfig(
      host: 'yourname.167183.xyz',
      port: 47823,
      deviceId: 'pwdev-abc',
      totpSecret: referenceSecret,
      lastVerifiedAt: DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
    );
    final json = cfg.toJson();
    final restored = PublicDirectConfig.fromJson(json);
    expect(restored.host, cfg.host);
    expect(restored.port, cfg.port);
    expect(restored.deviceId, cfg.deviceId);
    expect(restored.totpSecret, cfg.totpSecret);
    expect(restored.lastVerifiedAt, cfg.lastVerifiedAt);
  });
}
