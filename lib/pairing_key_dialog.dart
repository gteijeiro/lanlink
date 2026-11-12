import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'pairing_password.dart';
import 'transfer_service.dart';

typedef PairingKeyShare = Future<void> Function(String text, Rect? origin);

class PairingKeyDialog extends StatefulWidget {
  const PairingKeyDialog({super.key, required this.service, this.share});
  final TransferService service;
  final PairingKeyShare? share;
  @override
  State<PairingKeyDialog> createState() => _PairingKeyDialogState();
}

class _PairingKeyDialogState extends State<PairingKeyDialog> {
  late final TextEditingController _controller;
  bool _busy = false;
  bool _visible = false;
  String? _error;
  String? _message;
  TransferService get service => widget.service;
  bool get _saved =>
      service.pairingKey != null && service.pairingKey == _controller.text;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: service.pairingKey ?? '');
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await service.setPairingKey(_controller.text);
      if (mounted) setState(() => _message = 'Clave guardada y activada.');
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(bool enabled) async {
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      if (enabled) {
        if (pairingPasswordLength(_controller.text) >= 6) {
          await service.setPairingKey(_controller.text);
        } else {
          final generated = await service.enablePairingKey();
          if (mounted) _controller.text = generated;
        }
      } else {
        await service.disablePairingKey();
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    if (!_saved) {
      setState(() {});
      return;
    }
    await Clipboard.setData(ClipboardData(text: service.pairingKey!));
    if (mounted) setState(() => _message = 'Clave copiada.');
  }

  Future<void> _share(BuildContext anchorContext) async {
    if (!_saved) {
      setState(() {});
      return;
    }
    final text =
        'Clave de vinculación de LanLink para ${service.deviceName}:\n${service.pairingKey!}';
    final box = anchorContext.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    try {
      if (widget.share != null) {
        await widget.share!(text, origin);
      } else {
        await SharePlus.instance.share(
          ShareParams(
            text: text,
            subject: 'Clave de vinculación de LanLink',
            sharePositionOrigin: origin,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Este sistema no pudo abrir Compartir. Podés usar Copiar.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = pairingPasswordLength(_controller.text);
    final strength = pairingPasswordStrength(_controller.text);
    const labels = ['Muy débil', 'Débil', 'Media', 'Fuerte'];
    final colors = [
      Theme.of(context).colorScheme.error,
      Colors.deepOrange,
      Colors.amber.shade800,
      Colors.green.shade700,
    ];
    return AlertDialog(
      title: const Text('Clave de vinculación'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Quien tenga esta clave podrá vincularse sin aprobación mientras LanLink esté abierto y visible en la red.',
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Permitir vinculación con clave'),
                value: service.pairingKey != null,
                onChanged: _busy ? null : _toggle,
              ),
              TextField(
                key: const ValueKey('pairing-key-input'),
                controller: _controller,
                enabled: !_busy,
                obscureText: !_visible,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => setState(() {
                  _error = null;
                  _message = null;
                }),
                decoration: InputDecoration(
                  labelText: 'Tu clave',
                  helperText: 'Mínimo 6 caracteres',
                  counterText: '$count caracteres',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: _visible ? 'Ocultar clave' : 'Mostrar clave',
                    onPressed: () => setState(() => _visible = !_visible),
                    icon: Icon(
                      _visible ? Icons.visibility_off : Icons.visibility,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text('Fortaleza: ${labels[strength]}'),
              const SizedBox(height: 5),
              LinearProgressIndicator(
                value: (strength + 1) / 4,
                color: colors[strength],
              ),
              const SizedBox(height: 5),
              const Text(
                'Estimación orientativa. No impide guardar una clave débil.',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  FilledButton(
                    onPressed: _busy || count < 6 ? null : _save,
                    child: Text(
                      service.pairingKey == null
                          ? 'Guardar y activar'
                          : 'Guardar clave',
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('Generar clave corta'),
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _controller.text = generatePairingPassword();
                            _error = null;
                            _message =
                                'Clave generada. Guardala para activarla.';
                          }),
                  ),
                ],
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(),
                ),
              if (service.pairingKey != null && !_saved)
                const Text(
                  'Hay cambios sin guardar. Guardá la clave antes de copiarla o compartirla.',
                ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: !_busy && _saved ? _copy : null,
                    icon: const Icon(Icons.copy),
                    label: const Text('Copiar'),
                  ),
                  Builder(
                    builder: (anchorContext) => TextButton.icon(
                      onPressed: !_busy && _saved
                          ? () => _share(anchorContext)
                          : null,
                      icon: const Icon(Icons.share),
                      label: const Text('Compartir'),
                    ),
                  ),
                ],
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (_message != null) Text(_message!),
              const SizedBox(height: 8),
              const Text(
                'Cambiar la clave conserva los vínculos existentes. Los archivos solo se aceptan automáticamente de los equipos que marques como de confianza.',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
