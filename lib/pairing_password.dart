import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:characters/characters.dart';
import 'package:cryptography/cryptography.dart';

const pairingPasswordIterations = 600000;

int pairingPasswordLength(String value) => value.characters.length;

void validatePairingPassword(String value) {
  if (pairingPasswordLength(value) < 6) {
    throw const FormatException('La clave debe tener al menos 6 caracteres.');
  }
}

String generatePairingPassword() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
  final random = Random.secure();
  return List.generate(
    12,
    (_) => alphabet[random.nextInt(alphabet.length)],
  ).join();
}

/// Heuristic feedback only: this score never controls acceptance of a key.
int pairingPasswordStrength(String value) {
  final length = pairingPasswordLength(value);
  if (length < 6) return 0;
  final lower = value.toLowerCase();
  final unique = value.runes.toSet().length;
  const common = [
    '123456',
    'abcdef',
    'qwerty',
    'password',
    'contraseña',
    'contrasena',
  ];
  final sequence =
      '01234567890123456789'.contains(lower) ||
      '98765432109876543210'.contains(lower) ||
      'abcdefghijklmnopqrstuvwxyz'.contains(lower);
  var repeated = false;
  for (var size = 1; size <= value.length ~/ 2; size++) {
    if (value.length % size == 0 &&
        value.substring(0, size) * (value.length ~/ size) == value) {
      repeated = true;
      break;
    }
  }
  if (unique <= 2 || sequence || repeated || common.any(lower.startsWith)) {
    return 0;
  }
  final classes = [
    RegExp('[a-z]'),
    RegExp('[A-Z]'),
    RegExp('[0-9]'),
    RegExp(r'[^a-zA-Z0-9]'),
  ].where((pattern) => pattern.hasMatch(value)).length;
  if (length >= 18 && unique >= 7 ||
      length >= 12 && classes >= 2 && unique >= 7) {
    return 3;
  }
  if (length >= 10 && unique >= 5 ||
      length >= 8 && classes >= 3 && unique >= 5) {
    return 2;
  }
  return 1;
}

Future<String> derivePairingPassword(String password, String receiverId) async {
  validatePairingPassword(password);
  // Preserve existing LL1 credentials and interoperability with version 1.1.
  if (RegExp(r'^LL1-[A-Za-z0-9_-]{43}$').hasMatch(password)) {
    final legacy = password.substring(4);
    try {
      final decoded = base64Url.decode(base64Url.normalize(legacy));
      if (decoded.length == 32 &&
          base64Url.encode(decoded).replaceAll('=', '') == legacy) {
        return legacy;
      }
    } on FormatException {
      // An arbitrary user password resembling LL1 is still accepted literally.
    }
  }
  // Password stretching is done off the UI isolate. The salt separates devices.
  return Isolate.run(() async {
    final key =
        await Pbkdf2.hmacSha256(
          iterations: pairingPasswordIterations,
          bits: 256,
        ).deriveKey(
          secretKey: SecretKey(utf8.encode(password)),
          nonce: utf8.encode('lanlink-password-v2\u0000$receiverId'),
        );
    return base64Url.encode(await key.extractBytes()).replaceAll('=', '');
  });
}
