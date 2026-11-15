import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../ui/file_type_icon.dart';
import 'direct_coordinator.dart';
import 'quick_transfer.dart';
import 'radio_rpc.dart';
import 'route_selector.dart';

class QuickShareDialog extends StatefulWidget {
  const QuickShareDialog({
    super.key,
    required this.files,
    required this.deviceName,
    required this.direct,
    required this.lan,
  });
  final List<XFile> files;
  final String deviceName;
  final DirectCoordinator direct;
  final List<QuickDestination> Function() lan;
  @override
  State<QuickShareDialog> createState() => _QuickShareDialogState();
}

class _QuickShareDialogState extends State<QuickShareDialog> {
  QuickSender? _sender;
  QuickDestination? _target;
  Completer<bool>? _verification;
  QuickProgress? _progress;
  String? _code, _error;
  bool _sending = false, _canConfirm = false, _done = false, _choosing = false;
  Timer? _refresh;
  late final String _owner = 'share-${quickRandom()}';
  @override
  void initState() {
    super.initState();
    widget.direct.addListener(_changed);
    unawaited(widget.direct.acquire(_owner));
    _refresh = Timer.periodic(const Duration(seconds: 2), (_) => _changed());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _sender?.cancelled = true;
    if (_verification != null && !_verification!.isCompleted) {
      _verification!.complete(false);
    }
    _refresh?.cancel();
    widget.direct.removeListener(_changed);
    unawaited(widget.direct.release(_owner));
    super.dispose();
  }

  Future<void> _send(List<QuickDestination> routes) async {
    final destination = routes.first;
    setState(() {
      _target = destination;
      _sending = true;
      _choosing = true;
      _error = null;
      _code = null;
      _progress = null;
    });
    final sender = QuickSender(name: widget.deviceName);
    _sender = sender;
    final selector = QuickRouteSelector(
      routes,
      cancelled: () => sender.cancelled,
      onSelected: (route) {
        if (mounted) {
          setState(() {
            _target = route;
            _choosing = false;
          });
        }
      },
    );
    sender.onCode = (code) {
      if (mounted) setState(() => _code = code);
    };
    sender.confirmCode = (_) {
      _verification = Completer<bool>();
      if (mounted) setState(() => _canConfirm = true);
      return _verification!.future;
    };
    sender.onProgress = (progress) {
      if (mounted) {
        setState(() {
          _canConfirm = false;
          _progress = progress;
        });
      }
    };
    try {
      await sender.send(
        widget.files,
        selector.request,
        selectedChunkSize: () => selector.chunkSize,
      );
      if (mounted) setState(() => _done = true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _sending = false;
          _canConfirm = false;
          _code = null;
        });
      }
    }
  }

  Future<void> _systemShare() async {
    final box = context.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: widget.files,
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'No se pudo abrir Compartir: $error');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final destinations = groupQuickRoutes([
      ...widget.lan(),
      ...widget.direct.destinations,
    ]);
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(_done ? 'Envío completo' : 'Compartir con LanLink'),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${widget.files.length} archivo(s) · Sin guardar una vinculación',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              for (final file in widget.files.take(3))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      FileTypeIcon(name: file.name, size: 32),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          file.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              if (widget.files.length > 3)
                Text('Y ${widget.files.length - 3} archivo(s) más.'),
              const SizedBox(height: 16),
              if (_done) ...[
                Icon(
                  Icons.check_circle_rounded,
                  color: colors.primary,
                  size: 52,
                ),
                const SizedBox(height: 12),
                Text('El receptor verificó los archivos completos.'),
              ] else if (_sending) ...[
                Text(
                  'Destino: ${_target!.name} · ${_choosing ? 'Buscando conexión compatible…' : _target!.transport}',
                ),
                if (_target!.transport == 'Bluetooth')
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Bluetooth puede ser lento para videos grandes. No requiere Internet ni una Wi-Fi compartida.',
                    ),
                  ),
                const SizedBox(height: 14),
                if (_code != null && _progress == null) ...[
                  const Text(
                    'Compará este código con el que aparece en el receptor.',
                  ),
                  const SizedBox(height: 14),
                  Semantics(
                    label: 'Código de seguridad $_code',
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '${_code!.substring(0, 3)} ${_code!.substring(3)}',
                        style: TextStyle(
                          fontSize: 40,
                          fontWeight: FontWeight.bold,
                          color: colors.primary,
                          letterSpacing: 4,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_canConfirm)
                    FilledButton(
                      onPressed: () {
                        _verification!.complete(true);
                        setState(() => _canConfirm = false);
                      },
                      child: const Text('Los códigos coinciden · Enviar'),
                    )
                  else
                    const Text('Esperando la aceptación del otro equipo…'),
                ] else if (_progress != null) ...[
                  Text(_progress!.name),
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: _progress!.total == 0
                        ? 1
                        : _progress!.done / _progress!.total,
                  ),
                ] else
                  const LinearProgressIndicator(),
              ] else ...[
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: SelectableText(
                      _error!,
                      style: TextStyle(color: colors.error),
                    ),
                  ),
                Text(
                  'Elegí el destinatario',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (destinations.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Buscando equipos… Abrí LanLink en el receptor y activá «Recibir cerca» o su visibilidad en la red.',
                    ),
                  ),
                for (final routes in destinations.values)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      routes.first.transport == 'Bluetooth'
                          ? Icons.bluetooth_rounded
                          : Icons.devices_rounded,
                      color: colors.primary,
                    ),
                    title: Text(routes.first.name),
                    subtitle: Text(
                      'Automático · ${routes.map((route) => route.transport).toSet().join(" / ")}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _send(routes),
                  ),
                if (widget.direct.message != null)
                  Text(
                    widget.direct.message!,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                const SizedBox(height: 12),
                if (!Platform.isLinux) ...[
                  OutlinedButton.icon(
                    onPressed: _systemShare,
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Compartir fuera de LanLink'),
                  ),
                  const Text(
                    'Abre el menú del sistema. AirDrop y Quick Share dependen de la compatibilidad entre esos equipos; LanLink no los necesita para sus envíos.',
                  ),
                  const SizedBox(height: 12),
                ],
                const Text(
                  'LanLink elige una conexión compatible automáticamente. Android y iPhone usan red local o Bluetooth de LanLink. Entre equipos Apple, Wi-Fi directa necesita Wi-Fi encendida, aunque no esté conectada a una red. Bluetooth necesita estar activado y autorizado.',
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _done),
          child: Text(_done ? 'Listo' : 'Cancelar'),
        ),
      ],
    );
  }
}
