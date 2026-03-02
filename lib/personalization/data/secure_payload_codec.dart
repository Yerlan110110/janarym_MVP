import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecurePayloadCodec {
  SecurePayloadCodec({
    FlutterSecureStorage? secureStorage,
    String keyName = 'janarym_secure_payload_key_v1',
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _keyName = keyName;

  static const _prefix = 'enc:v1';
  static const _prefixWithSeparator = 'enc:v1:';
  static const _keyBytesLength = 32;

  final FlutterSecureStorage _secureStorage;
  final String _keyName;
  final AesGcm _algorithm = AesGcm.with256bits();

  SecretKey? _cachedKey;
  Future<SecretKey>? _keyFuture;

  Future<String> encrypt(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return trimmed;
    if (trimmed.startsWith(_prefix)) return trimmed;
    final secretKey = await _loadSecretKey();
    final nonce = _randomBytes(12);
    final secretBox = await _algorithm.encrypt(
      utf8.encode(trimmed),
      secretKey: secretKey,
      nonce: nonce,
    );
    return [
      _prefix,
      base64Encode(secretBox.nonce),
      base64Encode(secretBox.cipherText),
      base64Encode(secretBox.mac.bytes),
    ].join(':');
  }

  Future<String> decrypt(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty || !trimmed.startsWith(_prefixWithSeparator)) {
      return trimmed;
    }
    final parts = trimmed.split(':');
    if (parts.length != 5) return trimmed;
    try {
      final secretKey = await _loadSecretKey();
      final secretBox = SecretBox(
        base64Decode(parts[3]),
        nonce: base64Decode(parts[2]),
        mac: Mac(base64Decode(parts[4])),
      );
      final clearBytes = await _algorithm.decrypt(
        secretBox,
        secretKey: secretKey,
      );
      return utf8.decode(clearBytes);
    } catch (_) {
      return trimmed;
    }
  }

  Future<SecretKey> _loadSecretKey() async {
    final existing = _cachedKey;
    if (existing != null) return existing;
    final inFlight = _keyFuture;
    if (inFlight != null) return inFlight;
    final future = _loadSecretKeyInternal();
    _keyFuture = future;
    try {
      final key = await future;
      _cachedKey = key;
      return key;
    } finally {
      if (identical(_keyFuture, future)) {
        _keyFuture = null;
      }
    }
  }

  Future<SecretKey> _loadSecretKeyInternal() async {
    try {
      final stored = await _secureStorage.read(key: _keyName);
      if (stored != null && stored.isNotEmpty) {
        return SecretKey(base64Decode(stored));
      }
      final bytes = _randomBytes(_keyBytesLength);
      await _secureStorage.write(key: _keyName, value: base64Encode(bytes));
      return SecretKey(bytes);
    } catch (_) {
      return SecretKey(_randomBytes(_keyBytesLength));
    }
  }

  Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256), growable: false),
    );
  }
}
