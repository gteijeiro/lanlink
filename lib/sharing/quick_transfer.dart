import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as hashing;
import 'package:cryptography/cryptography.dart';
import 'package:file_selector/file_selector.dart';

import '../crypto_envelope.dart';
import '../download_storage.dart';
import '../file_stream.dart';

const quickVersion = 1;
const quickMaxBytes = 16 * 1024 * 1024 * 1024;
const quickMaxFiles = 100;
const quickMaxChunk = 128 * 1024;
typedef QuickRpc = Future<Map<String, dynamic>> Function(
  String path,
  Map<String, dynamic> body,
);

String quickRandom([int count = 16]) => base64Url
    .encode(List.generate(count, (_) => Random.secure().nextInt(256)))
    .replaceAll('=', '');
List<int> quickDecode(String text) =>
    base64Url.decode(base64Url.normalize(text));
String quickCommit(String session, List<int> publicKey, List<int> nonce) =>
    hashing.sha256.convert([
      ...utf8.encode('lanlink-quick-commit-v1:$session:'),
      ...publicKey,
      ...nonce,
    ]).toString();

Future<String> quickKey(
  KeyPair own,
  List<int> remote,
  List<int> serverNonce,
  List<int> clientNonce,
) async {
  if (remote.length != 32 ||
      serverNonce.length != 32 ||
      clientNonce.length != 32) {
    throw const FormatException('Claves de sesión inválidas.');
  }
  final shared = await X25519().sharedSecretKey(
    keyPair: own,
    remotePublicKey: SimplePublicKey(remote, type: KeyPairType.x25519),
  );
  final bytes = await shared.extractBytes();
  if (bytes.every((value) => value == 0)) {
    throw const FormatException('Clave pública inválida.');
  }
  final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: shared,
    nonce: [...serverNonce, ...clientNonce],
    info: utf8.encode('lanlink-quick-v1'),
  );
  return base64Url.encode(await derived.extractBytes());
}

Future<String> quickCode(String key, String session) async {
  final mac = await Hmac.sha256().calculateMac(
    utf8.encode('lanlink-quick-code-v1:$session'),
    secretKey: SecretKey(quickDecode(key)),
  );
  final value = mac.bytes
      .take(4)
      .fold<int>(0, (value, byte) => (value << 8) | byte);
  return (value % 1000000).toString().padLeft(6, '0');
}

String quickSafeName(String name) {
  final value = name
      .split(RegExp(r'[\\/]'))
      .last
      .replaceAll(RegExp(r'[<>:"|?*\x00-\x1f\x7f]'), '_')
      .trim();
  if (value.isEmpty || value == '.' || value == '..') return 'archivo';
  return value.length > 120 ? value.substring(value.length - 120) : value;
}

class QuickFile {
  const QuickFile(this.name, this.size, this.hash);
  final String name, hash;
  final int size;
  Map<String, Object> toJson() => {'name': name, 'size': size, 'hash': hash};
  static List<QuickFile> parse(dynamic raw) {
    if (raw is! List || raw.isEmpty || raw.length > quickMaxFiles) {
      throw const FormatException('Cantidad de archivos inválida.');
    }
    var total = 0;
    return raw.map((item) {
      if (item is! Map ||
          item['name'] is! String ||
          item['size'] is! int ||
          item['hash'] is! String) {
        throw const FormatException('Archivo inválido.');
      }
      final size = item['size'] as int;
      total += size;
      if (size < 0 ||
          size > quickMaxBytes ||
          total > quickMaxBytes ||
          (item['name'] as String).length > 512 ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(item['hash'])) {
        throw const FormatException('Archivo fuera de los límites.');
      }
      return QuickFile(quickSafeName(item['name']), size, item['hash']);
    }).toList();
  }
}

class QuickOffer {
  const QuickOffer(this.senderName, this.files, this.code);
  final String senderName, code;
  final List<QuickFile> files;
}

class QuickProgress {
  const QuickProgress(
    this.name,
    this.done,
    this.total,
    this.incoming,
    this.finished,
  );
  final String name;
  final int done, total;
  final bool incoming, finished;
}

class _Session {
  _Session(this.id, this.pair, this.publicKey, this.nonce);
  final String id;
  final SimpleKeyPair pair;
  final List<int> publicKey, nonce;
  String? commitment, key;
  String senderName = '';
  List<QuickFile>? files;
  bool offered = false, approved = false, closed = false, lease = false;
  int index = 0, offset = 0, pending = 0;
  DateTime expires = DateTime.now().add(const Duration(minutes: 3));
  File? part;
  TransferFileWriter? writer;
  String? lastRequest;
  Map<String, dynamic>? lastReply;
  Future<void> work = Future.value();
}

/// One-use sessions are independent of the persistent paired-device store.
/// Both ephemeral keys/nonces are committed before disclosure to prevent SAS grinding.
class QuickReceiver {
  QuickReceiver({
    required this.downloads,
    required this.name,
    required this.enabled,
  });
  final DownloadStorage downloads;
  final String Function() name;
  final bool Function() enabled;
  Future<bool> Function(QuickOffer offer)? onOffer;
  void Function(QuickProgress progress)? onProgress;
  void Function(String message)? onError;
  void Function(String session, bool receiving)? onSessionState;
  int _starting = 0;
  final _sessions = <String, _Session>{};
  final _attempts = <DateTime>[];
  bool _prompting = false;
  Timer? _timer;

  Future<Map<String, dynamic>> handle(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (!enabled() && path != '/quick/chunk' && path != '/quick/cancel') {
      throw StateError('Activá la recepción en LanLink.');
    }
    _timer ??= Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_expire()),
    );
    if (path == '/quick/hello') {
      final now = DateTime.now();
      _attempts.removeWhere(
        (value) => now.difference(value) > const Duration(minutes: 1),
      );
      if (_attempts.length >= 5 || _sessions.length + _starting >= 4) {
        throw StateError('Esperá un momento antes de reintentar.');
      }
      _attempts.add(now);
      _starting++;
      late _Session session;
      try {
        final pair = await X25519().newKeyPair();
        session = _Session(
          quickRandom(),
          pair,
          (await pair.extractPublicKey()).bytes,
          quickDecode(quickRandom(32)),
        );
        _sessions[session.id] = session;
      } finally {
        _starting--;
      }
      return {
        'v': quickVersion,
        'session': session.id,
        'name': name(),
        'commit': quickCommit(session.id, session.publicKey, session.nonce),
      };
    }
    final session = _sessions[body['session']];
    if (session == null || DateTime.now().isAfter(session.expires)) {
      throw StateError('La sesión venció.');
    }
    // Serialize every mutation, including concurrent/replayed chunks.
    if (session.pending >= 4) {
      throw StateError('Esperá a que termine el bloque anterior.');
    }
    session.pending++;
    final result = session.work
        .then((_) => _handleSession(session, path, body))
        .whenComplete(() => session.pending--);
    session.work = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<Map<String, dynamic>> _handleSession(
    _Session session,
    String path,
    Map<String, dynamic> body,
  ) async {
    if (session.closed && path != '/quick/chunk') {
      throw StateError('La sesión terminó.');
    }
    if (path == '/quick/reveal') {
      final commitment = body['commit'];
      if (commitment is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(commitment) ||
          (session.commitment != null && session.commitment != commitment) ||
          session.offered) {
        throw const FormatException('Compromiso de sesión inválido.');
      }
      session.commitment = commitment;
      return {
        'publicKey': base64Url.encode(session.publicKey),
        'nonce': base64Url.encode(session.nonce),
      };
    }
    if (path == '/quick/offer') {
      if (session.offered || session.commitment == null || _prompting) {
        throw StateError('Ya hay una solicitud en curso.');
      }
      session.offered = true;
      _prompting = true;
      try {
        final publicKey = quickDecode(body['publicKey'] as String);
        final nonce = quickDecode(body['nonce'] as String);
        if (publicKey.length != 32 ||
            nonce.length != 32 ||
            quickCommit(session.id, publicKey, nonce) != session.commitment) {
          throw const FormatException('La sesión cambió durante la conexión.');
        }
        final key = await quickKey(
          session.pair,
          publicKey,
          session.nonce,
          nonce,
        );
        final data = await CryptoEnvelope.decryptJson(
          (body['box'] as Map).cast<String, dynamic>(),
          key,
          aad: 'quick-offer-v1:${session.id}',
        );
        final senderName = data['name'];
        if (senderName is! String ||
            senderName.isEmpty ||
            senderName.length > 100 ||
            senderName.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
          throw const FormatException('Nombre de equipo inválido.');
        }
        final files = QuickFile.parse(data['files']);
        session.key = key;
        session.senderName = senderName;
        session.files = files;
        final accepted =
            await (onOffer?.call(
                      QuickOffer(
                        senderName,
                        files,
                        await quickCode(key, session.id),
                      ),
                    ) ??
                    Future.value(false))
                .timeout(const Duration(minutes: 2), onTimeout: () => false);
        session.approved = accepted && enabled();
        if (session.approved) {
          session.lease = true;
          onSessionState?.call(session.id, true);
        }
        if (!session.approved) session.closed = true;
        session.expires = DateTime.now().add(const Duration(minutes: 3));
        return await CryptoEnvelope.encryptJson(
          {'accepted': session.approved},
          key,
          aad: 'quick-decision-v1:${session.id}',
        );
      } finally {
        _prompting = false;
      }
    }
    if (!session.approved || session.key == null) {
      throw StateError('El envío no fue aceptado.');
    }
    if (path == '/quick/cancel') {
      await CryptoEnvelope.decryptJson(
        (body['box'] as Map).cast<String, dynamic>(),
        session.key!,
        aad: 'quick-cancel-v1:${session.id}',
      );
      await _remove(session);
      return {'cancelled': true};
    }
    if (path != '/quick/chunk') {
      throw const FormatException('Ruta de envío desconocida.');
    }
    // JSON dictionary order differs between Swift, Dart and other senders.
    // Cache the authenticated fields in a fixed order, never wire serialization.
    final envelope = (body['box'] as Map).cast<String, dynamic>();
    final requestHash = hashing.sha256
        .convert(
          utf8.encode(
            jsonEncode([
              session.id,
              body['index'],
              body['offset'],
              envelope['n'],
              envelope['c'],
              envelope['m'],
            ]),
          ),
        )
        .toString();
    if (session.lastRequest == requestHash) return session.lastReply!;
    if (session.closed ||
        body['index'] != session.index ||
        body['offset'] != session.offset) {
      throw StateError('Bloque fuera de orden.');
    }
    final file = session.files![session.index];
    final offset = session.offset;
    final bytes = await CryptoEnvelope.decrypt(
      (body['box'] as Map).cast<String, dynamic>(),
      session.key!,
      aad: 'quick-chunk-v1:${session.id}:${session.index}:$offset',
    );
    if (bytes.length > quickMaxChunk ||
        offset + bytes.length > file.size ||
        (bytes.isEmpty && file.size != 0)) {
      throw const FormatException('Bloque inválido.');
    }
    try {
      if (session.part == null) {
        final root = await downloads.stagingDirectory;
        session.part = File('${root.path}/${file.name}.${quickRandom()}.part');
        await session.part!.create(exclusive: true);
        session.writer = TransferFileWriter(session.part!);
      }
      await session.writer!.write(bytes);
      session.offset += bytes.length;
      final finishedFile = session.offset == file.size;
      final ack = await CryptoEnvelope.encryptJson(
        {
          'index': session.index,
          'offset': session.offset,
          'finished': finishedFile,
        },
        session.key!,
        aad: 'quick-ack-v1:${session.id}:${session.index}:$offset',
      );
      if (finishedFile) {
        await session.writer!.close(flush: true);
        session.writer = null;
        final hash = await hashing.sha256.bind(session.part!.openRead()).first;
        if (hash.toString() != file.hash) {
          throw StateError('El archivo no coincide con el original.');
        }
        await downloads.publish(session.part!, file.name);
        session.part = null;
        session.index++;
        session.offset = 0;
        session.closed = session.index == session.files!.length;
      }
      session.lastRequest = requestHash;
      session.lastReply = ack;
      session.expires = DateTime.now().add(
        session.closed
            ? const Duration(seconds: 90)
            : const Duration(minutes: 3),
      );
      onProgress?.call(
        QuickProgress(
          file.name,
          offset + bytes.length,
          file.size,
          true,
          finishedFile,
        ),
      );
      return ack;
    } catch (error) {
      await _remove(session);
      onError?.call('No se pudo recibir ${file.name}: $error');
      rethrow;
    }
  }

  Future<void> _remove(_Session session) async {
    _sessions.remove(session.id);
    if (session.lease) {
      session.lease = false;
      onSessionState?.call(session.id, false);
    }
    session.closed = true;
    await session.writer?.close();
    session.writer = null;
    if (session.part != null && await session.part!.exists()) {
      await session.part!.delete();
    }
  }

  Future<void> _expire() async {
    for (final session in _sessions.values.toList()) {
      if (session.pending == 0 && DateTime.now().isAfter(session.expires)) {
        await _remove(session);
      }
    }
  }

  Future<void> dispose() async {
    _timer?.cancel();
    for (final session in _sessions.values.toList()) {
      await session.work;
      await _remove(session);
    }
  }
}

class QuickSender {
  QuickSender({required this.name});
  final String name;
  bool cancelled = false;
  void Function(String code)? onCode;
  Future<bool> Function(String code)? confirmCode;
  void Function(QuickProgress progress)? onProgress;
  void _check() {
    if (cancelled) throw StateError('Envío cancelado.');
  }

  Future<void> send(
    List<XFile> sources,
    QuickRpc rpc, {
    int chunkSize = quickMaxChunk,
    int Function()? selectedChunkSize,
  }) async {
    if (sources.isEmpty ||
        sources.length > quickMaxFiles ||
        chunkSize < 1 ||
        chunkSize > quickMaxChunk) {
      throw const FormatException('Envío inválido.');
    }
    final files = <QuickFile>[];
    for (final source in sources) {
      _check();
      final hash = await hashing.sha256
          .bind(
            source.openRead().map((bytes) {
              _check();
              return bytes;
            }),
          )
          .first;
      files.add(
        QuickFile(
          quickSafeName(source.name),
          await source.length(),
          hash.toString(),
        ),
      );
    }
    QuickFile.parse(files.map((file) => file.toJson()).toList());
    _check();
    final hello = await rpc('/quick/hello', {});
    chunkSize = selectedChunkSize?.call() ?? chunkSize;
    if (chunkSize < 1 || chunkSize > quickMaxChunk) {
      throw const FormatException('Tamaño de bloque inválido.');
    }
    if (hello['v'] != quickVersion ||
        hello['session'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(hello['session'])) {
      throw const FormatException('Versión de LanLink incompatible.');
    }
    final session = hello['session'] as String;
    final pair = await X25519().newKeyPair();
    final publicKey = (await pair.extractPublicKey()).bytes;
    final nonce = quickDecode(quickRandom(32));
    final reveal = await rpc('/quick/reveal', {
      'session': session,
      'commit': quickCommit(session, publicKey, nonce),
    });
    final serverPublic = quickDecode(reveal['publicKey'] as String);
    final serverNonce = quickDecode(reveal['nonce'] as String);
    if (serverPublic.length != 32 ||
        serverNonce.length != 32 ||
        quickCommit(session, serverPublic, serverNonce) != hello['commit']) {
      throw StateError('No se pudo verificar la conexión.');
    }
    final key = await quickKey(pair, serverPublic, serverNonce, nonce);
    final code = await quickCode(key, session);
    onCode?.call(code);
    _check();
    final decision = await rpc('/quick/offer', {
      'session': session,
      'publicKey': base64Url.encode(publicKey),
      'nonce': base64Url.encode(nonce),
      'box': await CryptoEnvelope.encryptJson(
        {'name': name, 'files': files.map((file) => file.toJson()).toList()},
        key,
        aad: 'quick-offer-v1:$session',
      ),
    });
    final data = await CryptoEnvelope.decryptJson(
      decision,
      key,
      aad: 'quick-decision-v1:$session',
    );
    if (data['accepted'] != true) {
      throw StateError('El receptor no aceptó el envío.');
    }
    try {
      _check();
      if (!await (confirmCode
              ?.call(code)
              .timeout(const Duration(minutes: 2), onTimeout: () => false) ??
          Future.value(false))) {
        throw StateError('Los códigos no fueron confirmados.');
      }
      for (var index = 0; index < sources.length; index++) {
        var offset = 0;
        final source = sources[index];
        final reader = fileChunks(source.openRead(), chunkSize);
        Future<void> chunk(List<int> bytes) async {
          _check();
          final body = <String, dynamic>{
            'session': session,
            'index': index,
            'offset': offset,
            'box': await CryptoEnvelope.encrypt(
              bytes,
              key,
              aad: 'quick-chunk-v1:$session:$index:$offset',
            ),
          };
          Map<String, dynamic>? ack;
          for (var attempt = 0; attempt < 2; attempt++) {
            try {
              ack = await rpc('/quick/chunk', body);
              break;
            } catch (_) {
              if (attempt == 1) rethrow;
            }
          }
          final verified = await CryptoEnvelope.decryptJson(
            ack!,
            key,
            aad: 'quick-ack-v1:$session:$index:$offset',
          );
          if (verified['index'] != index ||
              verified['offset'] != offset + bytes.length) {
            throw StateError('La confirmación del archivo no es válida.');
          }
          offset += bytes.length;
          onProgress?.call(
            QuickProgress(
              files[index].name,
              offset,
              files[index].size,
              false,
              offset == files[index].size,
            ),
          );
        }

        await for (final read in reader) {
          for (var start = 0; start < read.length; start += chunkSize) {
            await chunk(
              read.sublist(start, min(start + chunkSize, read.length)),
            );
          }
        }
        if (files[index].size == 0) await chunk([]);
        if (offset != files[index].size) {
          throw StateError('El archivo cambió durante el envío.');
        }
      }
    } catch (_) {
      try {
        await rpc('/quick/cancel', {
          'session': session,
          'box': await CryptoEnvelope.encryptJson(
            {},
            key,
            aad: 'quick-cancel-v1:$session',
          ),
        });
      } catch (_) {}
      rethrow;
    }
  }
}
