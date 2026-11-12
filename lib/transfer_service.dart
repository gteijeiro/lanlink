import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashing;
import 'package:cryptography/cryptography.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'download_storage.dart';

const protocolVersion = 1;
const maxMessageBytes = 1024 * 1024;
const maxFileBytes = 16 * 1024 * 1024 * 1024;
final _temporaryFileSuffix = temporaryDownloadSuffix;

String _randomUrlSafe(int count) {
  final bytes = List<int>.generate(count, (_) => Random.secure().nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

List<int> _decode64(String value) =>
    base64Url.decode(base64Url.normalize(value));

String friendlyDeviceName(String hostname, {String fallback = 'Dispositivo'}) {
  final name = hostname
      .replaceFirst(RegExp(r'\.local\.?$', caseSensitive: false), '')
      .replaceAll(RegExp(r'[-_]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return name.isEmpty ||
          name.toLowerCase() == 'localhost' ||
          name.toLowerCase() == 'unknown'
      ? fallback
      : name;
}

Future<String> _systemDeviceName() async {
  final fallback = Platform.isMacOS
      ? 'Mac'
      : Platform.isIOS
      ? 'iPhone'
      : Platform.isAndroid
      ? 'Android'
      : Platform.isWindows
      ? 'PC Windows'
      : 'Equipo Linux';
  try {
    final info = DeviceInfoPlugin();
    if (Platform.isMacOS) {
      return friendlyDeviceName(
        (await info.macOsInfo).computerName,
        fallback: fallback,
      );
    }
    if (Platform.isAndroid) {
      final android = await info.androidInfo;
      final modelName = friendlyDeviceName(
        '${android.brand} ${android.model}',
        fallback: fallback,
      );
      return friendlyDeviceName(android.name, fallback: modelName);
    }
    if (Platform.isIOS) {
      return friendlyDeviceName((await info.iosInfo).name, fallback: fallback);
    }
    if (Platform.isWindows) {
      return friendlyDeviceName(
        (await info.windowsInfo).computerName,
        fallback: fallback,
      );
    }
  } catch (_) {
    // The network hostname remains available when native device info fails.
  }
  return friendlyDeviceName(Platform.localHostname, fallback: fallback);
}

class Peer {
  Peer({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    this.trustedForFiles = false,
  });

  final String id;
  bool trustedForFiles;
  String name;
  String host;
  int port;
  // Never persisted: an address is trusted only after this session verifies it.
  bool verified = false;

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'trustedForFiles': trustedForFiles,
  };

  factory Peer.fromJson(Map<String, dynamic> json) => Peer(
    id: json['id'] as String,
    name: json['name'] as String,
    host: json['host'] as String,
    port: json['port'] as int,
    trustedForFiles: json['trustedForFiles'] == true,
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

class NearbyInvitation {
  const NearbyInvitation({
    required this.id,
    required this.name,
    required this.hosts,
    required this.port,
    required this.publicKey,
  });

  final String id;
  final String name;
  final List<String> hosts;
  final int port;
  final String publicKey;
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
  _IncomingFile(this.peer, this.file, this.name, this.expectedHash, this.size);
  final Peer peer;
  final File file;
  final String name;
  final String expectedHash;
  final int size;
  int offset = 0;
}

class _IdentityChallenge {
  _IdentityChallenge(this.peerId, this.address);

  final String peerId;
  final String address;
  final DateTime createdAt = DateTime.now();
}

abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureKeyValueStore implements KeyValueStore {
  SecureKeyValueStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          (Platform.isMacOS
              ? const FlutterSecureStorage(
                  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
                )
              : const FlutterSecureStorage());
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
    DownloadStorage? downloadStorage,
    this.listenPort = 47829,
    this.supportDirectory,
    this.receivedDirectory,
    this.advertisedHosts,
    this.identityName,
  }) : _storage = storage ?? SecureKeyValueStore(),
       downloads =
           downloadStorage ??
           DownloadStorage(overrideDirectory: receivedDirectory);

  final KeyValueStore _storage;
  final DownloadStorage downloads;
  final int listenPort;
  final Directory? supportDirectory;
  final Directory? receivedDirectory;
  final List<String>? advertisedHosts;
  final String? identityName;
  final Map<String, Peer> peers = {};
  final Map<String, String> _keys = {};
  final Map<String, Peer> _revocations = {};
  final Map<String, String> _revocationKeys = {};
  final Set<String> _pendingRevocations = {};
  final Set<String> _sendingRevocations = {};
  final Set<String> _revoking = {};
  Future<void> _peerWrites = Future.value();
  Future<void> _revocationWrites = Future.value();
  final Map<String, DateTime> _revocationAttempts = {};
  final List<DateTime> _pairKeyAttempts = [];
  String? _pairingKey;
  String? get pairingKey => _pairingKey == null ? null : 'LL1-$_pairingKey';
  Set<String> get pendingRevocations => Set.unmodifiable(_pendingRevocations);
  final Map<String, _IncomingFile> _incoming = {};
  final Map<String, _IdentityChallenge> _identityChallenges = {};
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8);
  HttpServer? _server;
  Invitation? _invitation;
  KeyPair? _nearbyKeyPair;
  bool _pairingBusy = false;
  Directory? _supportDirectory;
  Timer? _networkTimer;
  bool _checkingNetwork = false;
  late String deviceId;
  late String deviceName;
  late String nearbyPublicKey;
  bool visibleOnLan = false;
  int get port => _server?.port ?? 0;

  Future<bool> Function(PairRequest request)? onPairRequest;
  Future<bool> Function(FileOffer offer)? onFileOffer;
  void Function(TransferProgress progress)? onProgress;
  void Function(String message)? onTransferError;
  void Function()? onPeersChanged;
  void Function(Invitation invitation)? onInvitationChanged;
  void Function()? onNearbyKeyChanged;

  Future<void> start() async {
    _supportDirectory =
        supportDirectory ?? await getApplicationSupportDirectory();
    await _supportDirectory!.create(recursive: true);
    deviceId = await _storage.read('device-id') ?? _randomUrlSafe(16);
    await _storage.write('device-id', deviceId);
    visibleOnLan = await _storage.read('visible-on-lan') == 'true';
    _pairingKey = await _storage.read('pairing-key');
    deviceName =
        identityName ??
        await _storage.read('device-name') ??
        await _systemDeviceName();
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
    final revocationsFile = File('${_supportDirectory!.path}/revocations.json');
    if (await revocationsFile.exists()) {
      for (final dynamic row
          in jsonDecode(await revocationsFile.readAsString()) as List) {
        final peer = Peer.fromJson(
          (row['peer'] as Map).cast<String, dynamic>(),
        );
        final key = await _storage.read('revocation-${peer.id}');
        if (key != null) {
          _revocations[peer.id] = peer;
          _revocationKeys[peer.id] = key;
          if (row['pending'] == true) _pendingRevocations.add(peer.id);
        }
      }
    }
    // Finish a revocation interrupted between persisting its receipt and
    // deleting the original peer. A newly established session has another key.
    for (final id in _revocations.keys.toList()) {
      final key = _keys[id];
      if (key != null && await _revocationKey(key, id) == _revocationKeys[id]) {
        await _forgetLocally(id);
      }
    }
    _server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      listenPort,
      shared: false,
    );
    _server!.listen(_handle, onError: (_) {});
    await downloads.initialize();
    await _clearInterruptedFiles();
    await refreshInvitation();
    await _refreshNearbyKey();
    if (advertisedHosts == null) {
      _networkTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(_checkNetworkAddresses()),
      );
    }
  }

  Future<void> _checkNetworkAddresses() async {
    if (_checkingNetwork || _invitation == null) return;
    _checkingNetwork = true;
    unawaited(retryPendingRevocations());
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addresses = interfaces
          .expand((entry) => entry.addresses)
          .map((address) => address.address)
          .where((host) => !host.startsWith('169.254.'))
          .toSet();
      if (addresses.length != _invitation!.hosts.length ||
          !addresses.containsAll(_invitation!.hosts)) {
        for (final peer in peers.values) {
          peer.verified = false;
        }
        onPeersChanged?.call();
        await refreshInvitation();
      }
    } catch (_) {
      // Transient interface changes are retried by the next poll.
    } finally {
      _checkingNetwork = false;
    }
  }

  Future<void> _refreshNearbyKey() async {
    _nearbyKeyPair = await X25519().newKeyPair();
    final publicKey =
        await _nearbyKeyPair!.extractPublicKey() as SimplePublicKey;
    nearbyPublicKey = base64Url.encode(publicKey.bytes).replaceAll('=', '');
    onNearbyKeyChanged?.call();
  }

  Future<void> _clearInterruptedFiles() async {
    final dir = await downloads.stagingDirectory;
    if (!await dir.exists()) return;
    await for (final entry in dir.list()) {
      if (entry is File && _temporaryFileSuffix.hasMatch(entry.path)) {
        await entry.delete();
      }
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
    onInvitationChanged?.call(_invitation!);
    return _invitation!;
  }

  Future<void> setVisibleOnLan(bool value) async {
    await _storage.write('visible-on-lan', value ? 'true' : 'false');
    visibleOnLan = value;
  }

  Future<void> setDeviceName(String value) async {
    final name = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (name.isEmpty ||
        name.length > 100 ||
        name.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
      throw const FormatException('Escribí un nombre de 1 a 100 caracteres.');
    }
    await _storage.write('device-name', name);
    deviceName = name;
    await refreshInvitation();
  }

  Invitation get invitation => _invitation!;

  Future<void> pair(String qrValue) =>
      pairInvitation(Invitation.fromQr(qrValue));

  Future<String> enablePairingKey() async {
    _pairingKey ??= _randomUrlSafe(32);
    await _storage.write('pairing-key', _pairingKey!);
    return pairingKey!;
  }

  Future<String> rotatePairingKey() async {
    _pairingKey = _randomUrlSafe(32);
    await _storage.write('pairing-key', _pairingKey!);
    return pairingKey!;
  }

  Future<void> disablePairingKey() async {
    _pairingKey = null;
    await _storage.delete('pairing-key');
  }

  static String _parsePairingKey(String value) {
    final key = value.trim();
    if (!RegExp(r'^LL1-[A-Za-z0-9_-]{43}$').hasMatch(key) ||
        _decode64(key.substring(4)).length != 32) {
      throw const FormatException(
        'Pegá la clave completa generada por LanLink (LL1-…).',
      );
    }
    return key.substring(4);
  }

  Future<String> _keyPairingSecret(
    String dhSecret,
    String key,
    String receiverId,
  ) async {
    final mac = await Hmac.sha256().calculateMac([
      ...utf8.encode('lanlink-pair-key-v1:$receiverId:'),
      ..._decode64(dhSecret),
    ], secretKey: SecretKey(_decode64(key)));
    return base64Url.encode(mac.bytes);
  }

  Future<void> pairNearby(NearbyInvitation invite, {String? pairingKey}) async {
    if (invite.id == deviceId) {
      throw StateError('No podés emparejar un dispositivo consigo mismo.');
    }
    _requireNewPeer(invite.id);
    final remoteBytes = _decode64(invite.publicKey);
    if (remoteBytes.length != 32 || invite.hosts.isEmpty) {
      throw const FormatException('Anuncio de red inválido.');
    }
    final pair = await X25519().newKeyPair();
    final publicKey = await pair.extractPublicKey();
    final dhSecret = await _nearbySharedSecret(pair, remoteBytes);
    final secret = pairingKey == null
        ? dhSecret
        : await _keyPairingSecret(
            dhSecret,
            _parsePairingKey(pairingKey),
            invite.id,
          );
    final requestAad = pairingKey == null
        ? 'pair-nearby-request-v1'
        : 'pair-key-request-v1';
    final responseAad = pairingKey == null
        ? 'pair-nearby-response-v1'
        : 'pair-key-response-v1';
    final clientRandom = _randomUrlSafe(32);
    final request = await CryptoEnvelope.encryptJson(
      {
        'id': deviceId,
        'name': deviceName,
        'random': clientRandom,
        'port': port,
      },
      secret,
      aad: requestAad,
    );
    Object? lastError;
    for (final host in invite.hosts) {
      try {
        final response = await _postJson(
          host,
          invite.port,
          pairingKey == null ? '/pair-nearby' : '/pair-key',
          {'publicKey': base64Url.encode(publicKey.bytes), 'box': request},
          timeout: const Duration(minutes: 2),
        );
        final result = await CryptoEnvelope.decryptJson(
          response,
          secret,
          aad: responseAad,
        );
        if (result['id'] != invite.id) {
          throw const FormatException(
            'El dispositivo no coincide con el anuncio.',
          );
        }
        final key = await _derivePeerKey(
          secret,
          clientRandom,
          result['random'] as String,
          deviceId,
          invite.id,
        );
        await _savePeer(
          Peer(
            id: invite.id,
            name: result['name'] as String,
            host: host,
            port: invite.port,
          ),
          key,
        );
        return;
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('No se pudo emparejar: $lastError');
  }

  Future<String> _nearbySharedSecret(
    KeyPair ownPair,
    List<int> remoteBytes,
  ) async {
    final shared = await X25519().sharedSecretKey(
      keyPair: ownPair,
      remotePublicKey: SimplePublicKey(remoteBytes, type: KeyPairType.x25519),
    );
    final bytes = await shared.extractBytes();
    if (bytes.every((byte) => byte == 0)) {
      throw const FormatException('Clave pública inválida.');
    }
    return base64Url.encode(bytes);
  }

  Future<void> pairInvitation(Invitation invite) async {
    if (invite.id == deviceId) {
      throw StateError('No podés emparejar un dispositivo consigo mismo.');
    }
    _requireNewPeer(invite.id);
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
    _requireNewPeer(peer.id);
    await _storage.write('peer-${peer.id}', key);
    peers[peer.id] = peer;
    _keys[peer.id] = key;
    _pendingRevocations.remove(peer.id);
    await _persistRevocations();
    await _persistPeers();
  }

  void _requireNewPeer(String id) {
    if (peers.containsKey(id) ||
        _keys.containsKey(id) ||
        _revoking.contains(id)) {
      throw StateError(
        'Este dispositivo ya está vinculado. Desvinculalo antes de '
        'crear un vínculo nuevo.',
      );
    }
  }

  Future<void> _persistPeers() {
    final work = _peerWrites.then((_) async {
      final file = File('${_supportDirectory!.path}/peers.json');
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode(peers.values.map((peer) => peer.toJson()).toList()),
        flush: true,
      );
      await temporary.rename(file.path);
      onPeersChanged?.call();
    });
    _peerWrites = work.catchError((Object _) {});
    return work;
  }

  Future<void> setPeerTrusted(String id, bool value) async {
    final peer = peers[id];
    if (peer == null) throw StateError('El dispositivo ya no está vinculado.');
    peer.trustedForFiles = value;
    await _persistPeers();
  }

  Future<String> _revocationKey(String key, String peerId) async {
    final ids = [deviceId, peerId]..sort();
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode(jsonEncode(['lanlink-revoke-key-v1', ...ids])),
      secretKey: SecretKey(_decode64(key)),
    );
    return base64Url.encode(mac.bytes);
  }

  Future<void> _persistRevocations() {
    final work = _revocationWrites.then((_) async {
      final file = File('${_supportDirectory!.path}/revocations.json');
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode(
          _revocations.values
              .map(
                (peer) => {
                  'peer': peer.toJson(),
                  'pending': _pendingRevocations.contains(peer.id),
                },
              )
              .toList(),
        ),
        flush: true,
      );
      await temporary.rename(file.path);
    });
    _revocationWrites = work.catchError((Object _) {});
    return work;
  }

  Future<void> _forgetLocally(String id) async {
    peers.remove(id);
    _keys.remove(id);
    _identityChallenges.removeWhere((_, challenge) => challenge.peerId == id);
    await _storage.delete('peer-$id');
    // A removed peer may know the general onboarding key. Rotate it so that
    // the removed peer cannot immediately rejoin using that old credential.
    if (_pairingKey != null) await rotatePairingKey();
    final incoming = _incoming.entries
        .where((entry) => entry.value.peer.id == id)
        .toList();
    for (final entry in incoming) {
      _incoming.remove(entry.key);
      if (await entry.value.file.exists()) await entry.value.file.delete();
    }
    await _persistPeers();
  }

  Future<void> removePeer(String id) async {
    if (!_revoking.add(id)) return;
    try {
      final peer = peers[id];
      final key = _keys[id];
      if (peer == null || key == null) return;
      final revokeKey = await _revocationKey(key, id);
      await _storage.write('revocation-$id', revokeKey);
      _revocations[id] = peer;
      _revocationKeys[id] = revokeKey;
      _pendingRevocations.add(id);
      await _persistRevocations();
      await _forgetLocally(id);
    } finally {
      _revoking.remove(id);
    }
    await retryPendingRevocations(peerId: id, force: true);
  }

  Future<void> reconcileRevocations(
    Iterable<NearbyInvitation> discovered,
  ) async {
    final candidates = discovered.toList();
    for (final id in _pendingRevocations.toList()) {
      if (_sendingRevocations.contains(id)) continue;
      final last = _revocationAttempts[id];
      if (last != null &&
          DateTime.now().difference(last) < const Duration(seconds: 10)) {
        continue;
      }
      for (final candidate in candidates.where(
        (candidate) => candidate.id == id,
      )) {
        await retryPendingRevocations(invitation: candidate, force: true);
        if (!_pendingRevocations.contains(id)) break;
      }
    }
  }

  Future<void> retryPendingRevocations({
    String? peerId,
    NearbyInvitation? invitation,
    bool force = false,
  }) async {
    for (final id in _pendingRevocations.toList()) {
      if (peerId != null && peerId != id) continue;
      if (invitation != null && invitation.id != id) continue;
      if (_sendingRevocations.contains(id)) continue;
      final now = DateTime.now();
      final last = _revocationAttempts[id];
      if (!force &&
          last != null &&
          now.difference(last) < const Duration(seconds: 10)) {
        continue;
      }
      final peer = _revocations[id]!;
      final key = _revocationKeys[id]!;
      final hosts = invitation?.hosts ?? [peer.host];
      final remotePort = invitation?.port ?? peer.port;
      _sendingRevocations.add(id);
      _revocationAttempts[id] = now;
      try {
        final nonce = _randomUrlSafe(32);
        final box = await CryptoEnvelope.encryptJson(
          {'from': deviceId, 'to': id, 'nonce': nonce},
          key,
          aad: 'revoke-request-v1',
        );
        for (final host in hosts) {
          try {
            final response = await _postJson(host, remotePort, '/unpair', {
              'peer': deviceId,
              'box': box,
            }, timeout: const Duration(seconds: 3));
            final ack = await CryptoEnvelope.decryptJson(
              response,
              key,
              aad: 'revoke-response-v1',
            );
            if (ack['from'] != id ||
                ack['to'] != deviceId ||
                ack['nonce'] != nonce ||
                ack['revoked'] != true) {
              throw const FormatException(
                'Confirmación de desvinculación inválida.',
              );
            }
            // A newer revocation must never be cleared by an older response.
            if (_revocationKeys[id] == key) {
              _pendingRevocations.remove(id);
              await _persistRevocations();
              onPeersChanged?.call();
            }
            break;
          } catch (_) {
            /* Offline peers are retried after discovery or restart. */
          }
        }
      } finally {
        _sendingRevocations.remove(id);
      }
    }
  }

  Future<Map<String, Object?>> _handleUnpair(Map<String, dynamic> body) async {
    final id = body['peer'] as String;
    final currentKey = _keys[id];
    final currentRevokeKey = currentKey == null
        ? null
        : await _revocationKey(currentKey, id);
    final candidates = <String>{
      ?currentRevokeKey,
      if (_revocationKeys[id] != null) _revocationKeys[id]!,
    };
    for (final key in candidates) {
      Map<String, dynamic> data;
      try {
        data = await CryptoEnvelope.decryptJson(
          (body['box'] as Map).cast<String, dynamic>(),
          key,
          aad: 'revoke-request-v1',
        );
      } catch (_) {
        continue;
      }
      if (data['from'] != id ||
          data['to'] != deviceId ||
          _decode64(data['nonce'] as String).length != 32) {
        throw const FormatException('Desvinculación inválida.');
      }
      if (key == currentRevokeKey && _keys[id] == currentKey) {
        if (!_revoking.add(id)) throw StateError('Desvinculación en curso.');
        try {
          await _storage.write('revocation-$id', key);
          _revocations[id] = peers[id]!;
          _revocationKeys[id] = key;
          _pendingRevocations.remove(id);
          await _persistRevocations();
          await _forgetLocally(id);
        } finally {
          _revoking.remove(id);
        }
      }
      return CryptoEnvelope.encryptJson(
        {'from': deviceId, 'to': id, 'nonce': data['nonce'], 'revoked': true},
        key,
        aad: 'revoke-response-v1',
      );
    }
    throw StateError('No se pudo autenticar la desvinculación.');
  }

  Future<void> reconnectKnownPeer(NearbyInvitation invite) async {
    final peer = peers[invite.id];
    final key = _keys[invite.id];
    if (peer == null || key == null || invite.hosts.isEmpty) {
      throw StateError('No hay un vínculo guardado con este dispositivo.');
    }
    Object? lastError;
    for (final host in invite.hosts) {
      try {
        final start = await _postJson(host, invite.port, '/identify/start', {
          'from': deviceId,
          'to': peer.id,
        }, timeout: const Duration(seconds: 5));
        final serverNonce = start['nonce'] as String;
        if (_decode64(serverNonce).length != 32) {
          throw const FormatException('Desafío de identidad inválido.');
        }
        final clientNonce = _randomUrlSafe(32);
        final proof = await _identityProof(key, [
          'request',
          deviceId,
          peer.id,
          serverNonce,
          clientNonce,
          deviceName,
          port,
        ]);
        final response = await _postJson(
          host,
          invite.port,
          '/identify/finish',
          {
            'from': deviceId,
            'to': peer.id,
            'serverNonce': serverNonce,
            'clientNonce': clientNonce,
            'name': deviceName,
            'port': port,
            'proof': proof,
          },
          timeout: const Duration(seconds: 5),
        );
        final remoteName = response['name'] as String;
        final remotePort = response['port'] as int;
        if (!_validIdentityName(remoteName) ||
            remotePort != invite.port ||
            !await _checkIdentityProof(key, [
              'response',
              deviceId,
              peer.id,
              serverNonce,
              clientNonce,
              remoteName,
              remotePort,
            ], response['proof'])) {
          throw const FormatException('La identidad del equipo no coincide.');
        }
        if (!identical(peers[peer.id], peer) || _keys[peer.id] != key) {
          throw StateError('El vínculo cambió durante la verificación.');
        }
        await _updatePeerAddress(peer, host, remotePort, remoteName);
        return;
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('No se pudo verificar el dispositivo: $lastError');
  }

  Future<String> _identityProof(String key, List<Object?> fields) async {
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode(jsonEncode(['lanlink-identify-v1', ...fields])),
      secretKey: SecretKey(_decode64(key)),
    );
    return base64Url.encode(mac.bytes).replaceAll('=', '');
  }

  Future<bool> _checkIdentityProof(
    String key,
    List<Object?> fields,
    Object? supplied,
  ) async {
    if (supplied is! String) return false;
    try {
      final actual = _decode64(supplied);
      final expected = _decode64(await _identityProof(key, fields));
      if (actual.length != expected.length) return false;
      var difference = 0;
      for (var i = 0; i < actual.length; i++) {
        difference |= actual[i] ^ expected[i];
      }
      return difference == 0;
    } catch (_) {
      return false;
    }
  }

  bool _validIdentityName(String name) =>
      name.isNotEmpty &&
      name.length <= 100 &&
      !name.contains(RegExp(r'[\x00-\x1F\x7F]'));

  Future<void> _updatePeerAddress(
    Peer peer,
    String host,
    int updatedPort,
    String name,
  ) async {
    final changed =
        peer.host != host || peer.port != updatedPort || peer.name != name;
    final newlyVerified = !peer.verified;
    peer.host = host;
    peer.port = updatedPort;
    peer.name = name;
    peer.verified = true;
    if (changed) {
      await _persistPeers();
    } else if (newlyVerified) {
      onPeersChanged?.call();
    }
  }

  Future<List<ReceivedDownload>> receivedFiles() => downloads.list();

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
        if (_keys[peer.id] != key) {
          throw StateError('El dispositivo fue desvinculado.');
        }
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
    final bytes = await response
        .fold<BytesBuilder>(BytesBuilder(copy: false), (buffer, chunk) {
          if (buffer.length + chunk.length > maxMessageBytes) {
            throw const FormatException('Respuesta demasiado grande.');
          }
          buffer.add(chunk);
          return buffer;
        })
        .timeout(timeout);
    final text = utf8.decode(bytes.takeBytes());
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
          '/pair-nearby' => await _handleNearbyPair(body, request),
          '/pair-key' => await _handleNearbyPair(
            body,
            request,
            withPairingKey: true,
          ),
          '/unpair' => await _handleUnpair(body),
          '/identify/start' => await _handleIdentityStart(body, request),
          '/identify/finish' => await _handleIdentityFinish(body, request),
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
      _requireNewPeer(scannerId);
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

  Future<Map<String, Object?>> _handleNearbyPair(
    Map<String, dynamic> body,
    HttpRequest request, {
    bool withPairingKey = false,
  }) async {
    if (!visibleOnLan || _nearbyKeyPair == null) {
      throw StateError('Este equipo no está visible en la red.');
    }
    final configuredKey = _pairingKey;
    if (withPairingKey) {
      final now = DateTime.now();
      _pairKeyAttempts.removeWhere(
        (time) => now.difference(time) > const Duration(minutes: 1),
      );
      if (configuredKey == null || _pairKeyAttempts.length >= 10) {
        throw StateError(
          'Vinculación con clave no disponible. Esperá un minuto o usá QR.',
        );
      }
      _pairKeyAttempts.add(now);
    }
    if (_pairingBusy) throw StateError('Ya hay un emparejamiento en curso.');
    final remoteBytes = _decode64(body['publicKey'] as String);
    if (remoteBytes.length != 32) {
      throw const FormatException('Clave pública inválida.');
    }
    _pairingBusy = true;
    try {
      final dhSecret = await _nearbySharedSecret(_nearbyKeyPair!, remoteBytes);
      final secret = withPairingKey
          ? await _keyPairingSecret(dhSecret, configuredKey!, deviceId)
          : dhSecret;
      final data = await CryptoEnvelope.decryptJson(
        (body['box'] as Map).cast<String, dynamic>(),
        secret,
        aad: withPairingKey ? 'pair-key-request-v1' : 'pair-nearby-request-v1',
      );
      final scannerId = data['id'] as String;
      final scannerName = data['name'] as String;
      final scannerRandom = data['random'] as String;
      final scannerPort = data['port'] as int;
      if (scannerId.isEmpty ||
          scannerId.length > 80 ||
          scannerName.isEmpty ||
          scannerName.length > 100 ||
          _decode64(scannerRandom).length != 32 ||
          scannerPort < 1 ||
          scannerPort > 65535) {
        throw const FormatException('Solicitud de emparejamiento inválida.');
      }
      _requireNewPeer(scannerId);
      final approved =
          withPairingKey ||
          await (onPairRequest?.call(PairRequest(scannerName)) ??
              Future.value(false));
      if (!approved) throw StateError('Emparejamiento rechazado.');
      if (withPairingKey && _pairingKey != configuredKey) {
        throw StateError('La clave de vinculación cambió.');
      }
      final hostRandom = _randomUrlSafe(32);
      final key = await _derivePeerKey(
        secret,
        scannerRandom,
        hostRandom,
        scannerId,
        deviceId,
      );
      await _savePeer(
        Peer(
          id: scannerId,
          name: scannerName,
          host: request.connectionInfo!.remoteAddress.address,
          port: scannerPort,
        ),
        key,
      );
      final response = await CryptoEnvelope.encryptJson(
        {'id': deviceId, 'name': deviceName, 'random': hostRandom},
        secret,
        aad: withPairingKey
            ? 'pair-key-response-v1'
            : 'pair-nearby-response-v1',
      );
      await _refreshNearbyKey();
      return response;
    } finally {
      _pairingBusy = false;
    }
  }

  Future<Map<String, Object?>> _handleIdentityStart(
    Map<String, dynamic> body,
    HttpRequest request,
  ) async {
    final peerId = body['from'];
    if (peerId is! String ||
        body['to'] != deviceId ||
        !_keys.containsKey(peerId)) {
      throw StateError('Dispositivo no vinculado.');
    }
    _identityChallenges.removeWhere(
      (_, challenge) =>
          DateTime.now().difference(challenge.createdAt) >
          const Duration(seconds: 30),
    );
    if (_identityChallenges.length >= 64) {
      _identityChallenges.remove(_identityChallenges.keys.first);
    }
    final nonce = _randomUrlSafe(32);
    _identityChallenges[nonce] = _IdentityChallenge(
      peerId,
      request.connectionInfo!.remoteAddress.address,
    );
    return {'nonce': nonce};
  }

  Future<Map<String, Object?>> _handleIdentityFinish(
    Map<String, dynamic> body,
    HttpRequest request,
  ) async {
    final peerId = body['from'];
    final serverNonce = body['serverNonce'];
    final clientNonce = body['clientNonce'];
    final name = body['name'];
    final updatedPort = body['port'];
    if (peerId is! String ||
        serverNonce is! String ||
        clientNonce is! String ||
        name is! String ||
        updatedPort is! int ||
        body['to'] != deviceId ||
        !_validIdentityName(name) ||
        updatedPort < 1 ||
        updatedPort > 65535 ||
        _decode64(clientNonce).length != 32) {
      throw const FormatException('Respuesta de identidad inválida.');
    }
    final challenge = _identityChallenges.remove(serverNonce);
    final peer = peers[peerId];
    final key = _keys[peerId];
    if (challenge == null ||
        challenge.peerId != peerId ||
        challenge.address != request.connectionInfo!.remoteAddress.address ||
        DateTime.now().difference(challenge.createdAt) >
            const Duration(seconds: 30) ||
        peer == null ||
        key == null ||
        !await _checkIdentityProof(key, [
          'request',
          peerId,
          deviceId,
          serverNonce,
          clientNonce,
          name,
          updatedPort,
        ], body['proof'])) {
      throw StateError('No se pudo verificar la identidad.');
    }
    final responseProof = await _identityProof(key, [
      'response',
      peerId,
      deviceId,
      serverNonce,
      clientNonce,
      deviceName,
      port,
    ]);
    await _updatePeerAddress(
      peer,
      request.connectionInfo!.remoteAddress.address,
      updatedPort,
      name,
    );
    return {'name': deviceName, 'port': port, 'proof': responseProof};
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
        peer.trustedForFiles ||
        await (onFileOffer?.call(FileOffer(peer, name, size)) ??
            Future.value(false));
    if (!approved) {
      return CryptoEnvelope.encryptJson(
        {'accepted': false},
        key,
        aad: 'offer-response-v1',
      );
    }
    if (_keys[peer.id] != key || !identical(peers[peer.id], peer)) {
      throw StateError('El dispositivo fue desvinculado.');
    }
    final dir = await downloads.stagingDirectory;
    await dir.create(recursive: true);
    final destination = await _uniqueDestination(dir, name);
    final id = _randomUrlSafe(16);
    final part = File('${destination.path}.$id.part');
    await part.create();
    _incoming[id] = _IncomingFile(peer, part, name, hash, size);
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
    if (_keys[transfer.peer.id] != key || !_incoming.containsKey(id)) {
      throw StateError('El dispositivo fue desvinculado.');
    }
    try {
      await transfer.file.writeAsBytes(
        bytes,
        mode: FileMode.append,
        flush: true,
      );
      transfer.offset += bytes.length;
      if (transfer.offset == transfer.size) {
        final digest = await hashing.sha256
            .bind(transfer.file.openRead())
            .first;
        if (digest.toString() != transfer.expectedHash) {
          await transfer.file.delete();
          _incoming.remove(id);
          throw StateError('El archivo recibido no coincide con el original.');
        }
        await downloads.publish(transfer.file, transfer.name);
        _incoming.remove(id);
      }
      onProgress?.call(
        TransferProgress(
          transfer.peer.name,
          transfer.name,
          transfer.offset,
          transfer.size,
          true,
          transfer.offset == transfer.size,
        ),
      );
      return {'offset': transfer.offset};
    } catch (error) {
      _incoming.remove(id);
      onTransferError?.call('No se pudo recibir “${transfer.name}”: $error');
      rethrow;
    }
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
    _networkTimer?.cancel();
    _client.close(force: true);
    await _server?.close(force: true);
  }
}
