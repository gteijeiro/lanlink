import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashing;
import 'package:cryptography/cryptography.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

const protocolVersion = 1;
const maxMessageBytes = 1024 * 1024;
const maxFileBytes = 16 * 1024 * 1024 * 1024;
final _temporaryFileSuffix = RegExp(r'\.[A-Za-z0-9_-]{22}\.part$');

String _randomUrlSafe(int count) {
  final bytes = List<int>.generate(count, (_) => Random.secure().nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

List<int> _decode64(String value) =>
    base64Url.decode(base64Url.normalize(value));

class Peer {
  Peer({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
  });

  final String id;
  final String name;
  String host;
  int port;

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
  };

  factory Peer.fromJson(Map<String, dynamic> json) => Peer(
    id: json['id'] as String,
    name: json['name'] as String,
    host: json['host'] as String,
    port: json['port'] as int,
  );
}

class Invitation {
  Invitation({
    required this.id,
    required this.name,
    required this.hosts,
    required this.port,
    required this.secret,
  });

  final String id;
  final String name;
  final List<String> hosts;
  final int port;
  final String secret;

  String get qrValue {
    final payload = base64Url
        .encode(
          utf8.encode(
            jsonEncode({
              'v': protocolVersion,
              'id': id,
              'name': name,
              'hosts': hosts,
              'port': port,
              'secret': secret,
            }),
          ),
        )
        .replaceAll('=', '');
    return 'lanlink://pair/$payload';
  }

  factory Invitation.fromQr(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'lanlink' ||
        uri.host != 'pair' ||
        uri.pathSegments.length != 1) {
      throw const FormatException('No es una invitación de LanLink.');
    }
    final json = jsonDecode(
      utf8.decode(_decode64(uri.pathSegments.single)),
    ) as Map<String, dynamic>;
    if (json['v'] != protocolVersion) {
      throw const FormatException('Versión de protocolo incompatible.');
    }
    final hosts = (json['hosts'] as List).cast<String>();
    if (hosts.isEmpty ||
        hosts.length > 16 ||
        hosts.any((host) => InternetAddress.tryParse(host) == null)) {
      throw const FormatException(
        'La invitación no contiene direcciones válidas.',
      );
    }
    final port = json['port'] as int;
    if (port < 1 ||
        port > 65535 ||
        _decode64(json['secret'] as String).length != 32) {
      throw const FormatException('La invitación es inválida.');
    }
    return Invitation(
      id: json['id'] as String,
      name: json['name'] as String,
      hosts: hosts,
      port: port,
      secret: json['secret'] as String,
    );
  }
}

class PairRequest {
  PairRequest(this.name);
  final String name;
}

class FileOffer {
  FileOffer(this.peer, this.name, this.size);
  final Peer peer;
  final String name;
  final int size;
}

class TransferProgress {
  TransferProgress(
    this.peerName,
    this.fileName,
    this.done,
    this.total,
    this.incoming,
    this.finished,
  );
  final String peerName;
  final String fileName;
  final int done;
  final int total;
  final bool incoming;
  final bool finished;
}

class _IncomingFile {
  _IncomingFile(this.peer, this.file, this.expectedHash, this.size);
  final Peer peer;
  final File file;
  final String expectedHash;
  final int size;
  int offset = 0;
}

abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureKeyValueStore implements KeyValueStore {
  SecureKeyValueStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class CryptoEnvelope {
  static final _cipher = AesGcm.with256bits();

  static Future<Map<String, String>> encrypt(
    List<int> bytes,
    String key, {
    String aad = '',
  }) async {
    final nonce = List<int>.generate(12, (_) => Random.secure().nextInt(256));
    final box = await _cipher.encrypt(
      bytes,
      secretKey: SecretKey(_decode64(key)),
      nonce: nonce,
      aad: utf8.encode(aad),
    );
    return {
      'n': base64Url.encode(box.nonce),
      'c': base64Url.encode(box.cipherText),
      'm': base64Url.encode(box.mac.bytes),
    };
  }

  static Future<Uint8List> decrypt(
    Map<String, dynamic> envelope,
    String key, {
    String aad = '',
  }) async {
    final box = SecretBox(
      _decode64(envelope['c'] as String),
      nonce: _decode64(envelope['n'] as String),
      mac: Mac(_decode64(envelope['m'] as String)),
    );
    return Uint8List.fromList(
      await _cipher.decrypt(
        box,
        secretKey: SecretKey(_decode64(key)),
        aad: utf8.encode(aad),
      ),
    );
  }

  static Future<Map<String, String>> encryptJson(
    Map<String, Object?> value,
    String key, {
    String aad = '',
  }) => encrypt(utf8.encode(jsonEncode(value)), key, aad: aad);

  static Future<Map<String, dynamic>> decryptJson(
    Map<String, dynamic> value,
    String key, {
    String aad = '',
  }) async =>
      jsonDecode(utf8.decode(await decrypt(value, key, aad: aad)))
          as Map<String, dynamic>;
}

class TransferService {
  TransferService({
    KeyValueStore? storage,
    this.listenPort = 47829,
    this.supportDirectory,
    this.receivedDirectory,
    this.advertisedHosts,
    this.identityName,
  }) : _storage = storage ?? SecureKeyValueStore();

  final KeyValueStore _storage;
  final int listenPort;
  final Directory? supportDirectory;
  final Directory? receivedDirectory;
  final List<String>? advertisedHosts;
  final String? identityName;
  final Map<String, Peer> peers = {};
  final Map<String, String> _keys = {};
  final Map<String, _IncomingFile> _incoming = {};
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8);
  HttpServer? _server;
  Invitation? _invitation;
  bool _pairingBusy = false;
  Directory? _supportDirectory;
  late String deviceId;
  late String deviceName;
  int get port => _server?.port ?? 0;

  Future<bool> Function(PairRequest request)? onPairRequest;
  Future<bool> Function(FileOffer offer)? onFileOffer;
  void Function(TransferProgress progress)? onProgress;
  void Function()? onPeersChanged;

  Future<void> start() async {
    _supportDirectory =
        supportDirectory ?? await getApplicationSupportDirectory();
    await _supportDirectory!.create(recursive: true);
    deviceId = await _storage.read('device-id') ?? _randomUrlSafe(16);
    await _storage.write('device-id', deviceId);
    deviceName =
        identityName ??
        (Platform.localHostname.isEmpty
            ? 'Dispositivo'
            : Platform.localHostname);
    final peerFile = File('${_supportDirectory!.path}/peers.json');
    if (await peerFile.exists()) {
      final rows = jsonDecode(await peerFile.readAsString()) as List;
      for (final row in rows) {
        final peer = Peer.fromJson((row as Map).cast<String, dynamic>());
        final key = await _storage.read('peer-${peer.id}');
        if (key != null) {
          peers[peer.id] = peer;
          _keys[peer.id] = key;
        }
      }
    }
    _server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      listenPort,
      shared: false,
    );
    _server!.listen(_handle, onError: (_) {});
    await _clearInterruptedFiles();
    await refreshInvitation();
  }

  Future<void> _clearInterruptedFiles() async {
    final dir =
        receivedDirectory ??
        Directory(
          '${(await getApplicationDocumentsDirectory()).path}/LanLink Recibidos',
        );
    if (!await dir.exists()) return;
    await for (final entry in dir.list()) {
      if (entry is File && _temporaryFileSuffix.hasMatch(entry.path)) await entry.delete();
    }
  }

  Future<Invitation> refreshInvitation() async {
    final interfaces = advertisedHosts == null
        ? await NetworkInterface.list(
            type: InternetAddressType.IPv4,
            includeLoopback: false,
          )
        : <NetworkInterface>[];
    final hosts =
        advertisedHosts ??
        interfaces
            .expand((entry) => entry.addresses)
            .map((address) => address.address)
            .where((host) => !host.startsWith('169.254.'))
            .toSet()
            .toList();
    _invitation = Invitation(
      id: deviceId,
      name: deviceName,
      hosts: hosts,
      port: port,
      secret: _randomUrlSafe(32),
    );
    return _invitation!;
  }

  Invitation get invitation => _invitation!;

  Future<void> pair(String qrValue) async {
    final invite = Invitation.fromQr(qrValue);
    if (invite.id == deviceId) {
      throw StateError('No podés emparejar un dispositivo consigo mismo.');
    }
    final clientRandom = _randomUrlSafe(32);
    final request = await CryptoEnvelope.encryptJson(
      {
        'id': deviceId,
        'name': deviceName,
        'random': clientRandom,
        'port': port,
      },
      invite.secret,
      aad: 'pair-request-v1',
    );
    Object? lastError;
    for (final host in invite.hosts) {
      try {
        final response = await _postJson(
          host,
          invite.port,
          '/pair',
          request,
          timeout: const Duration(minutes: 2),
        );
        final result = await CryptoEnvelope.decryptJson(
          response,
          invite.secret,
          aad: 'pair-response-v1',
        );
        if (result['id'] != invite.id) {
          throw const FormatException('El dispositivo no coincide con el QR.');
        }
        final key = await _derivePeerKey(
          invite.secret,
          clientRandom,
          result['random'] as String,
          deviceId,
          invite.id,
        );
        final peer = Peer(
          id: invite.id,
          name: result['name'] as String,
          host: host,
          port: invite.port,
        );
        await _savePeer(peer, key);
        return;
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('No se pudo emparejar: $lastError');
  }

  Future<String> _derivePeerKey(
    String inviteKey,
    String scannerRandom,
    String hostRandom,
    String scannerId,
    String hostId,
  ) async {
    final mac = await Hmac.sha256().calculateMac([
      ..._decode64(scannerRandom),
      ..._decode64(hostRandom),
      ...utf8.encode('$scannerId:$hostId:lanlink-v1'),
    ], secretKey: SecretKey(_decode64(inviteKey)));
    return base64Url.encode(mac.bytes);
  }

  Future<void> _savePeer(Peer peer, String key) async {
    await _storage.write('peer-${peer.id}', key);
    peers[peer.id] = peer;
    _keys[peer.id] = key;
    final file = File('${_supportDirectory!.path}/peers.json');
    await file.writeAsString(
      jsonEncode(peers.values.map((peer) => peer.toJson()).toList()),
      flush: true,
    );
    onPeersChanged?.call();
  }

  Future<void> removePeer(String id) async {
    peers.remove(id);
    _keys.remove(id);
    await _storage.delete('peer-$id');
    final file = File('${_supportDirectory!.path}/peers.json');
    await file.writeAsString(
      jsonEncode(peers.values.map((peer) => peer.toJson()).toList()),
      flush: true,
    );
    onPeersChanged?.call();
  }

  Future<List<File>> receivedFiles() async {
    final dir =
        receivedDirectory ??
        Directory(
          '${(await getApplicationDocumentsDirectory()).path}/LanLink Recibidos',
        );
    if (!await dir.exists()) return [];
    final files = await dir
        .list()
        .where((entry) => entry is File && !_temporaryFileSuffix.hasMatch(entry.path))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  Future<void> sendFile(Peer peer, XFile file) async {
    final key = _keys[peer.id];
    if (key == null) throw StateError('El dispositivo no está emparejado.');
    final size = await file.length();
    if (size > maxFileBytes) {
      throw StateError('El archivo supera el límite de 16 GiB.');
    }
    final digest = await hashing.sha256.bind(file.openRead()).first;
    final name = _safeName(file.name);
    final offer = await CryptoEnvelope.encryptJson(
      {'name': name, 'size': size, 'hash': digest.toString()},
      key,
      aad: 'offer-v1',
    );
    final response = await _postJson(peer.host, peer.port, '/offer', {
      'peer': deviceId,
      'box': offer,
    }, timeout: const Duration(minutes: 2));
    final decision = await CryptoEnvelope.decryptJson(
      response,
      key,
      aad: 'offer-response-v1',
    );
    if (decision['accepted'] != true) {
      throw StateError('El receptor rechazó el archivo.');
    }
    final transferId = decision['transferId'] as String;
    var offset = 0;
    await for (final readChunk in file.openRead()) {
      for (var start = 0; start < readChunk.length; start += 128 * 1024) {
        final end = min(start + 128 * 1024, readChunk.length);
        final chunk = readChunk.sublist(start, end);
        final box = await CryptoEnvelope.encrypt(
          chunk,
          key,
          aad: '$transferId:$offset',
        );
        final ack = await _postJson(peer.host, peer.port, '/chunk', {
          'peer': deviceId,
          'transferId': transferId,
          'offset': offset,
          'box': box,
        });
        if (ack['offset'] != offset + chunk.length) {
          throw StateError('El receptor no confirmó el bloque.');
        }
        offset += chunk.length;
        onProgress?.call(
          TransferProgress(
            peer.name,
            name,
            offset,
            size,
            false,
            offset == size,
          ),
        );
      }
    }
    if (size == 0) {
      final box = await CryptoEnvelope.encrypt([], key, aad: '$transferId:0');
      await _postJson(peer.host, peer.port, '/chunk', {
        'peer': deviceId,
        'transferId': transferId,
        'offset': 0,
        'box': box,
      });
    }
    onProgress?.call(
      TransferProgress(peer.name, name, size, size, false, true),
    );
  }

  Future<Map<String, dynamic>> _postJson(
    String host,
    int port,
    String path,
    Map<String, Object?> body, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final url = Uri(scheme: 'http', host: host, port: port, path: path);
    final request = await _client.postUrl(url).timeout(timeout);
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close().timeout(timeout);
    final text = await utf8.decodeStream(response).timeout(timeout);
    if (response.statusCode != 200) {
      throw StateError('Error de red (${response.statusCode}): $text');
    }
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request) {
      bytes.add(chunk);
      if (bytes.length > maxMessageBytes) {
        throw const FormatException('Mensaje demasiado grande.');
      }
    }
    return jsonDecode(utf8.decode(bytes.takeBytes())) as Map<String, dynamic>;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method != 'POST') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
      } else {
        final body = await _readJson(request);
        final result = switch (request.uri.path) {
          '/pair' => await _handlePair(body, request),
          '/offer' => await _handleOffer(body),
          '/chunk' => await _handleChunk(body),
          _ => throw const FormatException('Ruta desconocida.'),
        };
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(result));
      }
    } catch (error) {
      request.response.statusCode = error is FormatException
          ? HttpStatus.badRequest
          : HttpStatus.forbidden;
      request.response.write(error.toString());
    } finally {
      await request.response.close();
    }
  }

  Future<Map<String, Object?>> _handlePair(
    Map<String, dynamic> body,
    HttpRequest request,
  ) async {
    final invite = _invitation;
    if (invite == null) {
      throw const FormatException('No hay invitación activa.');
    }
    final data = await CryptoEnvelope.decryptJson(
      body,
      invite.secret,
      aad: 'pair-request-v1',
    );
    if (_pairingBusy) throw StateError('Ya hay un emparejamiento en curso.');
    _pairingBusy = true;
    try {
      final scannerId = data['id'] as String;
      final scannerName = data['name'] as String;
      final scannerRandom = data['random'] as String;
      final scannerPort = data['port'] as int;
      if (scannerId.isEmpty ||
          scannerId.length > 80 ||
          scannerName.length > 100 ||
          _decode64(scannerRandom).length != 32 ||
          scannerPort < 1 ||
          scannerPort > 65535) {
        throw const FormatException('Solicitud de emparejamiento inválida.');
      }
      final approved =
          await (onPairRequest?.call(PairRequest(scannerName)) ??
              Future.value(false));
      if (!approved) throw StateError('Emparejamiento rechazado.');
      if (!identical(_invitation, invite)) {
        throw StateError('Esta invitación ya no está vigente.');
      }
      final hostRandom = _randomUrlSafe(32);
      final key = await _derivePeerKey(
        invite.secret,
        scannerRandom,
        hostRandom,
        scannerId,
        deviceId,
      );
      final peer = Peer(
        id: scannerId,
        name: scannerName,
        host: request.connectionInfo!.remoteAddress.address,
        port: scannerPort,
      );
      await _savePeer(peer, key);
      await refreshInvitation();
      return await CryptoEnvelope.encryptJson(
        {'id': deviceId, 'name': deviceName, 'random': hostRandom},
        invite.secret,
        aad: 'pair-response-v1',
      );
    } finally {
      _pairingBusy = false;
    }
  }

  Future<Map<String, Object?>> _handleOffer(Map<String, dynamic> body) async {
    final peer = peers[body['peer']];
    if (peer == null) throw StateError('Dispositivo no emparejado.');
    final key = _keys[peer.id]!;
    final data = await CryptoEnvelope.decryptJson(
      (body['box'] as Map).cast<String, dynamic>(),
      key,
      aad: 'offer-v1',
    );
    final name = _safeName(data['name'] as String);
    final size = data['size'] as int;
    final hash = data['hash'] as String;
    if (size < 0 ||
        size > maxFileBytes ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const FormatException('Oferta de archivo inválida.');
    }
    final approved =
        await (onFileOffer?.call(FileOffer(peer, name, size)) ??
            Future.value(false));
    if (!approved) {
      return CryptoEnvelope.encryptJson(
        {'accepted': false},
        key,
        aad: 'offer-response-v1',
      );
    }
    final dir =
        receivedDirectory ??
        Directory(
          '${(await getApplicationDocumentsDirectory()).path}/LanLink Recibidos',
        );
    await dir.create(recursive: true);
    final destination = await _uniqueDestination(dir, name);
    final id = _randomUrlSafe(16);
    final part = File('${destination.path}.$id.part');
    await part.create();
    _incoming[id] = _IncomingFile(peer, part, hash, size);
    return CryptoEnvelope.encryptJson(
      {'accepted': true, 'transferId': id},
      key,
      aad: 'offer-response-v1',
    );
  }

  Future<Map<String, Object?>> _handleChunk(Map<String, dynamic> body) async {
    final id = body['transferId'] as String;
    final transfer = _incoming[id];
    if (transfer == null || transfer.peer.id != body['peer']) {
      throw StateError('Transferencia desconocida.');
    }
    final offset = body['offset'] as int;
    if (offset != transfer.offset) throw StateError('Bloque fuera de orden.');
    final key = _keys[transfer.peer.id]!;
    final bytes = await CryptoEnvelope.decrypt(
      (body['box'] as Map).cast<String, dynamic>(),
      key,
      aad: '$id:$offset',
    );
    if (bytes.length > 128 * 1024 || offset + bytes.length > transfer.size) {
      throw const FormatException('Bloque inválido.');
    }
    await transfer.file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
    transfer.offset += bytes.length;
    if (transfer.offset == transfer.size) {
      final digest = await hashing.sha256.bind(transfer.file.openRead()).first;
      if (digest.toString() != transfer.expectedHash) {
        await transfer.file.delete();
        _incoming.remove(id);
        throw StateError('El archivo recibido no coincide con el original.');
      }
      final originalName = transfer.file.path
          .split(Platform.pathSeparator)
          .last
          .split('.$id.part')
          .first;
      final dir = transfer.file.parent;
      final destination = await _uniqueDestination(dir, originalName);
      await transfer.file.rename(destination.path);
      _incoming.remove(id);
    }
    onProgress?.call(
      TransferProgress(
        transfer.peer.name,
        transfer.file.path,
        transfer.offset,
        transfer.size,
        true,
        transfer.offset == transfer.size,
      ),
    );
    return {'offset': transfer.offset};
  }

  static String _safeName(String name) {
    final cleaned = name
        .split(RegExp(r'[\\/]'))
        .last
        .replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_')
        .trim();
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return 'archivo';
    return cleaned.length > 120
        ? cleaned.substring(cleaned.length - 120)
        : cleaned;
  }

  static Future<File> _uniqueDestination(Directory dir, String name) async {
    var candidate = File('${dir.path}/$name');
    var index = 1;
    while (await candidate.exists()) {
      candidate = File('${dir.path}/$index-$name');
      index++;
    }
    return candidate;
  }

  Future<void> dispose() async {
    _client.close(force: true);
    await _server?.close(force: true);
  }
}
