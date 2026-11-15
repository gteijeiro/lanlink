import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'quick_transfer.dart';

const quickBleService = 'd34f0001-8937-4f59-8b32-65d72c5b81ad';
const quickBleRx = 'd34f0002-8937-4f59-8b32-65d72c5b81ad';
const quickBleTx = 'd34f0003-8937-4f59-8b32-65d72c5b81ad';
const radioMaxFrame = 1024 * 1024;

class QuickDestination {
  const QuickDestination({
    required this.id,
    required this.name,
    required this.transport,
    required this.rpc,
    this.chunkSize = quickMaxChunk,
  });
  final String id, name, transport;
  final QuickRpc rpc;
  final int chunkSize;
}

/// Stop-and-wait packets make GATT notifications reliable and ordered.
/// Routing tags are not authentication; QuickTransfer authenticates all file data.
class RadioRpc {
  RadioRpc({
    required this.tag,
    required this.write,
    required this.handle,
    this.packetTimeout = const Duration(seconds: 3),
  });
  final int tag;
  final Duration packetTimeout;
  final Future<void> Function(Uint8List packet) write;
  final QuickRpc handle;
  int payloadLength = 20;
  int _txSequence = 0, _rxSequence = 0;
  final _buffer = BytesBuilder(copy: false);
  bool _receiving = false, _closed = false;
  Future<void> _outgoing = Future.value();
  Completer<void>? _packetAck;
  final _pending = <String, Completer<Map<String, dynamic>>>{};

  static int packetTag(List<int> packet) => packet.length < 8
      ? -1
      : ByteData.sublistView(Uint8List.fromList(packet)).getUint32(4);
  Uint8List _header(int kind, int seq, int flags) {
    final value = Uint8List(8);
    final data = ByteData.sublistView(value);
    data.setUint8(0, kind);
    data.setUint16(1, seq);
    data.setUint8(3, flags);
    data.setUint32(4, tag);
    return value;
  }

  void receive(Uint8List packet) {
    if (_closed || packet.length < 8 || packetTag(packet) != tag) return;
    final data = ByteData.sublistView(packet);
    final kind = data.getUint8(0),
        sequence = data.getUint16(1),
        flags = data.getUint8(3);
    if (kind == 2) {
      if (sequence == _txSequence &&
          _packetAck != null &&
          !_packetAck!.isCompleted) {
        _packetAck!.complete();
      }
      return;
    }
    if (kind != 1) return;
    if (sequence == ((_rxSequence - 1) & 0xffff)) {
      unawaited(write(_header(2, sequence, 0)).catchError((_) {}));
      return;
    }
    if (sequence != _rxSequence) return;
    if ((flags & 1) != 0) {
      _buffer.clear();
      _receiving = true;
    }
    if (!_receiving || _buffer.length + packet.length - 8 > radioMaxFrame) {
      close();
      return;
    }
    _buffer.add(packet.sublist(8));
    _rxSequence = (_rxSequence + 1) & 0xffff;
    unawaited(write(_header(2, sequence, 0)).catchError((_) {}));
    if ((flags & 2) != 0) {
      _receiving = false;
      final bytes = _buffer.takeBytes();
      unawaited(_message(bytes));
    }
  }

  Future<void> _message(List<int> bytes) async {
    try {
      final message = (jsonDecode(utf8.decode(bytes)) as Map)
          .cast<String, dynamic>();
      final id = message['id'];
      if (id is! String || id.length > 64) return;
      if (message['response'] == true) {
        final pending = _pending.remove(id);
        if (pending == null || pending.isCompleted) return;
        if (message['ok'] == true && message['body'] is Map) {
          pending.complete((message['body'] as Map).cast<String, dynamic>());
        } else {
          pending.completeError(
            StateError('El otro equipo no pudo completar la operación.'),
          );
        }
      } else if (message['path'] is String && message['body'] is Map) {
        try {
          final result = await handle(
            message['path'],
            (message['body'] as Map).cast<String, dynamic>(),
          );
          await _send({'id': id, 'response': true, 'ok': true, 'body': result});
        } catch (_) {
          await _send({'id': id, 'response': true, 'ok': false});
        }
      }
    } catch (_) {
      /* Malformed frames cannot become file data. */
    }
  }

  Future<Map<String, dynamic>> request(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (_closed) throw StateError('La conexión Bluetooth se cerró.');
    if (_pending.length >= 4) {
      throw StateError('Hay demasiadas solicitudes Bluetooth.');
    }
    final id = quickRandom();
    final result = Completer<Map<String, dynamic>>();
    _pending[id] = result;
    // Attach the error handler before sending, because disconnect may race it.
    final answer = result.future.timeout(
      path == '/quick/offer'
          ? const Duration(minutes: 3)
          : const Duration(seconds: 45),
    );
    try {
      await Future.wait<dynamic>([
        _send({'id': id, 'path': path, 'body': body}),
        answer,
      ], eagerError: true);
      return await answer;
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> _send(Map<String, dynamic> value) {
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > radioMaxFrame) {
      throw const FormatException('Mensaje Bluetooth demasiado grande.');
    }
    final result = _outgoing.then((_) async {
      for (int offset = 0; offset < bytes.length;) {
        if (_closed) throw StateError('Bluetooth desconectado.');
        final int end = min(offset + max(1, payloadLength - 8), bytes.length);
        final packet = Uint8List.fromList([
          ..._header(
            1,
            _txSequence,
            (offset == 0 ? 1 : 0) | (end == bytes.length ? 2 : 0),
          ),
          ...bytes.sublist(offset, end),
        ]);
        var acknowledged = false;
        for (var attempt = 0; attempt < 3; attempt++) {
          _packetAck = Completer<void>();
          try {
            await Future.wait<void>([
              write(packet),
              _packetAck!.future.timeout(packetTimeout),
            ], eagerError: true);
            acknowledged = true;
            break;
          } on TimeoutException {
            if (attempt == 2) rethrow;
          }
        }
        if (!acknowledged) {
          throw StateError('El otro equipo no confirmó Bluetooth.');
        }
        _packetAck = null;
        _txSequence = (_txSequence + 1) & 0xffff;
        offset = end;
      }
    });
    _outgoing = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _buffer.clear();
    for (final value in _pending.values) {
      if (!value.isCompleted) {
        value.completeError(StateError('Bluetooth desconectado.'));
      }
    }
    _pending.clear();
    if (_packetAck != null && !_packetAck!.isCompleted) {
      _packetAck!.completeError(StateError('Bluetooth desconectado.'));
    }
  }
}
