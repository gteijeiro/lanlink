import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

List<int> _decode64(String value) =>
    base64Url.decode(base64Url.normalize(value));

class CryptoEnvelope {
  static final _cipher = AesGcm.with256bits();

  static Future<Uint8List> encryptBinary(
    List<int> bytes,
    String key, {
    required String aad,
  }) async {
    final box = await _cipher.encrypt(
      bytes,
      secretKey: SecretKey(_decode64(key)),
      aad: utf8.encode(aad),
    );
    return Uint8List.fromList([
      ...box.nonce,
      ...box.mac.bytes,
      ...box.cipherText,
    ]);
  }

  static Future<Uint8List> decryptBinary(
    Uint8List bytes,
    String key, {
    required String aad,
  }) async {
    if (bytes.length < 28) throw const FormatException('Bloque inválido.');
    return Uint8List.fromList(
      await _cipher.decrypt(
        SecretBox(
          Uint8List.sublistView(bytes, 28),
          nonce: Uint8List.sublistView(bytes, 0, 12),
          mac: Mac(Uint8List.sublistView(bytes, 12, 28)),
        ),
        secretKey: SecretKey(_decode64(key)),
        aad: utf8.encode(aad),
      ),
    );
  }

  static Future<Map<String, String>> encrypt(
    List<int> bytes,
    String key, {
    String aad = '',
  }) async {
    final nonce = List<int>.generate(12, (_) => Random.secure().nextInt(256));
    final box = await _cipher.encrypt(
      bytes,
      secretKey: SecretKey(_decode64(key)),
      nonce: nonce,
      aad: utf8.encode(aad),
    );
    return {
      'n': base64Url.encode(box.nonce),
      'c': base64Url.encode(box.cipherText),
      'm': base64Url.encode(box.mac.bytes),
    };
  }

  static Future<Uint8List> decrypt(
    Map<String, dynamic> envelope,
    String key, {
    String aad = '',
  }) async {
    final box = SecretBox(
      _decode64(envelope['c'] as String),
      nonce: _decode64(envelope['n'] as String),
      mac: Mac(_decode64(envelope['m'] as String)),
    );
    return Uint8List.fromList(
      await _cipher.decrypt(
        box,
        secretKey: SecretKey(_decode64(key)),
        aad: utf8.encode(aad),
      ),
    );
  }

  static Future<Map<String, String>> encryptJson(
    Map<String, Object?> value,
    String key, {
    String aad = '',
  }) => encrypt(utf8.encode(jsonEncode(value)), key, aad: aad);

  static Future<Map<String, dynamic>> decryptJson(
    Map<String, dynamic> value,
    String key, {
    String aad = '',
  }) async =>
      jsonDecode(utf8.decode(await decrypt(value, key, aad: aad)))
          as Map<String, dynamic>;
}
