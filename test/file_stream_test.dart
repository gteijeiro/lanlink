import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink/file_stream.dart';

void main() {
  final key = base64Url.encode(List<int>.filled(32, 17));

  Future<List<int>> decode(
    List<int> wire,
    int size, {
    String id = 'transfer',
  }) => decryptFileStream(
    // Deliberately split headers, tags and ciphertext at transport boundaries.
    fileChunks(Stream.value(wire), 7919),
    key: key,
    transferId: id,
    size: size,
  ).fold<List<int>>([], (result, bytes) => result..addAll(bytes));

  for (final size in [0, 1, fileStreamChunkBytes * 2 + 37]) {
    test(
      'Binary streaming preserves all $size bytes across fragmented reads',
      () async {
        final bytes = List.generate(size, (index) => index % 251);
        final records = await encryptFileStream(
          fileChunks(Stream.value(bytes), 64001),
          key: key,
          transferId: 'transfer',
          size: size,
        ).toList();
        expect(
          records.length,
          size == 0 ? 1 : (size / fileStreamChunkBytes).ceil(),
        );
        expect(
          await decode(records.expand((record) => record).toList(), size),
          bytes,
        );
      },
    );
  }

  test(
    'Tampering, wrong transfer, reordered records and incomplete streams fail',
    () async {
      final size = fileStreamChunkBytes + 7;
      final records = await encryptFileStream(
        Stream.value(List.filled(size, 3)),
        key: key,
        transferId: 'transfer',
        size: size,
      ).toList();
      final wire = records.expand((record) => record).toList();
      final altered = List<int>.of(wire)..[100] ^= 1;
      await expectLater(decode(altered, size), throwsA(isA<Exception>()));
      await expectLater(
        decode(wire, size, id: 'another'),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        decode([...records.last, ...records.first], size),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        decode(wire.sublist(0, wire.length - 1), size),
        throwsFormatException,
      );
      await expectLater(decode([...wire, 0], size), throwsFormatException);
      await expectLater(decode([], 0), throwsFormatException);
      final oversized = Uint8List(4);
      ByteData.sublistView(oversized).setUint32(0, 0xffffffff);
      await expectLater(decode(oversized, size), throwsFormatException);
    },
  );
}
