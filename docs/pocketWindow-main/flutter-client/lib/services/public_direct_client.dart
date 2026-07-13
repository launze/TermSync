// Public-direct client slot module for PocketWindow Flutter.
//
// Mirrors the desktop-side totp_auth.py behaviour:
//   * 30-second TOTP step, 6 digits, HMAC-SHA1, base32 secret
//   * ±1 step tolerance on the desktop verifier
//   * 16+ char random nonce for replay protection
//
// Persistence is via SharedPreferences so the configuration survives
// app restarts. The class is intentionally side-effect free at import
// time so unit tests can construct it without async setup.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:shared_preferences/shared_preferences.dart';

class PublicDirectConfig {
  final String host;
  final int port;
  final String deviceId;
  final String totpSecret;
  final DateTime? lastVerifiedAt;

  const PublicDirectConfig({
    required this.host,
    required this.port,
    required this.deviceId,
    required this.totpSecret,
    this.lastVerifiedAt,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'host': host,
        'port': port,
        'device_id': deviceId,
        'totp_secret': totpSecret,
        'last_verified_at': lastVerifiedAt?.millisecondsSinceEpoch ?? 0,
      };

  factory PublicDirectConfig.fromJson(Map<String, dynamic> json) {
    return PublicDirectConfig(
      host: (json['host'] ?? '').toString(),
      port: int.tryParse((json['port'] ?? 0).toString()) ?? 0,
      deviceId: (json['device_id'] ?? '').toString(),
      totpSecret: (json['totp_secret'] ?? '').toString(),
      lastVerifiedAt: json['last_verified_at'] is int
          ? DateTime.fromMillisecondsSinceEpoch(json['last_verified_at'] as int)
          : null,
    );
  }

  /// Parse a QR payload emitted by the desktop UI's "公网直连" tab.
  /// Expected shape:
  ///   {v:1, type:'pw-direct', device_id, direct_host, direct_port, totp_secret}
  /// Returns null if any required field is missing or malformed.
  static PublicDirectConfig? fromQrPayload(Map<String, dynamic> payload) {
    if (payload['type']?.toString() != 'pw-direct') return null;
    final host = (payload['direct_host'] ?? '').toString().trim();
    final port = int.tryParse((payload['direct_port'] ?? 0).toString()) ?? 0;
    final deviceId = (payload['device_id'] ?? '').toString().trim();
    final secret = (payload['totp_secret'] ?? '').toString().trim();
    if (host.isEmpty || port <= 0 || deviceId.isEmpty || secret.isEmpty) {
      return null;
    }
    return PublicDirectConfig(
      host: host,
      port: port,
      deviceId: deviceId,
      totpSecret: secret,
    );
  }
}

/// One-shot bundle returned by [PublicDirectClient.tryPrepare]. Holds
/// everything a caller needs to plug into a SignalingService for a
/// public-direct connection attempt.
class PublicDirectAttempt {
  final String serverUrl;
  final String totpCode;
  final String totpNonce;
  final PublicDirectConfig config;

  const PublicDirectAttempt({
    required this.serverUrl,
    required this.totpCode,
    required this.totpNonce,
    required this.config,
  });
}

class PublicDirectClient {
  static const _prefsKey = 'pw.public_direct.config';
  static const _totpStepSeconds = 30;
  static const _totpDigits = 6;

  final Random _random = Random.secure();
  PublicDirectConfig? _config;

  PublicDirectConfig? get config => _config;

  Future<PublicDirectConfig?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) {
      _config = null;
      return null;
    }
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      _config = PublicDirectConfig.fromJson(decoded);
      return _config;
    } catch (_) {
      _config = null;
      return null;
    }
  }

  Future<void> save(PublicDirectConfig config) async {
    _config = config;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(config.toJson()));
  }

  Future<void> clear() async {
    _config = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }

  /// Compute the current 6-digit TOTP code for the given base32 secret.
  /// Matches totp_auth.current_code on the desktop side exactly:
  ///   counter = floor(unix_seconds / 30)
  ///   HMAC-SHA1(key=base32_decode(secret), msg=counter_as_8_byte_BE)
  ///   dynamic truncation, mod 10^digits, zero-padded.
  String currentCode({String? secret, DateTime? atTime}) {
    final effectiveSecret = (secret ?? _config?.totpSecret ?? '').trim();
    if (effectiveSecret.isEmpty) return '';
    final key = _decodeBase32(effectiveSecret);
    if (key.isEmpty) return '';
    final now = atTime ?? DateTime.now();
    final counter =
        now.millisecondsSinceEpoch ~/ 1000 ~/ _totpStepSeconds;
    final code = _hotp(key, counter);
    return code;
  }

  String newNonce() {
    final bytes = Uint8List(16);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Map<String, String> signedHeaders({String? secret, String? nonce}) {
    final code = currentCode(secret: secret);
    final candidate = (nonce ?? '').trim();
    final value = candidate.isNotEmpty ? candidate : newNonce();
    return <String, String>{
      'X-PW-Code': code,
      'X-PW-Nonce': value,
    };
  }

  /// Optional reachability check: sends a HEAD-equivalent GET to
  /// /api/direct/ping with the current TOTP code + nonce. The desktop
  /// server treats this as a 401 unless the code is fresh; we only
  /// need to verify the socket is open, not pass auth.
  Future<bool> testConnection({Duration timeout = const Duration(seconds: 3)}) async {
    final cfg = _config;
    if (cfg == null || cfg.host.isEmpty || cfg.port <= 0) return false;
    // Simple TCP probe — we don't need a real HTTP request because the
    // desktop's lan-direct server accepts any TCP connection and
    // responds with HTTP on the websocket path. A successful connect
    // means the frpc forwarding is alive.
    try {
      final socket = await Socket.connect(cfg.host, cfg.port, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Convenience helper for connection sites: load the saved config,
  /// run a short TCP probe, and return everything the caller needs to
  /// hand off to a SignalingService — namely the ws:// URL plus a
  /// fresh TOTP code/nonce. Returns null when no usable config exists,
  /// when the device id does not match, or when the probe times out.
  ///
  /// `expectedDeviceId` lets the caller make sure the saved config
  /// belongs to the device they are about to connect to (we do not
  /// want the public-direct config from device A to be tried when the
  /// user is launching a session against device B).
  static Future<PublicDirectAttempt?> tryPrepare({
    required String expectedDeviceId,
    Duration probeTimeout = const Duration(seconds: 1),
  }) async {
    final client = PublicDirectClient();
    final cfg = await client.load();
    if (cfg == null) return null;
    if (cfg.host.isEmpty || cfg.port <= 0 || cfg.totpSecret.isEmpty) return null;
    final wantedDevice = expectedDeviceId.trim();
    if (wantedDevice.isNotEmpty && cfg.deviceId.trim() != wantedDevice) {
      return null;
    }
    final reachable = await client.testConnection(timeout: probeTimeout);
    if (!reachable) return null;
    final code = client.currentCode(secret: cfg.totpSecret);
    if (code.isEmpty) return null;
    return PublicDirectAttempt(
      serverUrl: 'ws://${cfg.host}:${cfg.port}',
      totpCode: code,
      totpNonce: client.newNonce(),
      config: cfg,
    );
  }

  // --- internals -------------------------------------------------------

  String _hotp(Uint8List key, int counter) {
    final msg = ByteData(8)..setUint64(0, counter, Endian.big);
    final hmac = crypto.Hmac(crypto.sha1, key);
    final digest = hmac.convert(msg.buffer.asUint8List()).bytes;
    final offset = digest[digest.length - 1] & 0x0F;
    final binary = ((digest[offset] & 0x7F) << 24) |
        ((digest[offset + 1] & 0xFF) << 16) |
        ((digest[offset + 2] & 0xFF) << 8) |
        (digest[offset + 3] & 0xFF);
    const modulo = 1000000;
    final code = binary % modulo;
    return code.toString().padLeft(_totpDigits, '0');
  }

  Uint8List _decodeBase32(String input) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final cleaned = input.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');
    if (cleaned.isEmpty) return Uint8List(0);
    final padded = cleaned + '=' * ((8 - cleaned.length % 8) % 8);
    final output = <int>[];
    var buffer = 0;
    var bitsLeft = 0;
    for (final ch in padded.codeUnits) {
      if (ch == 0x3D /* '=' */) break;
      final value = alphabet.indexOf(String.fromCharCode(ch));
      if (value < 0) {
        return Uint8List(0);
      }
      buffer = (buffer << 5) | value;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        bitsLeft -= 8;
        output.add((buffer >> bitsLeft) & 0xFF);
      }
    }
    return Uint8List.fromList(output);
  }
}
