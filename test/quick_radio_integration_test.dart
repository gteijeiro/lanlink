import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink/download_storage.dart';
import 'package:lanlink/sharing/quick_transfer.dart';
import 'package:lanlink/sharing/radio_rpc.dart';

void main() {
  test(
    'Encrypted transfer through the Bluetooth packet RPC, with an ACK loss',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanlink-radio-integration',
      );
      final source = File('${root.path}/source.dat');
      final bytes = List.generate(3072, (i) => i % 251);
      await source.writeAsBytes(bytes);
      String? code;
      final receiver = QuickReceiver(
        downloads: DownloadStorage(
          overrideDirectory: Directory('${root.path}/received'),
        ),
        name: () => 'Receiver',
        enabled: () => true,
      );
      receiver.onOffer = (offer) async {
        code = offer.code;
        return true;
      };
      late RadioRpc senderWire, receiverWire;
      var dropped = false;
      senderWire = RadioRpc(
        tag: 1042,
        packetTimeout: const Duration(milliseconds: 20),
        handle: (_, body) async => body,
        write: (packet) async {
          scheduleMicrotask(
            () => receiverWire.receive(Uint8List.fromList(packet)),
          );
        },
      );
      receiverWire = RadioRpc(
        tag: 1042,
        packetTimeout: const Duration(milliseconds: 20),
        handle: receiver.handle,
        write: (packet) async {
          if (!dropped && packet[0] == 2) {
            dropped = true;
            return;
          }
          scheduleMicrotask(
            () => senderWire.receive(Uint8List.fromList(packet)),
          );
        },
      );
      try {
        final sender = QuickSender(name: 'Sender');
        sender.confirmCode = (value) async => value == code;
        await sender.send(
          [XFile(source.path)],
          senderWire.request,
          chunkSize: 4096,
        );
        final received = await receiver.downloads.list();
        expect(await File(received.single.location).readAsBytes(), bytes);
        expect(dropped, true);
      } finally {
        senderWire.close();
        receiverWire.close();
        await receiver.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
