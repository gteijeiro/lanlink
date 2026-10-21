import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

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
  final TextEditingController _linkController = TextEditingController();
  bool _loading = true;
  bool _busy = false;
  String? _error;
  TransferProgress? _progress;

  @override
  void initState() {
    super.initState();
    _service.onPairRequest = _confirmPair;
    _service.onFileOffer = _confirmFile;
    _service.onPeersChanged = () {
      if (mounted) setState(() {});
    };
    _service.onProgress = (progress) {
      if (mounted) setState(() => _progress = progress);
    };
    _start();
  }

  Future<void> _start() async {
    try {
      await _service.start();
    } catch (error) {
      _error = error.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<bool> _confirmPair(PairRequest request) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('Emparejar dispositivo'),
            content: Text(
              '${request.name} leyó tu QR y quiere conectarse. ¿Lo aceptás?',
            ),
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
              '${offer.peer.name} quiere enviarte “${offer.name}” (${_size(offer.size)}).\n\nSe guardará en “LanLink Recibidos” dentro de los documentos de la app.',
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

  Future<void> _pair(String value) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _service.pair(value);
      _linkController.clear();
      _showMessage('Dispositivos emparejados. Ya podés enviar archivos.');
    } catch (error) {
      _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send(Peer peer) async {
    if (_busy) return;
    try {
      final file = await openFile();
      if (file == null) return;
      setState(() => _busy = true);
      await _service.sendFile(peer, file);
      _showMessage('Archivo enviado a ${peer.name}.');
    } catch (error) {
      _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(File file) async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final box = context.findRenderObject() as RenderBox?;
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path)],
            sharePositionOrigin: box == null
                ? null
                : box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      } else {
        final location = await getSaveLocation(
          suggestedName: file.uri.pathSegments.last,
        );
        if (location != null) await XFile(file.path).saveTo(location.path);
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
    return Scaffold(
      appBar: AppBar(title: const Text('LanLink')),
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
                            Text(_service.deviceName),
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
                      'Mis dispositivos',
                      style: Theme.of(context).textTheme.titleLarge,
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
                          subtitle: Text('${peer.host}:${peer.port}'),
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
                                  if (choice == 'remove') {
                                    await _service.removePeer(peer.id);
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'remove',
                                    child: Text('Olvidar dispositivo'),
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
                    if (_progress != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _progress!.incoming
                            ? 'Recibiendo de ${_progress!.peerName}'
                            : 'Enviando a ${_progress!.peerName}',
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
                    FutureBuilder<List<File>>(
                      future: _service.receivedFiles(),
                      builder: (context, snapshot) {
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
                                title: Text(file.uri.pathSegments.last),
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
    _linkController.dispose();
    _service.dispose();
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
