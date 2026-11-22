// Run explicitly: flutter test test/transfer_benchmark.dart --reporter expanded
// Optional: --dart-define=LANLINK_BENCHMARK_MIB=32
//           --dart-define=LANLINK_BENCHMARK_DELAY_MS=10
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashing;
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink/transfer_service.dart';

class _MemoryStore implements KeyValueStore {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

void main() {
  test('Measure verified synthetic file throughput on loopback', () async {
    const mib = int.fromEnvironment('LANLINK_BENCHMARK_MIB', defaultValue: 32);
    const delay = int.fromEnvironment(
      'LANLINK_BENCHMARK_DELAY_MS',
      defaultValue: 10,
    );
    final root = await Directory.systemTemp.createTemp('lanlink-benchmark-');
    TransferService device(String name) => TransferService(
      storage: _MemoryStore(),
      listenPort: 0,
      identityName: name,
      supportDirectory: Directory('${root.path}/$name-support'),
      receivedDirectory: Directory('${root.path}/$name-files'),
      advertisedHosts: ['127.0.0.1'],
    );
    final sender = device('sender'), receiver = device('receiver');
    final client = HttpClient();
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await sender.dispose();
      await receiver.dispose();
      client.close(force: true);
      await proxy.close(force: true);
      await root.delete(recursive: true);
    });
    await sender.start();
    await receiver.start();
    receiver.onPairRequest = (_) async => true;
    receiver.onFileOffer = (_) async => true;
    await sender.pairInvitation(receiver.invitation);
    final counts = <String, int>{};
    proxy.listen((request) async {
      try {
        counts.update(
          request.uri.path,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        await Future<void>.delayed(const Duration(milliseconds: delay));
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
        if (request.contentLength >= 0) {
          upstream.contentLength = request.contentLength;
        }
        await upstream.addStream(request);
        final response = await upstream.close();
        request.response.statusCode = response.statusCode;
        if (response.contentLength >= 0) {
          request.response.contentLength = response.contentLength;
        }
        await request.response.addStream(response);
      } finally {
        await request.response.close();
      }
    });
    sender.peers[receiver.deviceId]!.port = proxy.port;
    final file = File('${root.path}/synthetic.bin');
    final output = file.openWrite();
    final block = List.generate(1024 * 1024, (i) => i % 251);
    for (var i = 0; i < mib; i++) {
      output.add(block);
    }
    await output.close();
    final watch = Stopwatch()..start();
    await sender.sendFile(sender.peers[receiver.deviceId]!, XFile(file.path));
    watch.stop();
    final expected = await hashing.sha256.bind(file.openRead()).first;
    final received = File('${root.path}/receiver-files/synthetic.bin');
    expect(await hashing.sha256.bind(received.openRead()).first, expected);
    // Only synthetic metadata is printed; never keys or user files.
    // ignore: avoid_print
    print(
      'BENCHMARK ${jsonEncode({'label': const String.fromEnvironment('LANLINK_BENCHMARK_LABEL'), 'mib': mib, 'delay_ms_per_request': delay, 'elapsed_ms': watch.elapsedMilliseconds, 'mib_per_second': mib * 1000000 / watch.elapsedMicroseconds, 'requests': counts, 'sha256_verified': true})}',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
