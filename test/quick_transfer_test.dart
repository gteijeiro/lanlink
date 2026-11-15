import 'dart:io';

import 'package:crypto/crypto.dart' as hashing;
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink/download_storage.dart';
import 'package:lanlink/sharing/quick_transfer.dart';

void main() {
  late Directory root;
  late QuickReceiver receiver;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lanlink-quick-test');
    receiver = QuickReceiver(
      downloads: DownloadStorage(
        overrideDirectory: Directory('${root.path}/received'),
      ),
      name: () => 'Receptor',
      enabled: () => true,
    );
  });
  tearDown(() async {
    await receiver.dispose();
    await root.delete(recursive: true);
  });

  test('Envío múltiple y vacío exige códigos coincidentes y verifica el archivo completo', () async {
    final first = File('${root.path}/video.mp4');
    final empty = File('${root.path}/empty.txt');
    await first.writeAsBytes(List.generate(300000, (index) => index % 251));
    await empty.create();
    String? offeredCode;
    receiver.onOffer = (offer) async {
      offeredCode = offer.code;
      expect(offer.files.length, 2);
      return true;
    };
    final sender = QuickSender(name: 'Emisor')
      ..confirmCode = (code) async => code == offeredCode;
    await sender.send([XFile(first.path), XFile(empty.path)], receiver.handle);
    final results = await receiver.downloads.list();
    expect(results.map((file) => file.name).toSet(), {
      'video.mp4',
      'empty.txt',
    });
    final downloaded = File(
      results.firstWhere((file) => file.name == 'video.mp4').location,
    );
    expect(
      hashing.sha256.convert(await downloaded.readAsBytes()),
      hashing.sha256.convert(await first.readAsBytes()),
    );
  });

  test('Una revelación alterada no llega a mostrar una oferta', () async {
    final file = File('${root.path}/private.txt');
    await file.writeAsString('privado');
    var offered = false;
    receiver.onOffer = (_) async {
      offered = true;
      return true;
    };
    final sender = QuickSender(name: 'Emisor')..confirmCode = (_) async => true;
    await expectLater(
      sender.send([XFile(file.path)], (path, body) async {
        final reply = await receiver.handle(path, body);
        if (path == '/quick/reveal') reply['nonce'] = quickRandom(32);
        return reply;
      }),
      throwsStateError,
    );
    expect(offered, false);
    expect(await receiver.downloads.list(), isEmpty);
  });

  test(
    'Sin confirmación local no se publican archivos y se cancela la sesión',
    () async {
      final file = File('${root.path}/private.txt');
      await file.writeAsString('privado');
      receiver.onOffer = (_) async => true;
      final sender = QuickSender(name: 'Emisor')
        ..confirmCode = (_) async => false;
      await expectLater(
        sender.send([XFile(file.path)], receiver.handle),
        throwsStateError,
      );
      expect(await receiver.downloads.list(), isEmpty);
    },
  );

  test(
    'Un acuse perdido puede reintentarse sin duplicar ni corromper el archivo',
    () async {
      final file = File('${root.path}/note.txt');
      await file.writeAsString('hola');
      receiver.onOffer = (_) async => true;
      var dropped = false;
      final sender = QuickSender(name: 'Emisor')
        ..confirmCode = (_) async => true;
      await sender.send([XFile(file.path)], (path, body) async {
        final result = await receiver.handle(path, body);
        if (path == '/quick/chunk' && !dropped) {
          dropped = true;
          throw const SocketException('acuse perdido');
        }
        return result;
      });
      final results = await receiver.downloads.list();
      expect(results.length, 1);
      expect(await File(results.single.location).readAsString(), 'hola');
    },
  );

  test(
    'Una recepción aceptada termina aunque se desactive la visibilidad',
    () async {
      var enabled = true;
      final leases = <bool>[];
      await receiver.dispose();
      receiver = QuickReceiver(
        downloads: receiver.downloads,
        name: () => 'Receptor',
        enabled: () => enabled,
      );
      receiver.onOffer = (_) async => true;
      receiver.onSessionState = (_, active) => leases.add(active);
      final file = File('${root.path}/lease.txt');
      await file.writeAsString('conexión conservada');
      final sender = QuickSender(name: 'Emisor')
        ..confirmCode = (_) async {
          enabled = false;
          return true;
        };
      await sender.send([XFile(file.path)], receiver.handle);
      expect((await receiver.downloads.list()).length, 1);
      expect(leases, [true]);
      await expectLater(receiver.handle('/quick/hello', {}), throwsStateError);
      await receiver.dispose();
      expect(leases, [true, false]);
    },
  );

  test('La recepción desactivada y los límites no permiten abrir sesiones ilimitadas', () async {
    for (var i = 0; i < 4; i++) {
      await receiver.handle('/quick/hello', {});
    }
    await expectLater(receiver.handle('/quick/hello', {}), throwsStateError);
    final disabled = QuickReceiver(
      downloads: receiver.downloads,
      name: () => 'Oculto',
      enabled: () => false,
    );
    await expectLater(disabled.handle('/quick/hello', {}), throwsStateError);
    await disabled.dispose();
  });
}
