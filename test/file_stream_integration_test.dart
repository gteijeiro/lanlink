import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashing;
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink/file_stream.dart';
import 'package:lanlink/transfer_service.dart';

class _Store implements KeyValueStore {
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
  late Directory root;
  late TransferService sender, receiver;
  late _Store store;
  late HttpServer proxy;
  late HttpClient client;
  final paths = <String>[];
  var legacy = false;
  var tamperAck = false;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lanlink-stream-');
    store = _Store();
    TransferService device(String name, _Store storage) => TransferService(
      storage: storage,
      listenPort: 0,
      supportDirectory: Directory('${root.path}/$name-support'),
      receivedDirectory: Directory('${root.path}/$name-files'),
      identityName: name,
      advertisedHosts: ['127.0.0.1'],
    );
    sender = device('sender', store);
    receiver = device('receiver', _Store());
    await sender.start();
    await receiver.start();
    receiver.onPairRequest = (_) async => true;
    receiver.onFileOffer = (_) async => true;
    await sender.pairInvitation(receiver.invitation);
    legacy = false;
    tamperAck = false;
    paths.clear();
    client = HttpClient();
    proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    proxy.listen((request) async {
      try {
        paths.add(request.uri.path);
        final upstream = await client.postUrl(
          Uri(
            scheme: 'http',
            host: '127.0.0.1',
            port: receiver.port,
            path: request.uri.path,
            query: request.uri.query,
          ),
        );
        upstream.headers.contentType = request.headers.contentType;
        if (legacy && request.uri.path == '/offer') {
          // Model an older receiver: the authenticated capability is absent.
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          final key = store.values['peer-${receiver.deviceId}']!;
          final offer =
              await CryptoEnvelope.decryptJson(
                  (body['box'] as Map).cast<String, dynamic>(),
                  key,
                  aad: 'offer-v1',
                )
                ..remove('fileStream');
          body['box'] = await CryptoEnvelope.encryptJson(
            offer,
            key,
            aad: 'offer-v1',
          );
          upstream.write(jsonEncode(body));
        } else {
          await upstream.addStream(request);
        }
        final reply = await upstream.close();
        request.response.statusCode = reply.statusCode;
        if (tamperAck && request.uri.path == '/file-stream') {
          final ack = jsonDecode(await utf8.decoder.bind(reply).join()) as Map;
          ack['m'] = base64Url.encode(List<int>.filled(16, 0));
          request.response.write(jsonEncode(ack));
        } else {
          await request.response.addStream(reply);
        }
      } finally {
        await request.response.close();
      }
    });
    sender.peers[receiver.deviceId]!.port = proxy.port;
  });

  tearDown(() async {
    await sender.dispose();
    await receiver.dispose();
    client.close(force: true);
    await proxy.close(force: true);
    await root.delete(recursive: true);
  });

  test('A multi-megabyte file uses one streaming request and final verified acknowledgement', () async {
    final content = List.generate(2 * 1024 * 1024 + 17, (i) => i % 251);
    final file = await File('${root.path}/video.bin').writeAsBytes(content);
    final progress = <TransferProgress>[];
    sender.onProgress = progress.add;
    await sender.sendFile(sender.peers[receiver.deviceId]!, XFile(file.path));
    expect(paths, ['/offer', '/file-stream']);
    expect(
      await File('${root.path}/receiver-files/video.bin').readAsBytes(),
      content,
    );
    expect(progress.where((entry) => entry.finished).length, 1);
    expect(progress.last.finished, true);
    expect((await receiver.receivedFiles()).length, 1);
  });

  test(
    'Legacy peers keep receiving encrypted chunks, including empty files',
    () async {
      legacy = true;
      final content = List.generate(300000, (i) => i % 251);
      final file = await File('${root.path}/legacy.bin').writeAsBytes(content);
      final empty = await File('${root.path}/empty.txt').create();
      await sender.sendFile(sender.peers[receiver.deviceId]!, XFile(file.path));
      await sender.sendFile(
        sender.peers[receiver.deviceId]!,
        XFile(empty.path),
      );
      expect(paths.where((path) => path == '/file-stream'), isEmpty);
      expect(paths.where((path) => path == '/chunk').length, 4);
      expect(
        await File('${root.path}/receiver-files/legacy.bin').readAsBytes(),
        content,
      );
      expect(await File('${root.path}/receiver-files/empty.txt').length(), 0);
    },
  );

  test('An authenticated empty stream succeeds', () async {
    final empty = await File('${root.path}/empty.txt').create();
    await sender.sendFile(sender.peers[receiver.deviceId]!, XFile(empty.path));
    expect(paths, ['/offer', '/file-stream']);
    expect(await File('${root.path}/receiver-files/empty.txt').length(), 0);
  });

  test(
    'An altered final acknowledgement never marks the sender as finished',
    () async {
      tamperAck = true;
      final file = await File('${root.path}/ack.txt').writeAsString('verified');
      final progress = <TransferProgress>[];
      sender.onProgress = progress.add;
      await expectLater(
        sender.sendFile(sender.peers[receiver.deviceId]!, XFile(file.path)),
        throwsA(isA<Exception>()),
      );
      expect(progress.where((entry) => entry.finished), isEmpty);
    },
  );

  Future<(String, String)> offer(int size, String hash) async {
    final key = store.values['peer-${receiver.deviceId}']!;
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${receiver.port}/offer'),
    );
    request.write(
      jsonEncode({
        'peer': sender.deviceId,
        'box': await CryptoEnvelope.encryptJson(
          {
            'name': 'check.bin',
            'size': size,
            'hash': hash,
            'fileStream': fileStreamVersion,
          },
          key,
          aad: 'offer-v1',
        ),
      }),
    );
    final response = await request.close();
    final decision = await CryptoEnvelope.decryptJson(
      (jsonDecode(await utf8.decoder.bind(response).join()) as Map)
          .cast<String, dynamic>(),
      key,
      aad: 'offer-response-v1',
    );
    return (key, decision['transferId'] as String);
  }

  for (final failure in ['tamper', 'truncated', 'extra', 'hash', 'unpair']) {
    test(
      'A $failure stream is not published and closes its temporary file',
      () async {
        final bytes = List<int>.filled(fileStreamChunkBytes + 31, 7);
        final (key, id) = await offer(
          bytes.length,
          failure == 'hash'
              ? '0' * 64
              : hashing.sha256.convert(bytes).toString(),
        );
        final records = await encryptFileStream(
          Stream.value(bytes),
          key: key,
          transferId: id,
          size: bytes.length,
        ).toList();
        var wire = records.expand((record) => record).toList();
        if (failure == 'tamper') wire[100] ^= 1;
        if (failure == 'truncated') wire = wire.sublist(0, wire.length - 1);
        if (failure == 'extra') wire.add(1);
        final rejected = Completer<void>();
        receiver.onTransferError = (_) => rejected.complete();
        Future<void>? revocation;
        if (failure == 'unpair') {
          receiver.onProgress = (_) {
            revocation ??= receiver.removePeer(sender.deviceId);
          };
        }
        final request = await client.postUrl(
          Uri(
            scheme: 'http',
            host: '127.0.0.1',
            port: receiver.port,
            path: '/file-stream',
            queryParameters: {'peer': sender.deviceId, 'transferId': id},
          ),
        );
        request.add(wire);
        try {
          final response = await request.close();
          await response.drain<void>();
          expect(response.statusCode, isNot(200));
        } on HttpException {
          // Rejecting an invalid body can close HTTP before upload completion.
        } on SocketException {
          // Cancelling the invalid input stream can close the TCP connection.
        }
        await rejected.future.timeout(const Duration(seconds: 10));
        await revocation;
        expect(await receiver.receivedFiles(), isEmpty);
        expect(
          await Directory('${root.path}/receiver-files').list().toList(),
          isEmpty,
        );
      },
    );
  }
}
