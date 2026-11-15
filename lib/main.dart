import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'discovery_service.dart';
import 'download_storage.dart';
import 'pairing_key_dialog.dart';
import 'pairing_password.dart';
import 'transfer_service.dart';
import 'ui/app_theme.dart';
import 'ui/lanlink_dashboard.dart';
import 'sharing/direct_coordinator.dart';
import 'sharing/incoming_shares.dart';
import 'sharing/quick_transfer.dart';
import 'sharing/quick_share_dialog.dart';
import 'sharing/radio_rpc.dart';

void main(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(LanLinkApp(arguments: arguments));
}

class LanLinkApp extends StatelessWidget {
  const LanLinkApp({super.key, this.arguments = const []});
  final List<String> arguments;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'LanLink',
    debugShowCheckedModeBanner: false,
    theme: lanLinkTheme(),
    darkTheme: lanLinkTheme(brightness: Brightness.dark),
    home: HomePage(arguments: arguments),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.arguments = const []});
  final List<String> arguments;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TransferService _service = TransferService();
  DiscoveryService? _discovery;
  DiscoveryService? _quickDiscovery;
  final TextEditingController _linkController = TextEditingController();
  final _incomingShares = IncomingShares();
  final _sharedQueue = <SharedBatch>[];
  DirectCoordinator? _direct;
  Timer? _directTimer;
  bool _sharing = false;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _discoveryError;
  TransferProgress? _progress;
  String? _transferError;
  Timer? _reconnectTimer;
  final Set<String> _reconnecting = {};
  final Map<String, DateTime> _lastReconnectAttempt = {};

  @override
  void initState() {
    super.initState();
    _service.onPairRequest = _confirmPair;
    _service.onFileOffer = _confirmFile;
    _service.onPeersChanged = () {
      if (mounted) setState(() {});
    };
    _service.onProgress = (progress) {
      if (mounted) {
        setState(() {
          _progress = progress;
          _transferError = null;
        });
      }
    };
    _service.onTransferError = (message) {
      if (mounted) {
        setState(() {
          _progress = null;
          _transferError = message;
        });
      }
    };
    _incomingShares.onBatch = (batch) {
      _sharedQueue.add(batch);
      unawaited(_drainShared());
    };
    _incomingShares.onError = (message) {
      if (mounted) setState(() => _transferError = message);
    };
    unawaited(_incomingShares.start(widget.arguments));
    _start();
  }

  Future<void> _start() async {
    try {
      await _service.start();
      _service.quick.onOffer = _confirmQuick;
      _service.quick.onProgress = (progress) {
        if (mounted) {
          setState(
            () => _progress = TransferProgress(
              'Equipo cercano',
              progress.name,
              progress.done,
              progress.total,
              progress.incoming,
              progress.finished,
            ),
          );
        }
      };
      _service.quick.onSessionState = (session, receiving) {
        if (receiving && _direct?.active == true) {
          unawaited(_direct!.acquire('incoming-$session'));
        }
        if (!receiving) {
          unawaited(_direct?.release('incoming-$session'));
        }
      };
      _service.quick.onError = (message) {
        if (mounted) setState(() => _transferError = message);
      };
      _direct = DirectCoordinator(
        id: _service.deviceId,
        name: _service.deviceName,
        handle: _service.quick.handle,
      );

      final quickDiscovery = DiscoveryService(
        _service.deviceId,
        serviceType: '_lanlink-quick._tcp',
      );
      _quickDiscovery = quickDiscovery;
      unawaited(quickDiscovery.start().catchError((Object _) {}));
      final discovery = DiscoveryService(_service.deviceId);
      discovery.onChanged = () {
        if (mounted) setState(() {});
        _verifyNearbyPeers();
      };
      discovery.onError = (error) {
        if (mounted) setState(() => _discoveryError = error.toString());
      };
      _discovery = discovery;
      _service.onInvitationChanged = (invitation) {
        if (_service.directReceiving) {
          unawaited(
            _quickDiscovery
                ?.advertise(invitation, _service.nearbyPublicKey)
                .catchError((Object _) {}),
          );
        }
        if (_service.visibleOnLan) {
          unawaited(
            discovery
                .advertise(invitation, _service.nearbyPublicKey)
                .catchError((Object error) {
                  if (mounted) {
                    setState(() => _discoveryError = error.toString());
                  }
                }),
          );
        }
      };
      _service.onNearbyKeyChanged = () {
        if (_service.visibleOnLan) {
          unawaited(
            discovery
                .advertise(_service.invitation, _service.nearbyPublicKey)
                .catchError((Object error) {
                  if (mounted) {
                    setState(() => _discoveryError = error.toString());
                  }
                }),
          );
        }
      };
      unawaited(_startDiscovery(discovery));
      _reconnectTimer = Timer.periodic(
        const Duration(seconds: 12),
        (_) => _verifyNearbyPeers(),
      );
    } catch (error) {
      _error = error.toString();
    }
    if (mounted) setState(() => _loading = false);
    unawaited(_drainShared());
  }

  Future<void> _startDiscovery(DiscoveryService discovery) async {
    try {
      await discovery.start();
      if (_service.visibleOnLan) {
        await discovery.advertise(
          _service.invitation,
          _service.nearbyPublicKey,
        );
      }
      _verifyNearbyPeers();
    } catch (error) {
      if (mounted) setState(() => _discoveryError = error.toString());
    }
  }

  void _verifyNearbyPeers() {
    final discovery = _discovery;
    if (discovery == null) return;
    unawaited(
      _service.reconcileRevocations(
        _service.pendingRevocations.expand(discovery.candidatesForPeer),
      ),
    );
    for (final peer in _service.peers.values) {
      final candidates = discovery.candidatesForPeer(peer.id);
      if (candidates.isEmpty || _reconnecting.contains(peer.id)) continue;
      final now = DateTime.now();
      final last = _lastReconnectAttempt[peer.id];
      if (last != null && now.difference(last) < const Duration(seconds: 10)) {
        continue;
      }
      _lastReconnectAttempt[peer.id] = now;
      _reconnecting.add(peer.id);
      unawaited(() async {
        try {
          for (final candidate in candidates) {
            try {
              await _service.reconnectKnownPeer(candidate);
              break;
            } catch (_) {
              // A forged or stale mDNS record cannot change a saved peer.
            }
          }
        } finally {
          _reconnecting.remove(peer.id);
        }
      }());
    }
  }

  Future<bool> _confirmPair(PairRequest request) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('Emparejar dispositivo'),
            content: Text('${request.name} quiere conectarse. ¿Lo aceptás?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Rechazar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Emparejar'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<bool> _confirmFile(FileOffer offer) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('Archivo entrante'),
            content: Text(
              '${offer.peer.name} quiere enviarte “${offer.name}” (${_size(offer.size)}).\n\nSe guardará en ${_service.downloads.label}.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Rechazar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Aceptar'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _showQr() async {
    final invite = await _service.refreshInvitation();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mi código QR'),
        content: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (invite.hosts.isEmpty)
                const Text(
                  'No se encontró una dirección de red local. Conectá este equipo a Wi-Fi o Ethernet.',
                ),
              if (invite.hosts.isNotEmpty) ...[
                QrImageView(
                  data: invite.qrValue,
                  size: 260,
                  backgroundColor: Colors.white,
                ),
                const SizedBox(height: 12),
                Text(
                  'Escaneá desde el otro dispositivo. Esta invitación se usa una sola vez.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                SelectableText(
                  'IP: ${invite.hosts.join(', ')}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (invite.hosts.isNotEmpty)
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: invite.qrValue));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Enlace copiado')),
                  );
                }
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copiar enlace'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  Future<void> _scanQr() async {
    if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      _showMessage(
        'La lectura con cámara está disponible en Android, iOS y macOS. En este equipo pegá el enlace del QR.',
      );
      return;
    }
    final value = await showDialog<String>(
      context: context,
      builder: (context) => const _ScannerDialog(),
    );
    if (value != null) await _pair(value);
  }

  Future<void> _pair(String value) => _runPair(() => _service.pair(value));

  Future<void> _pairNearby(NearbyInvitation invitation) async {
    final controller = TextEditingController();
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Vincular con ${invitation.name}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Si tenés la clave de este dispositivo, podés vincular sin que aprueben del otro lado.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => update(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Clave de vinculación',
                    hintText: 'Mínimo 6 caracteres',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, ''),
              child: const Text('Solicitar aprobación'),
            ),
            FilledButton(
              onPressed: pairingPasswordLength(controller.text) < 6
                  ? null
                  : () => Navigator.pop(context, controller.text),
              child: const Text('Vincular con clave'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (choice == null || !mounted) return;
    await _runPair(
      () => _service.pairNearby(
        invitation,
        pairingKey: choice.isEmpty ? null : choice,
      ),
    );
  }

  Future<void> _configurePairingKey() async {
    await showDialog<void>(
      context: context,
      builder: (_) => PairingKeyDialog(service: _service),
    );
    if (mounted) setState(() {});
  }

  Future<void> _setTrusted(Peer peer) async {
    var confirmed = true;
    if (!peer.trustedForFiles) {
      confirmed =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('Confiar en ${peer.name}'),
              content: const Text(
                'Este equipo guardará automáticamente los archivos que envíe ese dispositivo, sin pedir aprobación. Podés desactivarlo desde sus opciones.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Aceptar automáticamente'),
                ),
              ],
            ),
          ) ??
          false;
    }
    if (!confirmed) return;
    await _service.setPeerTrusted(peer.id, !peer.trustedForFiles);
  }

  Future<void> _runPair(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      _linkController.clear();
      _showMessage('Dispositivos emparejados. Ya podés enviar archivos.');
    } catch (error) {
      _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setVisibleOnLan(bool value) async {
    try {
      if (value) {
        await _discovery?.advertise(
          _service.invitation,
          _service.nearbyPublicKey,
        );
      } else {
        await _discovery?.advertise(null, null);
      }
      await _service.setVisibleOnLan(value);
      if (mounted) setState(() => _discoveryError = null);
    } catch (error) {
      if (mounted) _showMessage('No se pudo cambiar la visibilidad: $error');
    }
  }

  Future<void> _editDeviceName() async {
    final controller = TextEditingController(text: _service.deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Nombre de este dispositivo'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 100,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Nombre visible'),
            onChanged: (_) => setDialogState(() {}),
            onSubmitted: (_) {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context, controller.text);
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: controller.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, controller.text),
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (name == null || name.trim() == _service.deviceName) return;
    try {
      await _service.setDeviceName(name);
      if (mounted) {
        setState(() {});
        _showMessage('Nombre actualizado.');
      }
    } catch (error) {
      _showMessage(error.toString());
    }
  }

  Future<void> _send(Peer peer) async {
    if (_busy) return;
    try {
      final file = await openFile();
      if (file == null) return;
      setState(() {
        _busy = true;
        _progress = null;
        _transferError = null;
      });
      await _service.sendFile(peer, file);
      _showMessage('Archivo enviado a ${peer.name}.');
    } catch (error) {
      if (mounted) {
        setState(() {
          _progress = null;
          _transferError = 'No se pudo enviar el archivo: $error';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openReceived(ReceivedDownload file) async {
    try {
      await _service.downloads.open(file);
    } catch (error) {
      if (mounted) {
        setState(() => _transferError = 'No se pudo abrir el archivo: $error');
      }
    }
  }

  Future<void> _export(ReceivedDownload file) async {
    try {
      final exported = await _service.downloads.forExport(file);
      if (!mounted) return;
      if (Platform.isAndroid || Platform.isIOS) {
        final box = context.findRenderObject() as RenderBox?;
        await SharePlus.instance.share(
          ShareParams(
            files: [exported],
            sharePositionOrigin: box == null
                ? null
                : box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      } else {
        final location = await getSaveLocation(suggestedName: file.name);
        if (location != null) {
          await exported.saveTo(location.path);
          _showMessage('Archivo guardado en ${location.path}.');
        }
      }
    } catch (error) {
      _showMessage(error.toString());
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _peerAction(Peer peer, String choice) async {
    try {
      if (choice == 'remove') {
        await _service.removePeer(peer.id);
        _showMessage(
          _service.pendingRevocations.contains(peer.id)
              ? 'Desvinculado aquí. Se avisará al otro equipo cuando vuelva a estar disponible.'
              : 'Dispositivos desvinculados.',
        );
      } else if (choice == 'trust') {
        await _setTrusted(peer);
      }
    } catch (error) {
      _showMessage(error.toString());
    }
  }

  Future<bool> _confirmQuick(QuickOffer offer) async {
    if (!mounted) return false;
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('${offer.senderName} quiere enviarte archivos'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Aceptá solo si este código coincide con el que ves en el otro equipo. No se guardará una vinculación.',
                ),
                const SizedBox(height: 16),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${offer.code.substring(0, 3)} ${offer.code.substring(3)}',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                ),
                const SizedBox(height: 16),
                for (final file in offer.files.take(10))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('${file.name} · ${_size(file.size)}'),
                  ),
                if (offer.files.length > 10)
                  Text('Y ${offer.files.length - 10} archivo(s) más.'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Rechazar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('El código coincide · Aceptar'),
          ),
        ],
      ),
    );
    final timer = Timer(const Duration(minutes: 2), () {
      if (route.isActive) navigator.removeRoute(route, false);
    });
    try {
      return await navigator.push(route) ?? false;
    } finally {
      timer.cancel();
    }
  }

  List<QuickDestination> _quickLan() {
    final result = <String, QuickDestination>{};
    for (final device in [
      ...?_discovery?.devices.values,
      ...?_quickDiscovery?.devices.values,
    ]) {
      final invite = device.invitation;
      result[device.id] = lanDestination(
        id: device.id,
        name: device.name,
        hosts: invite.hosts,
        port: invite.port,
      );
    }
    for (final peer in _service.peers.values) {
      if (peer.verified) {
        result.putIfAbsent(
          peer.id,
          () => lanDestination(
            id: peer.id,
            name: peer.name,
            hosts: [peer.host],
            port: peer.port,
          ),
        );
      }
    }
    return result.values.toList();
  }

  Future<void> _drainShared() async {
    if (_loading || _error != null || _sharing || _direct == null || !mounted) {
      return;
    }
    _sharing = true;
    try {
      while (_sharedQueue.isNotEmpty) {
        if (!mounted) break;
        final batch = _sharedQueue.removeAt(0);
        try {
          await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => QuickShareDialog(
              files: batch.files,
              deviceName: _service.deviceName,
              direct: _direct!,
              lan: _quickLan,
            ),
          );
        } finally {
          await _incomingShares.release(batch);
        }
      }
    } finally {
      _sharing = false;
    }
  }

  Future<void> _shareNearby() async {
    try {
      final files = await openFiles();
      if (files.isEmpty || !mounted) return;
      _sharedQueue.add(SharedBatch(files));
      await _drainShared();
    } catch (error) {
      if (mounted) {
        setState(
          () => _transferError = 'No se pudieron preparar los archivos: $error',
        );
      }
    }
  }

  Future<void> _toggleDirectReceiving() async {
    final direct = _direct;
    if (direct == null) return;
    _directTimer?.cancel();
    if (_service.directReceiving) {
      setState(() => _service.directReceiving = false);
      await _quickDiscovery?.advertise(null, null);
      await direct.release('receive');
    } else {
      setState(() => _service.directReceiving = true);
      await _quickDiscovery?.advertise(
        _service.invitation,
        _service.nearbyPublicKey,
      );
      await direct.acquire('receive');
      _directTimer = Timer(const Duration(minutes: 10), () {
        if (mounted) setState(() => _service.directReceiving = false);
        unawaited(_quickDiscovery?.advertise(null, null));
        unawaited(direct.release('receive'));
      });
      _showMessage(
        direct.message ?? 'Recepción cercana activada durante 10 minutos.',
      );
    }
  }

  Future<void> _chooseDownloads() async {
    try {
      await _service.downloads.chooseDirectory();
      if (mounted) setState(() {});
    } catch (error) {
      _showMessage(error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final peers = _service.peers.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final nearby =
        _discovery?.devices.values
            .where((device) => !_service.peers.containsKey(device.id))
            .toList() ??
        [];
    nearby.sort((a, b) => a.name.compareTo(b.name));
    return LanLinkDashboard(
      deviceName: _service.deviceName,
      visible: _service.visibleOnLan,
      peers: peers,
      nearby: nearby,
      files: _loading || _error != null
          ? Future.value([])
          : _service.receivedFiles(),
      downloadsLabel: _service.downloads.label,
      linkController: _linkController,
      onShareNearby: _shareNearby,
      onDirectReceive: _toggleDirectReceiving,
      directReceiving: _service.directReceiving,
      onEditName: _editDeviceName,
      onVisibleChanged: _discovery == null ? null : _setVisibleOnLan,
      onShowQr: _showQr,
      onScanQr: _scanQr,
      onConfigureKey: _configurePairingKey,
      onPairLink: _pair,
      onPairNearby: (device) => _pairNearby(device.invitation),
      onSend: _send,
      onPeerAction: _peerAction,
      onOpenFile: _openReceived,
      onExportFile: _export,
      onClearError: () => setState(() => _transferError = null),
      onChooseDownloads: Platform.isIOS ? _chooseDownloads : null,
      loading: _loading,
      busy: _busy,
      startupError: _error,
      discoveryError: _discoveryError,
      transferError: _transferError,
      progress: _progress,
      pendingRevocations: _service.pendingRevocations.length,
    );
  }

  @override
  void dispose() {
    _directTimer?.cancel();
    _incomingShares.dispose();
    unawaited(_direct?.release('receive'));
    _reconnectTimer?.cancel();
    _linkController.dispose();
    unawaited(_quickDiscovery?.dispose());
    unawaited(_discovery?.dispose());
    unawaited(_service.dispose());
    super.dispose();
  }
}

class _ScannerDialog extends StatefulWidget {
  const _ScannerDialog();

  @override
  State<_ScannerDialog> createState() => _ScannerDialogState();
}

class _ScannerDialogState extends State<_ScannerDialog> {
  bool _found = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Escanear QR'),
    content: SizedBox(
      width: 360,
      height: 360,
      child: MobileScanner(
        onDetect: (capture) {
          if (_found) return;
          final value = capture.barcodes.firstOrNull?.rawValue;
          if (value != null && value.startsWith('lanlink://pair/')) {
            _found = true;
            Navigator.pop(context, value);
          }
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
    ],
  );
}

String _size(int count) {
  if (count < 1024) return '$count B';
  if (count < 1024 * 1024) return '${(count / 1024).toStringAsFixed(1)} KiB';
  if (count < 1024 * 1024 * 1024) {
    return '${(count / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(count / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
}
