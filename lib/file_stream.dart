import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'crypto_envelope.dart';

const fileStreamVersion = 1;
const fileStreamChunkBytes = 512 * 1024;

/// Coalesce filesystem reads without retaining the whole file in memory.
Stream<Uint8List> fileChunks(Stream<List<int>> source, int size) async* {
  var buffer = Uint8List(size);
  var used = 0;
  await for (final read in source) {
    var offset = 0;
    while (offset < read.length) {
      final count = (read.length - offset).clamp(0, size - used);
      buffer.setRange(used, used + count, read, offset);
      used += count;
      offset += count;
      if (used == size) {
        yield buffer;
        buffer = Uint8List(size);
        used = 0;
      }
    }
  }
  if (used != 0) yield Uint8List.sublistView(buffer, 0, used);
}

/// Each record is uint32 BE length, nonce[12], tag[16], ciphertext.
/// AAD binds authenticated plaintext to this transfer and byte offset.
Stream<List<int>> encryptFileStream(
  Stream<List<int>> source, {
  required String key,
  required String transferId,
  required int size,
  void Function(int offset)? onProgress,
}) async* {
  var offset = 0;
  final chunks = size == 0
      ? Stream<Uint8List>.value(Uint8List(0))
      : fileChunks(source, fileStreamChunkBytes);
  await for (final bytes in chunks) {
    if (offset + bytes.length > size) {
      throw StateError('El archivo cambió durante el envío.');
    }
    final encrypted = await CryptoEnvelope.encryptBinary(
      bytes,
      key,
      aad: 'file-stream-v1:$transferId:$offset',
    );
    final record = Uint8List(4 + encrypted.length);
    ByteData.sublistView(record).setUint32(0, encrypted.length);
    record.setRange(4, record.length, encrypted);
    yield record;
    offset += bytes.length;
    onProgress?.call(offset);
  }
  if (offset != size) {
    throw StateError('El archivo cambió durante el envío.');
  }
}

Stream<Uint8List> decryptFileStream(
  Stream<List<int>> source, {
  required String key,
  required String transferId,
  required int size,
}) async* {
  final reader = _RecordReader(source);
  var offset = 0;
  try {
    do {
      final header = (await reader.read(4))!;
      final length = ByteData.sublistView(header).getUint32(0);
      if (length < 28 ||
          length > fileStreamChunkBytes + 28 ||
          length - 28 > size - offset ||
          (length == 28 && size != 0)) {
        throw const FormatException('Bloque de archivo inválido.');
      }
      final bytes = await CryptoEnvelope.decryptBinary(
        (await reader.read(length))!,
        key,
        aad: 'file-stream-v1:$transferId:$offset',
      );
      offset += bytes.length;
      yield bytes;
    } while (offset < size);
    // A truncated or extended stream must never publish a completed file.
    if (await reader.read(1, allowEnd: true) != null) {
      throw const FormatException('Datos después del final del archivo.');
    }
  } finally {
    await reader.cancel();
  }
}

class _RecordReader {
  _RecordReader(Stream<List<int>> source) : _input = StreamIterator(source);
  final StreamIterator<List<int>> _input;
  List<int> _buffer = const [];
  int _offset = 0;

  Future<Uint8List?> read(int count, {bool allowEnd = false}) async {
    final result = Uint8List(count);
    var copied = 0;
    while (copied < count) {
      if (_offset == _buffer.length) {
        if (!await _input.moveNext()) {
          if (allowEnd && copied == 0) return null;
          throw const FormatException('El envío quedó incompleto.');
        }
        _buffer = _input.current;
        _offset = 0;
      }
      final take = (_buffer.length - _offset).clamp(0, count - copied);
      result.setRange(copied, copied + take, _buffer, _offset);
      _offset += take;
      copied += take;
    }
    return result;
  }

  Future<void> cancel() => _input.cancel();
}

/// Keep one handle per incoming file; sync once, before verification/publication.
class TransferFileWriter {
  TransferFileWriter(this.file);
  final File file;
  RandomAccessFile? _handle;
  bool _closed = false;

  Future<void> write(List<int> bytes) async {
    if (_closed) throw StateError('La recepción ya está cerrada.');
    final handle = _handle ??= await file.open(mode: FileMode.append);
    await handle.writeFrom(bytes);
  }

  Future<void> close({bool flush = false}) async {
    if (_closed) return;
    _closed = true;
    final handle = _handle;
    _handle = null;
    if (handle == null) return;
    try {
      if (flush) await handle.flush();
    } finally {
      await handle.close();
    }
  }
}
