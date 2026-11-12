import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink/transfer_service.dart';

class TestStore implements KeyValueStore {
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

class Device {
  Device(this.root, this.name);
  final Directory root;
  final String name;
  final store = TestStore();
  late TransferService service;
  Future<void> start() async {
    service = TransferService(
      storage: store,
      listenPort: 0,
      supportDirectory: Directory('${root.path}/$name/support'),
      receivedDirectory: Directory('${root.path}/$name/files'),
      identityName: name,
      advertisedHosts: ['127.0.0.1'],
    );
    await service.start();
    service.onPairRequest = (_) async => true;
    service.onFileOffer = (_) async => true;
    await service.setVisibleOnLan(true);
  }

  NearbyInvitation get invite => NearbyInvitation(
    id: service.deviceId,
    name: service.deviceName,
    hosts: ['127.0.0.1'],
    port: service.port,
    publicKey: service.nearbyPublicKey,
  );
  Future<void> restart() async {
    await service.dispose();
    await start();
  }
}

Future<Map<String, dynamic>> post(
  int port,
  String path,
  Map<String, dynamic> body,
) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != 200) {
      throw StateError('HTTP ${response.statusCode}: $text');
    }
    return (jsonDecode(text) as Map).cast<String, dynamic>();
  } finally {
    client.close(force: true);
  }
}

void main() {
  late Directory root;
  late Device a;
  late Device b;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lanlink-trust-');
    a = Device(root, 'A');
    b = Device(root, 'B');
    await a.start();
    await b.start();
  });
  tearDown(() async {
    await a.service.dispose();
    await b.service.dispose();
    await root.delete(recursive: true);
  });

  test('La clave permite vincular sin aprobación, pero no otorga confianza para archivos', () async {
    final key = await b.service.enablePairingKey();
    b.service.onPairRequest = (_) =>
        throw StateError('No debería pedir aprobación');
    await a.service.pairNearby(b.invite, pairingKey: key);
    expect(a.service.peers.containsKey(b.service.deviceId), true);
    expect(b.service.peers[a.service.deviceId]!.trustedForFiles, false);
    b.service.onFileOffer = (_) async => false;
    final file = await File('${root.path}/prueba.txt')
        .writeAsString('contenido');
    await expectLater(
      a.service.sendFile(
        a.service.peers[b.service.deviceId]!,
        XFile(file.path),
      ),
      throwsStateError,
    );
    final json = await File('${root.path}/B/support/peers.json').readAsString();
    expect(json.contains(key), false);
  });

  test('Clave incorrecta, desactivada o renovada no vincula ni sustituye a otro equipo', () async {
    final oldKey = await b.service.enablePairingKey();
    final wrongKey = await a.service.enablePairingKey();
    b.service.onPairRequest = (_) =>
        throw StateError('No debería pedir aprobación');
    await expectLater(
      a.service.pairNearby(b.invite, pairingKey: wrongKey),
      throwsStateError,
    );
    expect(b.service.peers, isEmpty);
    final newKey = await b.service.rotatePairingKey();
    await expectLater(
      a.service.pairNearby(b.invite, pairingKey: oldKey),
      throwsStateError,
    );
    await b.service.disablePairingKey();
    await expectLater(
      a.service.pairNearby(b.invite, pairingKey: newKey),
      throwsStateError,
    );
    final enabledKey = await b.service.enablePairingKey();
    await b.restart();
    expect(b.service.pairingKey, enabledKey);
    b.service.onPairRequest = (_) =>
        throw StateError('No debería pedir aprobación');
    await a.service.pairNearby(b.invite, pairingKey: enabledKey);
    await expectLater(
      a.service.pairNearby(b.invite, pairingKey: enabledKey),
      throwsStateError,
    );
    expect(b.service.peers.length, 1);
  });

  test(
    'Los intentos de clave están limitados y nunca saltan a aprobación manual',
    () async {
      final correct = await b.service.enablePairingKey();
      final wrong =
          'LL1-${base64Url.encode(List.filled(32, 37)).replaceAll('=', '')}';
      b.service.onPairRequest = (_) =>
          throw StateError('No debería pedir aprobación');
      for (var i = 0; i < 10; i++) {
        await expectLater(
          a.service.pairNearby(b.invite, pairingKey: wrong),
          throwsStateError,
        );
      }
      await expectLater(
        a.service.pairNearby(b.invite, pairingKey: correct),
        throwsStateError,
      );
      expect(b.service.peers, isEmpty);
    },
  );

  test(
    'La confianza persiste, acepta archivos sin diálogo y puede desactivarse',
    () async {
      await a.service.pairInvitation(b.service.invitation);
      await b.service.setPeerTrusted(a.service.deviceId, true);
      await b.restart();
      expect(b.service.peers[a.service.deviceId]!.trustedForFiles, true);
      a.service.peers[b.service.deviceId]!.port = b.service.port;
      b.service.onFileOffer = (_) => throw StateError('No debería preguntar');
      final file = await File('${root.path}/archivo.txt')
          .writeAsString('verificado');
      await a.service.sendFile(
        a.service.peers[b.service.deviceId]!,
        XFile(file.path),
      );
      expect(
        await File('${root.path}/B/files/archivo.txt').readAsString(),
        'verificado',
      );
      await b.service.setPeerTrusted(a.service.deviceId, false);
      b.service.onFileOffer = (_) async => false;
      await expectLater(
        a.service.sendFile(
          a.service.peers[b.service.deviceId]!,
          XFile(file.path),
        ),
        throwsStateError,
      );
      expect((await b.service.receivedFiles()).length, 1);
    },
  );

  test(
    'Desvincular borra ambos vínculos y la confianza sin borrar archivos',
    () async {
      await a.service.pairInvitation(b.service.invitation);
      await b.service.setPeerTrusted(a.service.deviceId, true);
      final oldPairingKey = await b.service.enablePairingKey();
      final file = await File('${root.path}/foto.jpg').writeAsBytes([1, 2, 3]);
      await a.service.sendFile(
        a.service.peers[b.service.deviceId]!,
        XFile(file.path),
      );
      await a.service.removePeer(b.service.deviceId);
      expect(a.service.peers, isEmpty);
      expect(b.service.peers, isEmpty);
      expect(a.service.pendingRevocations, isEmpty);
      expect(b.service.pairingKey, isNot(oldPairingKey));
      expect(await File('${root.path}/B/files/foto.jpg').readAsBytes(), [
        1,
        2,
        3,
      ]);
      await a.service.pairInvitation(b.service.invitation);
      expect(b.service.peers[a.service.deviceId]!.trustedForFiles, false);
    },
  );

  test('La desvinculación pendiente sobrevive reinicios y encuentra una nueva dirección', () async {
    await a.service.pairInvitation(b.service.invitation);
    final id = b.service.deviceId;
    await b.service.dispose();
    await a.service.removePeer(id);
    expect(a.service.peers, isEmpty);
    expect(a.service.pendingRevocations, {id});
    await a.restart();
    await b.start();
    expect(a.service.pendingRevocations, {id});
    expect(b.service.peers.containsKey(a.service.deviceId), true);
    await a.service.reconcileRevocations([
      NearbyInvitation(
        id: b.service.deviceId,
        name: 'Anuncio falso',
        hosts: ['127.0.0.1'],
        port: 1,
        publicKey: b.service.nearbyPublicKey,
      ),
      b.invite,
    ]);
    expect(a.service.pendingRevocations, isEmpty);
    expect(b.service.peers, isEmpty);
    await b.restart();
    expect(b.service.peers, isEmpty);
  });

  test(
    'Una desvinculación falsificada o antigua no elimina un vínculo nuevo',
    () async {
      await a.service.pairInvitation(b.service.invitation);
      final targetPort = b.service.port;
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      Map<String, dynamic>? captured;
      proxy.listen((request) async {
        captured = (jsonDecode(await utf8.decoder.bind(request).join()) as Map)
            .cast<String, dynamic>();
        final response = await post(targetPort, '/unpair', captured!);
        request.response.write(jsonEncode(response));
        await request.response.close();
      });
      a.service.peers[b.service.deviceId]!.port = proxy.port;
      await a.service.removePeer(b.service.deviceId);
      expect(captured, isNotNull);
      await a.service.pairInvitation(b.service.invitation);
      final old = Map<String, dynamic>.from(captured!);
      final corrupt = Map<String, dynamic>.from(old);
      corrupt['box'] = {
        ...(old['box'] as Map),
        'm': base64Url.encode(List.filled(16, 0)),
      };
      await expectLater(post(targetPort, '/unpair', corrupt), throwsStateError);
      expect(b.service.peers.containsKey(a.service.deviceId), true);
      await post(targetPort, '/unpair', old);
      expect(b.service.peers.containsKey(a.service.deviceId), true);
      b.service.onFileOffer = (_) async => true;
      final file = await File('${root.path}/nuevo.txt')
          .writeAsString('vínculo nuevo');
      await a.service.sendFile(
        a.service.peers[b.service.deviceId]!,
        XFile(file.path),
      );
      expect(
        await File('${root.path}/B/files/nuevo.txt').readAsString(),
        'vínculo nuevo',
      );
    },
  );

  test('La confianza no acepta una oferta que no se autentique', () async {
    await a.service.pairInvitation(b.service.invitation);
    await b.service.setPeerTrusted(a.service.deviceId, true);
    b.service.onFileOffer = (_) =>
        throw StateError('No debe llegar al diálogo');
    final forged = await CryptoEnvelope.encryptJson(
      {'name': 'falso.txt', 'size': 0, 'hash': '0' * 64},
      base64Url.encode(List.filled(32, 9)),
      aad: 'offer-v1',
    );
    await expectLater(
      post(b.service.port, '/offer', {
        'peer': a.service.deviceId,
        'box': forged,
      }),
      throwsStateError,
    );
    expect(await b.service.receivedFiles(), isEmpty);
  });

  test('El receptor rechaza el reemplazo de un ID aunque conozcan la clave general', () async {
    final key = await b.service.enablePairingKey();
    await a.service.pairNearby(b.invite, pairingKey: key);
    final impostor = Device(root, 'C');
    impostor.store.values['device-id'] = a.service.deviceId;
    await impostor.start();
    addTearDown(() => impostor.service.dispose());
    await expectLater(
      impostor.service.pairNearby(b.invite, pairingKey: key),
      throwsStateError,
    );
    expect(impostor.service.peers, isEmpty);
    expect(b.service.peers.length, 1);
    final file = await File('${root.path}/real.txt').writeAsString('original');
    await a.service.sendFile(
      a.service.peers[b.service.deviceId]!,
      XFile(file.path),
    );
    expect(
      await File('${root.path}/B/files/real.txt').readAsString(),
      'original',
    );
  });

  test(
    'Un acuse perdido se recupera después de reiniciar el receptor',
    () async {
      await a.service.pairInvitation(b.service.invitation);
      final targetPort = b.service.port;
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      proxy.listen((request) async {
        final body = (jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map).cast<String, dynamic>();
        await post(targetPort, '/unpair', body);
        request.response.statusCode = 503;
        await request.response.close();
      });
      a.service.peers[b.service.deviceId]!.port = proxy.port;
      await a.service.removePeer(b.service.deviceId);
      expect(b.service.peers, isEmpty);
      expect(a.service.pendingRevocations, {b.service.deviceId});
      await b.restart();
      await a.service.retryPendingRevocations(
        invitation: b.invite,
        force: true,
      );
      expect(a.service.pendingRevocations, isEmpty);
    },
  );

  test('Un equipo invisible recibe la revocación al encontrar al otro tras cambiar de red', () async {
    await a.service.pairInvitation(b.service.invitation);
    await b.service.dispose();
    await a.service.removePeer(b.service.deviceId);
    expect(a.service.pendingRevocations, {b.service.deviceId});
    await b.start();
    await b.service.setVisibleOnLan(false);
    await b.service.reconnectKnownPeer(a.invite);
    expect(b.service.peers, isEmpty);
    expect(a.service.pendingRevocations, isEmpty);
    expect(b.service.pendingRevocations, isEmpty);
  });

  test('Se vincula con una clave elegida de seis caracteres y se conserva al reiniciar', () async {
    await b.service.setPairingKey('123456');
    await b.restart();
    expect(b.service.pairingKey, '123456');
    b.service.onPairRequest = (_) =>
        throw StateError('No debe pedir aprobación');
    await a.service.pairNearby(b.invite, pairingKey: '123456');
    expect(b.service.peers.containsKey(a.service.deviceId), true);
    await b.service.setPairingKey('      ');
    expect(b.service.pairingKey, '      ');
    final file = await File('${root.path}/despues.txt')
        .writeAsString('vínculo conservado');
    await a.service.sendFile(
      a.service.peers[b.service.deviceId]!,
      XFile(file.path),
    );
    expect(
      await File('${root.path}/B/files/despues.txt').readAsString(),
      'vínculo conservado',
    );
  });

  test('Se conservan las claves LL1 de la versión anterior', () async {
    await b.service.dispose();
    const legacy = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    b.store.values['pairing-key'] = legacy;
    await b.start();
    expect(b.service.pairingKey, 'LL1-$legacy');
    await a.service.pairNearby(b.invite, pairingKey: 'LL1-$legacy');
    await b.service.disablePairingKey();
    expect(b.store.values['pairing-key'], isNull);
    expect(b.store.values['pairing-key-v2'], isNull);
  });

  test(
    'Los vínculos de versiones anteriores no son de confianza por defecto',
    () {
      expect(
        Peer.fromJson({
          'id': 'old',
          'name': 'Anterior',
          'host': '127.0.0.1',
          'port': 47829,
        }).trustedForFiles,
        false,
      );
    },
  );
}
