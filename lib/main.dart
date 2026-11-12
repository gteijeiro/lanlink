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
import 'transfer_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LanLinkApp());
}

class LanLinkApp extends StatelessWidget {
  const LanLinkApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'LanLink',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff176b61)),
      useMaterial3: true,
    ),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TransferService _service = TransferService();
  DiscoveryService? _discovery;
  final TextEditingController _linkController = TextEditingController();
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
    _start();
  }

  Future<void> _start() async {
    try {
      await _service.start();
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
                    hintText: 'LL1-…',
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
              onPressed: controller.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, controller.text.trim()),
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
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Clave de vinculación'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Quien tenga esta clave podrá vincularse con este equipo sin aprobación mientras LanLink esté abierto y visible en la red. Los archivos seguirán pidiendo aprobación, salvo que marques al equipo como de confianza.',
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Permitir vinculación con clave'),
                  value: _service.pairingKey != null,
                  onChanged: (value) async {
                    try {
                      if (value) {
                        await _service.enablePairingKey();
                      } else {
                        await _service.disablePairingKey();
                      }
                      if (context.mounted) update(() {});
                      if (mounted) setState(() {});
                    } catch (error) {
                      _showMessage(error.toString());
                    }
                  },
                ),
                if (_service.pairingKey != null) ...[
                  SelectableText(_service.pairingKey!),
                  const SizedBox(height: 8),
                  Wrap(
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.copy),
                        label: const Text('Copiar clave'),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: _service.pairingKey!),
                          );
                          _showMessage(
                            'Clave copiada. Compartila solo con quien quieras vincular.',
                          );
                        },
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.refresh),
                        label: const Text('Renovar clave'),
                        onPressed: () async {
                          try {
                            await _service.rotatePairingKey();
                            if (context.mounted) update(() {});
                          } catch (error) {
                            _showMessage(error.toString());
                          }
                        },
                      ),
                    ],
                  ),
                  const Text(
                    'Renovarla invalida la clave anterior para nuevos vínculos. Los dispositivos ya vinculados se conservan.',
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      ),
    );
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('LanLink'),
        actions: [
          IconButton(
            tooltip: 'Clave de vinculación',
            icon: const Icon(Icons.key),
            onPressed: _loading || _busy ? null : _configurePairingKey,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: SelectableText('No se pudo iniciar: $_error'),
                )
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Este dispositivo',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 5),
                            Row(
                              children: [
                                Expanded(child: Text(_service.deviceName)),
                                IconButton(
                                  tooltip: 'Editar nombre',
                                  onPressed: _editDeviceName,
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                              ],
                            ),
                            SwitchListTile.adaptive(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Visible en la red'),
                              subtitle: const Text(
                                'Otros equipos con LanLink podrán encontrarte mientras la app esté abierta.',
                              ),
                              value: _service.visibleOnLan,
                              onChanged: _discovery == null
                                  ? null
                                  : _setVisibleOnLan,
                            ),
                            const SizedBox(height: 14),
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                FilledButton.icon(
                                  onPressed: _busy ? null : _showQr,
                                  icon: const Icon(Icons.qr_code),
                                  label: const Text('Mostrar mi QR'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _busy ? null : _scanQr,
                                  icon: const Icon(Icons.qr_code_scanner),
                                  label: const Text('Escanear QR'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Ambos equipos deben estar en la misma red local y tener la app abierta.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '¿No podés escanear?',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _linkController,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        labelText: 'Pegá aquí el enlace del QR',
                        suffixIcon: IconButton(
                          tooltip: 'Emparejar',
                          onPressed: _busy
                              ? null
                              : () => _pair(_linkController.text),
                          icon: const Icon(Icons.link),
                        ),
                      ),
                      onSubmitted: _busy ? null : _pair,
                    ),
                    const SizedBox(height: 22),
                    Text(
                      'Disponibles en mi red',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (_discoveryError != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'No se pudo buscar dispositivos: $_discoveryError',
                        ),
                      )
                    else if (nearby.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 18),
                        child: Text('No hay otros equipos visibles por ahora.'),
                      ),
                    for (final device in nearby)
                      Card(
                        child: ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.wifi)),
                          title: Text(device.name),
                          subtitle: const Text('Disponible en la red local'),
                          trailing: FilledButton(
                            onPressed: _busy
                                ? null
                                : () => _pairNearby(device.invitation),
                            child: const Text('Conectar'),
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    Text(
                      'Mis dispositivos',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (_service.pendingRevocations.isNotEmpty)
                      Text(
                        '${_service.pendingRevocations.length} desvinculación(es) pendiente(s). Se avisará al otro equipo cuando vuelva a estar disponible.',
                      ),
                    if (peers.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 18),
                        child: Text('Todavía no hay dispositivos emparejados.'),
                      ),
                    for (final peer in peers)
                      Card(
                        child: ListTile(
                          leading: const CircleAvatar(
                            child: Icon(Icons.devices),
                          ),
                          title: Text(peer.name),
                          subtitle: Text(
                            '${peer.trustedForFiles ? 'De confianza · ' : ''}${peer.verified ? 'Identidad verificada · ${peer.host}:${peer.port}' : 'Buscando en la red · Última IP: ${peer.host}'}',
                          ),
                          trailing: Wrap(
                            spacing: 4,
                            children: [
                              IconButton(
                                tooltip: 'Enviar archivo',
                                onPressed: _busy ? null : () => _send(peer),
                                icon: const Icon(Icons.upload_file),
                              ),
                              PopupMenuButton<String>(
                                tooltip: 'Opciones',
                                onSelected: (choice) async {
                                  try {
                                    if (choice == 'remove') {
                                      await _service.removePeer(peer.id);
                                      _showMessage(
                                        _service.pendingRevocations.contains(
                                              peer.id,
                                            )
                                            ? 'Desvinculado aquí. Se avisará al otro equipo cuando vuelva a estar disponible.'
                                            : 'Dispositivos desvinculados.',
                                      );
                                    } else if (choice == 'trust') {
                                      await _setTrusted(peer);
                                    }
                                  } catch (error) {
                                    _showMessage(error.toString());
                                  }
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                    value: 'trust',
                                    child: Text(
                                      peer.trustedForFiles
                                          ? 'Pedir aprobación para archivos'
                                          : 'Aceptar archivos automáticamente',
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'remove',
                                    child: Text('Desvincular en ambos equipos'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 14),
                        child: LinearProgressIndicator(),
                      ),
                    if (_transferError != null)
                      Card(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: ListTile(
                          leading: const Icon(Icons.error_outline),
                          title: const Text('La transferencia falló'),
                          subtitle: SelectableText(_transferError!),
                          trailing: IconButton(
                            tooltip: 'Cerrar error',
                            icon: const Icon(Icons.close),
                            onPressed: () =>
                                setState(() => _transferError = null),
                          ),
                        ),
                      ),
                    if (_progress != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _progress!.finished
                            ? (_progress!.incoming
                                  ? 'Archivo recibido'
                                  : 'Archivo enviado')
                            : (_progress!.incoming
                                  ? 'Recibiendo de ${_progress!.peerName}'
                                  : 'Enviando a ${_progress!.peerName}'),
                      ),
                      Text(
                        _progress!.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 5),
                      LinearProgressIndicator(
                        value: _progress!.total == 0
                            ? 1
                            : _progress!.done / _progress!.total,
                      ),
                      Text(
                        '${_size(_progress!.done)} / ${_size(_progress!.total)}',
                      ),
                    ],
                    const SizedBox(height: 22),
                    Text(
                      'Archivos recibidos',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text('Destino: ${_service.downloads.label}'),
                    if (Platform.isIOS)
                      TextButton.icon(
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Elegir carpeta Descargas'),
                        onPressed: _busy
                            ? null
                            : () async {
                                try {
                                  await _service.downloads.chooseDirectory();
                                  if (mounted) setState(() {});
                                } catch (error) {
                                  _showMessage(error.toString());
                                }
                              },
                      ),
                    FutureBuilder<List<ReceivedDownload>>(
                      future: _service.receivedFiles(),
                      builder: (context, snapshot) {
                        if (snapshot.hasError) {
                          return Text(
                            'No se pudieron leer las descargas: ${snapshot.error}',
                          );
                        }
                        final files = snapshot.data ?? [];
                        if (files.isEmpty) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 18),
                            child: Text('Todavía no recibiste archivos.'),
                          );
                        }
                        return Column(
                          children: [
                            for (final file in files)
                              ListTile(
                                leading: const Icon(
                                  Icons.insert_drive_file_outlined,
                                ),
                                title: Text(file.name),
                                trailing: IconButton(
                                  tooltip: Platform.isAndroid || Platform.isIOS
                                      ? 'Compartir o guardar'
                                      : 'Exportar',
                                  icon: const Icon(
                                    Icons.file_download_outlined,
                                  ),
                                  onPressed: () => _export(file),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _linkController.dispose();
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
