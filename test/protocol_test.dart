import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:cryptography/cryptography.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink/discovery_service.dart';
import 'package:lanlink/download_storage.dart';
import 'package:lanlink/transfer_service.dart';

class FailingDownloads extends DownloadStorage {
  FailingDownloads(Directory directory) : super(overrideDirectory: directory);
  @override
  Future<void> publish(File source, String name) async {
    throw const FileSystemException('No hay espacio para guardar el archivo.');
  }
}

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

Future<(int, Map<String, dynamic>)> postLocal(
  int port,
  String path,
  Map<String, Object?> body,
) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    return (
      response.statusCode,
      response.statusCode == 200
          ? Map<String, dynamic>.from(jsonDecode(text) as Map)
          : <String, dynamic>{},
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  test('El nombre de red se muestra en un formato legible', () {
    expect(friendlyDeviceName('MacBook-Pro.local'), 'MacBook Pro');
    expect(friendlyDeviceName('equipo_trabajo.LOCAL.'), 'equipo trabajo');
    expect(friendlyDeviceName('localhost', fallback: 'Android'), 'Android');
  });

  test('El nombre editado se anuncia y persiste al reiniciar', () async {
    final root = await Directory.systemTemp.createTemp('lanlink-name-test-');
    final storage = MemoryStore();
    final support = Directory('${root.path}/support');
    final first = TransferService(
      storage: storage,
      listenPort: 0,
      supportDirectory: support,
      receivedDirectory: Directory('${root.path}/received'),
      advertisedHosts: ['127.0.0.1'],
      identityName: 'Inicial',
    );
    addTearDown(() async {
      await first.dispose();
      await root.delete(recursive: true);
    });
    await first.start();
    await first.setDeviceName('  Mi   Mac  ');
    expect(first.deviceName, 'Mi Mac');
    expect(first.invitation.name, 'Mi Mac');
    await expectLater(first.setDeviceName('  '), throwsFormatException);
    await first.dispose();

    final second = TransferService(
      storage: storage,
      listenPort: 0,
      supportDirectory: support,
      receivedDirectory: Directory('${root.path}/received'),
      advertisedHosts: ['127.0.0.1'],
    );
    addTearDown(second.dispose);
    await second.start();
    expect(second.deviceName, 'Mi Mac');
  });

  test('Un anuncio Bonjour válido permite conectar sin QR', () {
    final service = BonsoirService(
      name: 'LanLink equipo-1',
      type: lanLinkServiceType,
      hostAddresses: ['192.168.1.8', '127.0.0.1', 'fe80::1'],
      port: 47829,
      attributes: {
        'v': '$protocolVersion',
        'id': 'equipo-1',
        'name': 'Mi Mac',
        'key': base64Url.encode(List<int>.filled(32, 4)),
      },
    );
    final invitation = invitationFromService(service);
    expect(invitation?.id, 'equipo-1');
    expect(invitation?.name, 'Mi Mac');
    expect(invitation?.hosts, ['192.168.1.8']);
    expect(
      invitationFromService(
        service.copyWith(attributes: {...service.attributes, 'key': 'bad'}),
      ),
      isNull,
    );
  });

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
    'Dos dispositivos se emparejan sin QR y transfieren un archivo completo',
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
      final nearbyInvite = NearbyInvitation(
        id: receiver.deviceId,
        name: receiver.deviceName,
        hosts: ['127.0.0.1'],
        port: receiver.port,
        publicKey: receiver.nearbyPublicKey,
      );
      await expectLater(sender.pairNearby(nearbyInvite), throwsStateError);
      expect(sender.peers, isEmpty);
      await receiver.setVisibleOnLan(true);
      receiver.onPairRequest = (_) async => true;
      receiver.onFileOffer = (_) async => true;
      await sender.pairNearby(nearbyInvite);
      expect(sender.peers.containsKey(receiver.deviceId), true);
      expect(receiver.peers.containsKey(sender.deviceId), true);

      final content = List<int>.generate(300000, (index) => index % 251);
      final receivedProgress = <TransferProgress>[];
      receiver.onProgress = receivedProgress.add;
      final original = File('${root.path}/sample.bin')
        ..writeAsBytesSync(content);
      await sender.sendFile(
        sender.peers[receiver.deviceId]!,
        XFile(original.path),
      );
      final received = File('${root.path}/received/sample.bin');
      expect(await received.exists(), true);
      expect(await received.readAsBytes(), content);
      expect(receivedProgress.last.fileName, 'sample.bin');
      expect(receivedProgress.last.finished, true);
    },
  );

  test(
    'Un fallo al guardar se informa a ambos lados y no marca éxito',
    () async {
      final root = await Directory.systemTemp.createTemp('lanlink-save-error-');
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
        downloadStorage: FailingDownloads(Directory('${root.path}/received')),
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
      String? receiveError;
      final progress = <TransferProgress>[];
      receiver.onTransferError = (message) => receiveError = message;
      receiver.onProgress = progress.add;
      await sender.pairInvitation(receiver.invitation);
      final file = await File('${root.path}/foto.jpg').writeAsBytes([1, 2, 3]);
      await expectLater(
        sender.sendFile(sender.peers[receiver.deviceId]!, XFile(file.path)),
        throwsA(isA<StateError>()),
      );
      expect(receiveError, contains('No hay espacio'));
      expect(progress.where((entry) => entry.finished), isEmpty);
    },
  );

  test('Solo la clave guardada puede actualizar la IP de un par', () async {
    final root = await Directory.systemTemp.createTemp('lanlink-reconnect-');
    final senderStore = MemoryStore();
    final receiverStore = MemoryStore();
    final sender = TransferService(
      storage: senderStore,
      listenPort: 0,
      supportDirectory: Directory('${root.path}/sender'),
      receivedDirectory: Directory('${root.path}/sender-files'),
      advertisedHosts: ['127.0.0.1'],
      identityName: 'Emisor',
    );
    final receiver = TransferService(
      storage: receiverStore,
      listenPort: 0,
      supportDirectory: Directory('${root.path}/receiver'),
      receivedDirectory: Directory('${root.path}/received'),
      advertisedHosts: ['127.0.0.1'],
      identityName: 'Receptor',
    );
    final impostor = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await sender.dispose();
      await receiver.dispose();
      await impostor.close(force: true);
      await root.delete(recursive: true);
    });
    await sender.start();
    await receiver.start();
    await receiver.setVisibleOnLan(true);
    receiver.onPairRequest = (_) async => true;
    receiver.onFileOffer = (_) async => true;
    await sender.pairNearby(
      NearbyInvitation(
        id: receiver.deviceId,
        name: receiver.deviceName,
        hosts: ['127.0.0.1'],
        port: receiver.port,
        publicKey: receiver.nearbyPublicKey,
      ),
    );
    final savedKey = senderStore.values['peer-${receiver.deviceId}'];
    final peer = sender.peers[receiver.deviceId]!;
    peer.host = '192.0.2.1';
    peer.port = 1;
    impostor.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(
          request.uri.path == '/identify/start'
              ? {'nonce': base64Url.encode(List<int>.filled(32, 8))}
              : {
                  'name': 'Equipo falso',
                  'port': impostor.port,
                  'proof': base64Url.encode(List<int>.filled(32, 0)),
                },
        ),
      );
      await request.response.close();
    });
    await expectLater(
      sender.reconnectKnownPeer(
        NearbyInvitation(
          id: receiver.deviceId,
          name: 'Equipo falso',
          hosts: ['127.0.0.1'],
          port: impostor.port,
          publicKey: receiver.nearbyPublicKey,
        ),
      ),
      throwsStateError,
    );
    expect(peer.host, '192.0.2.1');
    expect(peer.port, 1);
    expect(peer.name, 'Receptor');
    expect(peer.verified, false);
    expect(senderStore.values['peer-${receiver.deviceId}'], savedKey);

    await sender.reconnectKnownPeer(
      NearbyInvitation(
        id: receiver.deviceId,
        name: 'Nombre no confiable',
        hosts: ['127.0.0.1'],
        port: receiver.port,
        publicKey: receiver.nearbyPublicKey,
      ),
    );
    expect(peer.host, '127.0.0.1');
    expect(peer.port, receiver.port);
    expect(peer.name, 'Receptor');
    expect(peer.verified, true);
    expect(receiver.peers[sender.deviceId]!.verified, true);
    expect(senderStore.values['peer-${receiver.deviceId}'], savedKey);

    final original = File('${root.path}/after-reconnect.txt');
    await original.writeAsString('El vínculo sigue siendo el mismo.');
    await sender.sendFile(peer, XFile(original.path));
    expect(
      await File('${root.path}/received/after-reconnect.txt').readAsString(),
      'El vínculo sigue siendo el mismo.',
    );
  });

  test('Un desafío de identidad no se puede reutilizar', () async {
    final root = await Directory.systemTemp.createTemp('lanlink-replay-');
    final senderStore = MemoryStore();
    final receiverStore = MemoryStore();
    final sender = TransferService(
      storage: senderStore,
      listenPort: 0,
      supportDirectory: Directory('${root.path}/sender'),
      receivedDirectory: Directory('${root.path}/sender-files'),
      advertisedHosts: ['127.0.0.1'],
      identityName: 'Emisor',
    );
    final receiver = TransferService(
      storage: receiverStore,
      listenPort: 0,
      supportDirectory: Directory('${root.path}/receiver'),
      receivedDirectory: Directory('${root.path}/receiver-files'),
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
    await receiver.setVisibleOnLan(true);
    receiver.onPairRequest = (_) async => true;
    await sender.pairNearby(
      NearbyInvitation(
        id: receiver.deviceId,
        name: receiver.deviceName,
        hosts: ['127.0.0.1'],
        port: receiver.port,
        publicKey: receiver.nearbyPublicKey,
      ),
    );
    final (startStatus, start) = await postLocal(
      receiver.port,
      '/identify/start',
      {'from': sender.deviceId, 'to': receiver.deviceId},
    );
    expect(startStatus, 200);
    final serverNonce = start['nonce'] as String;
    final clientNonce = base64Url.encode(List<int>.filled(32, 5));
    final key = receiverStore.values['peer-${sender.deviceId}']!;
    final fields = [
      'lanlink-identify-v1',
      'request',
      sender.deviceId,
      receiver.deviceId,
      serverNonce,
      clientNonce,
      sender.deviceName,
      sender.port,
    ];
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode(jsonEncode(fields)),
      secretKey: SecretKey(base64Url.decode(base64Url.normalize(key))),
    );
    final body = <String, Object?>{
      'from': sender.deviceId,
      'to': receiver.deviceId,
      'serverNonce': serverNonce,
      'clientNonce': clientNonce,
      'name': sender.deviceName,
      'port': sender.port,
      'proof': base64Url.encode(mac.bytes),
    };
    final (firstStatus, _) = await postLocal(
      receiver.port,
      '/identify/finish',
      body,
    );
    final (replayStatus, _) = await postLocal(
      receiver.port,
      '/identify/finish',
      body,
    );
    expect(firstStatus, 200);
    expect(replayStatus, HttpStatus.forbidden);
  });

  test('Un emparejamiento nuevo no reemplaza una clave existente', () async {
    final root = await Directory.systemTemp.createTemp('lanlink-replace-');
    final senderStore = MemoryStore();
    final receiverStore = MemoryStore();
    final sender = TransferService(
      storage: senderStore,
      listenPort: 0,
      supportDirectory: Directory('${root.path}/sender'),
      receivedDirectory: Directory('${root.path}/sender-files'),
      advertisedHosts: ['127.0.0.1'],
      identityName: 'Emisor',
    );
    final receiver = TransferService(
      storage: receiverStore,
      listenPort: 0,
      supportDirectory: Directory('${root.path}/receiver'),
      receivedDirectory: Directory('${root.path}/receiver-files'),
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
    await receiver.setVisibleOnLan(true);
    receiver.onPairRequest = (_) async => true;
    await sender.pairNearby(
      NearbyInvitation(
        id: receiver.deviceId,
        name: receiver.deviceName,
        hosts: ['127.0.0.1'],
        port: receiver.port,
        publicKey: receiver.nearbyPublicKey,
      ),
    );
    final savedKey = receiverStore.values['peer-${sender.deviceId}'];
    final fakeStore = MemoryStore()..values['device-id'] = sender.deviceId;
    final fake = TransferService(
      storage: fakeStore,
      listenPort: 0,
      supportDirectory: Directory('${root.path}/fake'),
      receivedDirectory: Directory('${root.path}/fake-files'),
      advertisedHosts: ['127.0.0.1'],
      identityName: 'Emisor falso',
    );
    addTearDown(fake.dispose);
    await fake.start();
    await expectLater(
      fake.pairNearby(
        NearbyInvitation(
          id: receiver.deviceId,
          name: receiver.deviceName,
          hosts: ['127.0.0.1'],
          port: receiver.port,
          publicKey: receiver.nearbyPublicKey,
        ),
      ),
      throwsStateError,
    );
    expect(receiverStore.values['peer-${sender.deviceId}'], savedKey);
    expect(receiver.peers[sender.deviceId]!.name, 'Emisor');
  });
}
