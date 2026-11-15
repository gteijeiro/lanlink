import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink/sharing/radio_rpc.dart';

void main() {
  test('Bluetooth reintenta un paquete perdido sin ejecutar dos veces la solicitud', () async {
    late RadioRpc left, right;
    var dropped = false, calls = 0;
    left = RadioRpc(
      tag: 42,
      packetTimeout: const Duration(milliseconds: 20),
      write: (packet) async {
        scheduleMicrotask(() => right.receive(Uint8List.fromList(packet)));
      },
      handle: (_, body) async => body,
    );
    right = RadioRpc(
      tag: 42,
      packetTimeout: const Duration(milliseconds: 20),
      write: (packet) async {
        if (!dropped && packet[0] == 2) {
          dropped = true;
          return;
        }
        scheduleMicrotask(() => left.receive(Uint8List.fromList(packet)));
      },
      handle: (_, body) async {
        calls++;
        return body;
      },
    );
    addTearDown(left.close);
    addTearDown(right.close);
    final text = List.filled(400, 'Archivo ñ 🌊').join();
    final response = await left.request('/echo', {'text': text});
    expect(response['text'], text);
    expect(calls, 1);
    expect(dropped, true);
  });
}
