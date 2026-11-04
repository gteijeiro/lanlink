import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

import 'transfer_service.dart';

const lanLinkServiceType = '_lanlink._tcp';

class NearbyDevice {
  const NearbyDevice(this.invitation);

  final NearbyInvitation invitation;

  String get id => invitation.id;
  String get name => invitation.name;
}

// TXT records contain only the public half of the ephemeral pairing key.
class DiscoveryService {
  DiscoveryService(this.ownDeviceId);

  final String ownDeviceId;
  final Map<String, NearbyDevice> devices = {};
  final Map<String, String> _idsByServiceName = {};
  final Map<String, NearbyInvitation> _invitationsByServiceName = {};
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _events;
  BonsoirBroadcast? _broadcast;
  Future<void> _broadcastWork = Future.value();
  bool _stopped = false;

  void Function()? onChanged;
  void Function(Object error)? onError;

  // Keep all candidates for a known ID. An unauthenticated mDNS record must
  // not hide a legitimate address before the shared-key challenge verifies it.
  List<NearbyInvitation> candidatesForPeer(String id) =>
      _invitationsByServiceName.values
          .where((invitation) => invitation.id == id)
          .toList();

  Future<void> start() async {
    final discovery = BonsoirDiscovery(
      type: lanLinkServiceType,
      printLogs: false,
    );
    await discovery.initialize();
    _discovery = discovery;
    _events = discovery.eventStream!.listen(_onEvent, onError: onError);
    await discovery.start();
  }

  Future<void> advertise(Invitation? invitation, String? publicKey) {
    _broadcastWork = _broadcastWork.catchError((Object _) {}).then((_) async {
      final previous = _broadcast;
      _broadcast = null;
      if (previous != null) await previous.stop();
      if (_stopped ||
          invitation == null ||
          publicKey == null ||
          invitation.hosts.isEmpty) {
        return;
      }
      final broadcast = BonsoirBroadcast(
        printLogs: false,
        service: BonsoirService(
          name: 'LanLink ${invitation.id}',
          type: lanLinkServiceType,
          port: invitation.port,
          attributes: {
            'v': '$protocolVersion',
            'id': invitation.id,
            'name': invitation.name,
            'key': publicKey,
          },
        ),
      );
      await broadcast.initialize();
      await broadcast.start();
      _broadcast = broadcast;
    });
    return _broadcastWork;
  }

  void _onEvent(BonsoirDiscoveryEvent event) {
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent():
        unawaited(
          event.service
              .resolve(_discovery!.serviceResolver)
              .catchError((Object error) => onError?.call(error)),
        );
      case BonsoirDiscoveryServiceResolvedEvent():
        _upsert(event.service);
      case BonsoirDiscoveryServiceUpdatedEvent():
        _upsert(event.service);
      case BonsoirDiscoveryServiceLostEvent():
        final id = _idsByServiceName.remove(event.service.name);
        _invitationsByServiceName.remove(event.service.name);
        if (id != null) {
          _refreshDevice(id);
          onChanged?.call();
        }
      default:
        break;
    }
  }

  void _upsert(BonsoirService service) {
    final invitation = invitationFromService(service);
    if (invitation == null || invitation.id == ownDeviceId) return;
    final previousId = _idsByServiceName[service.name];
    _idsByServiceName[service.name] = invitation.id;
    _invitationsByServiceName[service.name] = invitation;
    if (previousId != null && previousId != invitation.id) {
      _refreshDevice(previousId);
    }
    _refreshDevice(invitation.id);
    onChanged?.call();
  }

  void _refreshDevice(String id) {
    final candidates = candidatesForPeer(id);
    if (candidates.isEmpty) {
      devices.remove(id);
    } else {
      devices[id] = NearbyDevice(candidates.last);
    }
  }

  Future<void> dispose() async {
    _stopped = true;
    await _events?.cancel();
    await _discovery?.stop();
    await advertise(null, null);
    devices.clear();
    _idsByServiceName.clear();
    _invitationsByServiceName.clear();
  }
}

NearbyInvitation? invitationFromService(BonsoirService service) {
  try {
    final txt = service.attributes;
    final id = txt['id'];
    final name = txt['name'];
    final publicKey = txt['key'];
    if (txt['v'] != '$protocolVersion' ||
        id == null ||
        id.isEmpty ||
        id.length > 80 ||
        name == null ||
        name.isEmpty ||
        name.length > 100 ||
        publicKey == null ||
        base64Url.decode(base64Url.normalize(publicKey)).length != 32 ||
        service.port < 1 ||
        service.port > 65535) {
      return null;
    }
    final hosts = service.hostAddresses
        .where((host) {
          final address = InternetAddress.tryParse(host);
          return address != null &&
              address.type == InternetAddressType.IPv4 &&
              !address.isLoopback &&
              !address.isLinkLocal;
        })
        .toSet()
        .toList();
    final hostname = service.hostname;
    if (hosts.isEmpty && hostname != null) {
      if (hostname.endsWith('.local') && !hostname.contains('/')) {
        hosts.add(hostname);
      }
    }
    if (hosts.isEmpty) return null;
    return NearbyInvitation(
      id: id,
      name: name,
      hosts: hosts,
      port: service.port,
      publicKey: publicKey,
    );
  } catch (_) {
    return null;
  }
}
