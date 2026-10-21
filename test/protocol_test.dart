import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink/transfer_service.dart';

class MemoryStore implements KeyValueStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  test('El QR conserva las direcciones y rechaza otro protocolo', () {
    final invitation = Invitation(
      id: 'device-1',
      name: 'Equipo',
      hosts: ['192.168.1.5', '10.0.0.2'],
      port: 47829,
      secret: base64Url.encode(List<int>.filled(32, 7)),
    );
    final parsed = Invitation.fromQr(invitation.qrValue);
    expect(parsed.id, invitation.id);
    expect(parsed.hosts, invitation.hosts);
    expect(parsed.secret, invitation.secret);
    expect(
      () => Invitation.fromQr('https://example.com'),
      throwsFormatException,
    );
  });

  test(
    'El cifrado detecta alteraciones y vincula el bloque a su posición',
    () async {
      final key = base64Url.encode(List<int>.filled(32, 9));
      final encrypted = await CryptoEnvelope.encrypt(
        utf8.encode('archivo'),
        key,
        aad: 'transfer:0',
      );
      expect(
        utf8.decode(
          await CryptoEnvelope.decrypt(encrypted, key, aad: 'transfer:0'),
        ),
        'archivo',
      );
      expect(
        CryptoEnvelope.decrypt(encrypted, key, aad: 'transfer:7'),
        throwsA(isA<Exception>()),
      );
      final modified = Map<String, dynamic>.from(encrypted)
        ..['c'] = base64Url.encode(utf8.encode('cambiado'));
      expect(
        CryptoEnvelope.decrypt(modified, key, aad: 'transfer:0'),
        throwsA(isA<Exception>()),
      );
    },
  );

  test(
    'Dos dispositivos se emparejan por QR y transfieren un archivo completo',
    () async {
      final root = await Directory.systemTemp.createTemp('lanlink-test-');
      final sender = TransferService(
        storage: MemoryStore(),
        listenPort: 0,
        supportDirectory: Directory('${root.path}/sender'),
        receivedDirectory: Directory('${root.path}/sender-files'),
        advertisedHosts: ['127.0.0.1'],
        identityName: 'Emisor',
      );
      final receiver = TransferService(
        storage: MemoryStore(),
        listenPort: 0,
        supportDirectory: Directory('${root.path}/receiver'),
        receivedDirectory: Directory('${root.path}/received'),
        advertisedHosts: ['127.0.0.1'],
        identityName: 'Receptor',
      );
      addTearDown(() async {
        await sender.dispose();
        await receiver.dispose();
        await root.delete(recursive: true);
      });
      await sender.start();
      await receiver.start();
      receiver.onPairRequest = (_) async => true;
      receiver.onFileOffer = (_) async => true;
      await sender.pair(receiver.invitation.qrValue);
      expect(sender.peers.containsKey(receiver.deviceId), true);
      expect(receiver.peers.containsKey(sender.deviceId), true);

      final content = List<int>.generate(300000, (index) => index % 251);
      final original = File('${root.path}/sample.bin')
        ..writeAsBytesSync(content);
      await sender.sendFile(
        sender.peers[receiver.deviceId]!,
        XFile(original.path),
      );
      final received = File('${root.path}/received/sample.bin');
      expect(await received.exists(), true);
      expect(await received.readAsBytes(), content);
    },
  );
}
