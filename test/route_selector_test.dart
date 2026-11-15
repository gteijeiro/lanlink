import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink/download_storage.dart';
import 'package:lanlink/sharing/quick_transfer.dart';
import 'package:lanlink/sharing/radio_rpc.dart';
import 'package:lanlink/sharing/route_selector.dart';

Map<String, dynamic> hello() => {
  'v': 1,
  'session': 'abcdefghijklmnopqrstuv',
  'commit': List.filled(64, 'a').join(),
};
QuickDestination route(
  String transport,
  QuickRpc rpc, {
  String id = 'device',
}) => QuickDestination(
  id: id,
  name: 'Device',
  transport: transport,
  rpc: rpc,
  chunkSize: transport == 'Bluetooth' ? 4096 : quickMaxChunk,
);

void main() {
  test(
    'Groups by device and prefers LAN, then Apple direct Wi-Fi, then BLE',
    () {
      final groups = groupQuickRoutes([
        route('Bluetooth', (_, body) async => body),
        route('Wi-Fi directa', (_, body) async => body),
        route('Red local', (_, body) async => body),
        route('Bluetooth', (_, body) async => body, id: 'other'),
      ]);
      expect(groups.length, 2);
      expect(groups['device']!.map((e) => e.transport), [
        'Red local',
        'Wi-Fi directa',
        'Bluetooth',
      ]);
    },
  );
  test('A usable LAN does not probe Bluetooth', () async {
    final selector = QuickRouteSelector([
      route('Bluetooth', (_, _) async => throw StateError('Must not be used')),
      route('Red local', (_, _) async => hello()),
    ]);
    await selector.request('/quick/hello', {});
    expect(selector.selected!.transport, 'Red local');
    expect(selector.chunkSize, quickMaxChunk);
  });
  test(
    'An unavailable or incompatible route falls back automatically',
    () async {
      final selector = QuickRouteSelector([
        route('Red local', (_, _) async => {'v': 0}),
        route('Bluetooth', (_, _) async => hello()),
      ]);
      await selector.request('/quick/hello', {});
      expect(selector.selected!.transport, 'Bluetooth');
    },
  );
  test('A hung connection does not prevent trying another transport', () async {
    final selector = QuickRouteSelector([
      route('Red local', (_, _) => Completer<Map<String, dynamic>>().future),
      route('Bluetooth', (_, _) async => hello()),
    ], timeout: const Duration(milliseconds: 10));
    await selector.request('/quick/hello', {});
    expect(selector.selected!.transport, 'Bluetooth');
  });
  test(
    'A rejection or authentication failure cannot create a second offer',
    () async {
      var bluetoothCalls = 0;
      final selector = QuickRouteSelector([
        route('Red local', (path, _) async {
          if (path == '/quick/hello') return hello();
          throw StateError('Rejected');
        }),
        route('Bluetooth', (_, _) async {
          bluetoothCalls++;
          return hello();
        }),
      ]);
      await selector.request('/quick/hello', {});
      await expectLater(selector.request('/quick/offer', {}), throwsStateError);
      expect(bluetoothCalls, 0);
    },
  );
  test('Cancellation does not start a fallback', () async {
    var cancelled = false, calls = 0;
    final selector = QuickRouteSelector([
      route('Red local', (_, _) async {
        cancelled = true;
        throw StateError('Offline');
      }),
      route('Bluetooth', (_, _) async {
        calls++;
        return hello();
      }),
    ], cancelled: () => cancelled);
    await expectLater(selector.request('/quick/hello', {}), throwsStateError);
    expect(calls, 0);
  });
  test('Android/iPhone protocol transfer uses BLE when the advertised LAN is stale', () async {
    final root = await Directory.systemTemp.createTemp('lanlink-route-test');
    final receiver = QuickReceiver(
      downloads: DownloadStorage(
        overrideDirectory: Directory('${root.path}/received'),
      ),
      name: () => 'iPhone',
      enabled: () => true,
    );
    receiver.onOffer = (_) async => true;
    var offers = 0, chunks = 0;
    final selector = QuickRouteSelector([
      route('Red local', (_, _) async => throw const SocketException('Old IP')),
      route('Bluetooth', (path, body) async {
        if (path == '/quick/offer') offers++;
        if (path == '/quick/chunk') {
          chunks++;
          expect(
            quickDecode((body['box'] as Map)['c']).length,
            lessThanOrEqualTo(4096),
          );
        }
        return receiver.handle(path, body);
      }),
    ]);
    try {
      final file = File('${root.path}/video.mp4');
      final bytes = List.generate(16000, (i) => i % 251);
      await file.writeAsBytes(bytes);
      final sender = QuickSender(name: 'Android');
      sender.confirmCode = (_) async => true;
      await sender.send(
        [XFile(file.path)],
        selector.request,
        selectedChunkSize: () => selector.chunkSize,
      );
      expect(selector.selected!.transport, 'Bluetooth');
      expect(offers, 1);
      expect(chunks, greaterThan(1));
      final files = await receiver.downloads.list();
      expect(await File(files.single.location).readAsBytes(), bytes);
    } finally {
      await receiver.dispose();
      await root.delete(recursive: true);
    }
  });
}
