import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink/crypto_envelope.dart';
import 'package:lanlink/sharing/quick_transfer.dart';

void main() {
  test(
    'Apple CryptoKit y Dart coinciden en X25519/HKDF/SAS y AES-GCM',
    () async {
      final vector = jsonDecode(
        await File('test/fixtures/apple_quick_crypto.json').readAsString(),
      ) as Map<String, dynamic>;
      final own = await X25519().newKeyPairFromSeed(
        quickDecode(vector['privateKey']),
      );
      final remote = quickDecode(vector['remotePublic']);
      final server = quickDecode(vector['serverNonce']);
      final client = quickDecode(vector['clientNonce']);
      final key = await quickKey(own, remote, server, client);
      expect(key, vector['key']);
      expect(quickCommit(vector['session'], remote, server), vector['commit']);
      expect(await quickCode(key, vector['session']), vector['code']);
      expect(
        await CryptoEnvelope.decryptJson(
          (vector['box'] as Map).cast<String, dynamic>(),
          key,
          aad: 'interop-v1',
        ),
        {'message': 'Hola desde Apple 🌎'},
      );
    },
  );
}
