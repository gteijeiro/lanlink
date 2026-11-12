import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink/pairing_password.dart';

void main() {
  test('La única restricción es un mínimo de seis caracteres', () {
    for (final value in [
      '123456',
      'aaaaaa',
      '      ',
      '🔑🔑🔑🔑🔑🔑',
      'áéíóúñ',
    ]) {
      expect(() => validatePairingPassword(value), returnsNormally);
    }
    expect(() => validatePairingPassword('12345'), throwsFormatException);
    expect(() => validatePairingPassword('🔑🔑🔑🔑🔑'), throwsFormatException);
  });
  test('La fortaleza distingue claves comunes sin rechazarlas', () {
    expect(pairingPasswordStrength('123456'), 0);
    expect(pairingPasswordStrength('aaaaaa'), 0);
    expect(pairingPasswordStrength('abcabcabcabc'), 0);
    expect(pairingPasswordStrength('Nube!46RamaSol'), 3);
  });
  test('La clave generada es corta y varía', () {
    final values = List.generate(20, (_) => generatePairingPassword());
    expect(values.toSet().length, 20);
    expect(values.every((value) => value.length == 12), true);
  });
  test(
    'La derivación conserva claves antiguas y separa equipos y espacios',
    () async {
      const legacy = 'LL1-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
      expect(
        await derivePairingPassword(legacy, 'equipo'),
        legacy.substring(4),
      );
      final first = await derivePairingPassword('123456', 'uno');
      expect(await derivePairingPassword('123456', 'uno'), first);
      expect(await derivePairingPassword('123456', 'dos'), isNot(first));
      expect(await derivePairingPassword('123456 ', 'uno'), isNot(first));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
