import 'dart:io';

import 'package:flutter/material.dart';

import '../discovery_service.dart';
import '../download_storage.dart';
import '../transfer_service.dart';
import 'file_type_icon.dart';

class LanLinkDashboard extends StatefulWidget {
  const LanLinkDashboard({
    super.key,
    required this.deviceName,
    required this.visible,
    required this.peers,
    required this.nearby,
    required this.files,
    required this.downloadsLabel,
    required this.linkController,
    required this.onEditName,
    required this.onVisibleChanged,
    required this.onShowQr,
    required this.onScanQr,
    required this.onConfigureKey,
    required this.onPairLink,
    required this.onPairNearby,
    required this.onSend,
    required this.onPeerAction,
    required this.onOpenFile,
    required this.onExportFile,
    required this.onClearError,
    this.loading = false,
    this.busy = false,
    this.startupError,
    this.discoveryError,
    this.transferError,
    this.progress,
    this.pendingRevocations = 0,
    this.canOpenFiles,
    this.usesShareSheet,
    this.onChooseDownloads,
  });
  final String deviceName, downloadsLabel;
  final bool visible, loading, busy;
  final String? startupError, discoveryError, transferError;
  final int pendingRevocations;
  final List<Peer> peers;
  final List<NearbyDevice> nearby;
  final Future<List<ReceivedDownload>> files;
  final TextEditingController linkController;
  final VoidCallback onEditName,
      onShowQr,
      onScanQr,
      onConfigureKey,
      onClearError;
  final ValueChanged<bool>? onVisibleChanged;
  final ValueChanged<String> onPairLink;
  final ValueChanged<NearbyDevice> onPairNearby;
  final ValueChanged<Peer> onSend;
  final void Function(Peer, String) onPeerAction;
  final ValueChanged<ReceivedDownload> onOpenFile, onExportFile;
  final TransferProgress? progress;
  final bool? canOpenFiles, usesShareSheet;
  final VoidCallback? onChooseDownloads;

  @override
  State<LanLinkDashboard> createState() => _LanLinkDashboardState();
}

class _LanLinkDashboardState extends State<LanLinkDashboard> {
  int _page = 0;
  FileCategory? _category;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  ColorScheme get colors => Theme.of(context).colorScheme;
  bool get disabled => widget.busy || widget.loading;
  bool get mobileShare =>
      widget.usesShareSheet ?? (Platform.isAndroid || Platform.isIOS);

  void _navigate(int index) {
    if (_page == index) return;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() => _page = index);
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 960;
      return Scaffold(
        body: SafeArea(
          bottom: false,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (wide) _sidebar(),
              Expanded(
                child: Column(
                  children: [
                    if (!wide) _mobileBrand(),
                    Expanded(
                      child: widget.loading
                          ? const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircularProgressIndicator(),
                                  SizedBox(height: 20),
                                  Text('Preparando tus conexiones…'),
                                ],
                              ),
                            )
                          : widget.startupError != null
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: _empty(
                                  Icons.error_outline_rounded,
                                  'No se pudo iniciar LanLink',
                                  widget.startupError!,
                                ),
                              ),
                            )
                          : Scrollbar(
                              controller: _scroll,
                              child: ListView(
                                controller: _scroll,
                                padding: EdgeInsets.fromLTRB(
                                  wide ? 36 : 20,
                                  wide ? 32 : 16,
                                  wide ? 36 : 20,
                                  28 + MediaQuery.paddingOf(context).bottom,
                                ),
                                children: [
                                  Align(
                                    alignment: Alignment.topCenter,
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 1160,
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          _pageHeading(wide),
                                          const SizedBox(height: 24),
                                          if (widget.transferError != null) ...[
                                            _errorCard(),
                                            const SizedBox(height: 20),
                                          ],
                                          if (widget.progress != null) ...[
                                            _transferCard(),
                                            const SizedBox(height: 20),
                                          ] else if (widget.busy) ...[
                                            const LinearProgressIndicator(),
                                            const SizedBox(height: 20),
                                          ],
                                          if (_page == 0)
                                            _devicesPage(wide)
                                          else
                                            _filesPage(),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: _page,
                onDestinationSelected: _navigate,
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.devices_outlined),
                    selectedIcon: Icon(Icons.devices_rounded),
                    label: 'Dispositivos',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.folder_outlined),
                    selectedIcon: Icon(Icons.folder_rounded),
                    label: 'Recibidos',
                  ),
                ],
              ),
      );
    },
  );

  Widget _brand() => Row(
    children: [
      Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xff397ed1), Color(0xff14988d)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(13),
        ),
        child: const Icon(
          Icons.swap_horiz_rounded,
          color: Colors.white,
          size: 29,
        ),
      ),
      const SizedBox(width: 12),
      Flexible(
        child: Text(
          'LanLink',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(letterSpacing: -.6),
        ),
      ),
    ],
  );

  Widget _mobileBrand() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
    child: Row(
      children: [
        Expanded(child: _brand()),
        IconButton(
          tooltip: 'Escanear QR',
          onPressed: disabled ? null : widget.onScanQr,
          icon: const Icon(Icons.qr_code_scanner_rounded),
        ),
        IconButton(
          tooltip: 'Clave de vinculación',
          onPressed: disabled ? null : widget.onConfigureKey,
          icon: const Icon(Icons.key_outlined),
        ),
      ],
    ),
  );

  Widget _sidebar() => Container(
    width: 244,
    decoration: BoxDecoration(
      color: colors.surface,
      border: Border(right: BorderSide(color: colors.outlineVariant)),
    ),
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 0, 36),
              child: _brand(),
            ),
            _navItem(0, Icons.devices_rounded, 'Dispositivos'),
            const SizedBox(height: 8),
            _navItem(1, Icons.folder_rounded, 'Recibidos'),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: disabled ? null : widget.onConfigureKey,
              icon: const Icon(Icons.key_outlined, size: 19),
              label: const Text('Clave de vinculación'),
            ),
            const SizedBox(height: 28),
            const SizedBox(height: 12),
            _localDevice(compact: true),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 14,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'Transferencias cifradas',
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    ),
  );

  Widget _navItem(int index, IconData icon, String title) => Material(
    color: _page == index
        ? colors.primary.withValues(alpha: .10)
        : Colors.transparent,
    borderRadius: BorderRadius.circular(14),
    child: ListTile(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      leading: Icon(
        icon,
        color: _page == index ? colors.primary : colors.onSurfaceVariant,
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: _page == index ? FontWeight.w700 : FontWeight.w500,
          color: _page == index ? colors.primary : colors.onSurfaceVariant,
        ),
      ),
      selected: _page == index,
      onTap: () => _navigate(index),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
    ),
  );

  Widget _pageHeading(bool wide) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        _page == 0 ? 'Tus equipos, conectados.' : 'Tus archivos, a mano.',
        style: (wide
            ? Theme.of(context).textTheme.headlineLarge
            : Theme.of(context).textTheme.headlineSmall),
      ),
      const SizedBox(height: 8),
      Text(
        _page == 0
            ? 'Compartí archivos entre tus dispositivos, sin cables.'
            : 'Encontrá y abrí todo lo que recibiste.',
        style: Theme.of(context).textTheme.bodyLarge
            ?.copyWith(color: colors.onSurfaceVariant, height: 1.5),
      ),
    ],
  );

  Widget _localDevice({bool compact = false}) => compact
      ? _localDeviceDetails()
      : Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          decoration: BoxDecoration(
            color: colors.primary.withValues(alpha: .055),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: colors.primary.withValues(alpha: .12)),
          ),
          child: Row(
            children: [
              Icon(
                _deviceIcon(widget.deviceName),
                color: colors.primary,
                size: 26,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.deviceName,
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.visible ? 'Visible en la red' : 'Oculto en la red',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Editar nombre',
                onPressed: disabled ? null : widget.onEditName,
                icon: const Icon(Icons.edit_outlined, size: 18),
              ),
              Semantics(
                label: 'Visible en la red mientras LanLink esté abierto',
                child: Switch.adaptive(
                  value: widget.visible,
                  onChanged: disabled ? null : widget.onVisibleChanged,
                ),
              ),
            ],
          ),
        );

  Widget _localDeviceDetails() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: colors.primary.withValues(alpha: .055),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: colors.primary.withValues(alpha: .12)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ESTE DISPOSITIVO',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: colors.primary,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(
              _deviceIcon(widget.deviceName),
              color: colors.primary,
              size: 22,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.deviceName,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: 'Editar nombre',
              onPressed: disabled ? null : widget.onEditName,
              icon: const Icon(Icons.edit_outlined, size: 18),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                widget.visible ? 'Visible en la red' : 'Oculto en la red',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            Semantics(
              label: 'Visible en la red',
              child: Switch.adaptive(
                value: widget.visible,
                onChanged: disabled ? null : widget.onVisibleChanged,
              ),
            ),
          ],
        ),
        Text(
          'Mientras LanLink esté abierto.',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    ),
  );

  Widget _devicesPage(bool wide) => LayoutBuilder(
    builder: (context, constraints) {
      final split = constraints.maxWidth >= 830;
      final devices = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.pendingRevocations > 0) ...[
            _notice(
              '${widget.pendingRevocations} desvinculación(es) pendiente(s). Se avisará al otro equipo cuando vuelva a estar disponible.',
            ),
            const SizedBox(height: 12),
          ],
          if (widget.peers.isNotEmpty) ...[
            _sectionTitle(
              'Mis dispositivos',
              Icons.devices_outlined,
              count: widget.peers.length,
            ),
            const SizedBox(height: 14),
            for (final peer in widget.peers)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _peerCard(peer),
              ),
            const SizedBox(height: 24),
          ],
          _sectionTitle(
            'Cerca tuyo',
            Icons.radar_rounded,
            count: widget.nearby.length,
          ),
          const SizedBox(height: 6),
          Text(
            'Equipos visibles en tu misma red Wi-Fi.',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          if (widget.discoveryError != null)
            _notice('No se pudo buscar dispositivos: ${widget.discoveryError}')
          else if (widget.nearby.isEmpty)
            _empty(
              Icons.wifi_find_rounded,
              'Buscando otros equipos',
              'Abrí LanLink en el otro dispositivo y activá su visibilidad.',
            ),
          for (final device in widget.nearby)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _nearbyCard(device),
            ),
        ],
      );
      final connect = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _connectCard(),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 17,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Mantené ambas apps abiertas y los equipos en la misma red local.',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant, height: 1.5),
                ),
              ),
            ],
          ),
        ],
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!wide) ...[_localDevice(), const SizedBox(height: 24)],
          if (split)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 5, child: devices),
                const SizedBox(width: 24),
                Expanded(flex: 4, child: connect),
              ],
            )
          else if (widget.peers.isEmpty && widget.nearby.isEmpty) ...[
            connect,
            const SizedBox(height: 28),
            devices,
          ] else ...[
            devices,
            const SizedBox(height: 28),
            connect,
          ],
        ],
      );
    },
  );

  Widget _connectCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.secondary.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.qr_code_scanner_rounded,
                  color: colors.secondary,
                  size: 28,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Conectar un equipo',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Un QR y listo.',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: disabled ? null : widget.onScanQr,
            icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
            label: const Text('Escanear QR'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: disabled ? null : widget.onShowQr,
            icon: const Icon(Icons.qr_code_2_rounded, size: 20),
            label: const Text('Mostrar mi QR'),
          ),
          const SizedBox(height: 8),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(top: 4, bottom: 8),
              title: Text(
                'Usar un enlace',
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
              children: [
                TextField(
                  controller: widget.linkController,
                  enabled: !disabled,
                  decoration: const InputDecoration(
                    labelText: 'Enlace de vinculación',
                    hintText: 'Pegá el enlace del QR',
                  ),
                  onSubmitted: disabled ? null : widget.onPairLink,
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: disabled
                        ? null
                        : () => widget.onPairLink(widget.linkController.text),
                    icon: const Icon(Icons.link_rounded),
                    label: const Text('Conectar con enlace'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _peerCard(Peer peer) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 10, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _deviceAvatar(peer.name, online: peer.verified),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      peer.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      peer.verified
                          ? 'Identidad verificada'
                          : 'Buscando en la red…',
                      style: TextStyle(
                        color: peer.verified
                            ? colors.primary
                            : colors.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                    if (peer.trustedForFiles)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Tooltip(
                          message: 'Aceptás sus archivos automáticamente.',
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.verified_user_outlined,
                                size: 14,
                                color: colors.primary,
                              ),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  'De confianza',
                                  style: TextStyle(
                                    color: colors.primary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Opciones de ${peer.name}',
                onSelected: (choice) {
                  if (choice == 'details') {
                    showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(peer.name),
                        content: SelectableText(
                          '${peer.verified ? 'Identidad verificada' : 'Dirección pendiente de verificar'}\n${peer.host}:${peer.port}',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Cerrar'),
                          ),
                        ],
                      ),
                    );
                  } else {
                    widget.onPeerAction(peer, choice);
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'trust',
                    enabled: !disabled,
                    child: Text(
                      peer.trustedForFiles
                          ? 'Pedir aprobación para archivos'
                          : 'Aceptar archivos automáticamente',
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'details',
                    child: Text('Detalles de conexión'),
                  ),
                  PopupMenuItem(
                    value: 'remove',
                    enabled: !disabled,
                    child: const Text('Desvincular en ambos equipos'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: disabled ? null : () => widget.onSend(peer),
            icon: const Icon(Icons.north_east_rounded, size: 18),
            label: const Text('Enviar archivo'),
          ),
        ],
      ),
    ),
  );

  Widget _nearbyCard(NearbyDevice device) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _deviceAvatar(device.name, online: true),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Listo para vincular',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextButton.icon(
            onPressed: disabled ? null : () => widget.onPairNearby(device),
            icon: const Icon(Icons.add_link_rounded, size: 19),
            label: const Text('Conectar'),
          ),
        ],
      ),
    ),
  );

  Widget _deviceAvatar(String name, {required bool online}) => Container(
    width: 48,
    height: 48,
    decoration: BoxDecoration(
      color: (online ? colors.primary : colors.onSurfaceVariant).withValues(
        alpha: .09,
      ),
      borderRadius: BorderRadius.circular(15),
    ),
    child: Icon(
      _deviceIcon(name),
      color: online ? colors.primary : colors.onSurfaceVariant,
      size: 26,
    ),
  );

  Widget _sectionTitle(String title, IconData icon, {int? count}) => Row(
    children: [
      Icon(icon, color: colors.primary, size: 20),
      const SizedBox(width: 10),
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
      if (count != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: colors.primary.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              color: colors.primary,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ),
    ],
  );

  Widget _filesPage() => FutureBuilder<List<ReceivedDownload>>(
    future: widget.files,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return _empty(
          Icons.folder_off_outlined,
          'No se pudieron leer los archivos',
          snapshot.error.toString(),
        );
      }
      if (!snapshot.hasData) {
        return const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      final all = snapshot.data!;
      final query = _search.text.trim().toLowerCase();
      final files = all
          .where(
            (file) =>
                file.name.toLowerCase().contains(query) &&
                (_category == null ||
                    FileVisual.forName(file.name).category == _category),
          )
          .toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.folder_open_rounded,
                        color: colors.primary,
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Carpeta de recepción',
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            const SizedBox(height: 4),
                            SelectableText(
                              widget.downloadsLabel,
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (widget.onChooseDownloads != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: disabled ? null : widget.onChooseDownloads,
                icon: const Icon(Icons.drive_folder_upload_outlined),
                label: const Text('Elegir carpeta Descargas'),
              ),
            ),
          const SizedBox(height: 20),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Buscar un archivo',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Limpiar búsqueda',
                      onPressed: () => setState(_search.clear),
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
          const SizedBox(height: 14),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final filter in <(FileCategory?, String)>[
                  (null, 'Todos'),
                  (FileCategory.image, 'Imágenes'),
                  (FileCategory.video, 'Videos'),
                  (FileCategory.audio, 'Audio'),
                  (FileCategory.document, 'Documentos'),
                  (FileCategory.archive, 'Comprimidos'),
                  (FileCategory.code, 'Código'),
                  (FileCategory.other, 'Otros'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(filter.$2),
                      selected: _category == filter.$1,
                      onSelected: (_) => setState(() => _category = filter.$1),
                      showCheckmark: false,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          _sectionTitle(
            'Recibidos',
            Icons.south_west_rounded,
            count: files.length,
          ),
          const SizedBox(height: 14),
          if (all.isEmpty)
            _empty(
              Icons.move_to_inbox_outlined,
              'Tu próxima entrega, acá',
              'Los archivos que recibas aparecerán en esta sección.',
            )
          else if (files.isEmpty)
            _empty(
              Icons.search_off_rounded,
              'No encontramos ese archivo',
              'Probá otro nombre o cambiá el filtro.',
            ),
          for (final file in files)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ReceivedFileCard(
                file: file,
                onOpen: (widget.canOpenFiles ?? Platform.isAndroid)
                    ? () => widget.onOpenFile(file)
                    : null,
                onExport: () => widget.onExportFile(file),
                share: mobileShare,
              ),
            ),
        ],
      );
    },
  );

  Widget _empty(IconData icon, String title, String description) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 28),
      child: Column(
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              color: colors.secondary.withValues(alpha: .07),
              borderRadius: BorderRadius.circular(21),
            ),
            child: Icon(icon, size: 30, color: colors.secondary),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            description,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant, height: 1.5),
          ),
        ],
      ),
    ),
  );

  Widget _notice(String message) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: colors.secondary.withValues(alpha: .07),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Text(
      message,
      style: TextStyle(color: colors.onSurfaceVariant, height: 1.5),
    ),
  );

  Widget _errorCard() => Card(
    color: colors.errorContainer,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 8, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, color: colors.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No se pudo completar la acción',
                  style: TextStyle(
                    color: colors.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  widget.transferError!,
                  style: TextStyle(color: colors.onErrorContainer),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Cerrar error',
            onPressed: widget.onClearError,
            icon: Icon(Icons.close_rounded, color: colors.onErrorContainer),
          ),
        ],
      ),
    ),
  );

  Widget _transferCard() {
    final progress = widget.progress!;
    final done = progress.finished;
    final value = progress.total == 0
        ? 1.0
        : (progress.done / progress.total).clamp(0.0, 1.0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  done ? Icons.check_circle_rounded : Icons.swap_vert_rounded,
                  color: colors.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    done
                        ? (progress.incoming
                              ? 'Archivo recibido'
                              : 'Archivo enviado')
                        : (progress.incoming
                              ? 'Recibiendo de ${progress.peerName}'
                              : 'Enviando a ${progress.peerName}'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Text(
                  '${(value * 100).round()}%',
                  style: TextStyle(
                    color: colors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FileTypeIcon(name: progress.fileName, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    progress.fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            LinearProgressIndicator(
              value: value,
              minHeight: 6,
              borderRadius: BorderRadius.circular(6),
            ),
            const SizedBox(height: 8),
            Text(
              '${_size(progress.done)} de ${_size(progress.total)}',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class ReceivedFileCard extends StatelessWidget {
  const ReceivedFileCard({
    super.key,
    required this.file,
    required this.onExport,
    required this.share,
    this.onOpen,
  });
  final ReceivedDownload file;
  final VoidCallback onExport;
  final VoidCallback? onOpen;
  final bool share;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide =
          constraints.maxWidth >= 650 &&
          MediaQuery.textScalerOf(context).scale(14) <= 21;
      final visual = FileVisual.forName(file.name);
      final date = file.modified.toLocal();
      final label =
          '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
      final info = InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              FileTypeIcon(name: file.name, size: wide ? 46 : 58),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      '${visual.label} · $label',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
      final actions = Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          if (onOpen != null)
            TextButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: const Text('Abrir con'),
            ),
          TextButton.icon(
            onPressed: onExport,
            icon: Icon(
              share ? Icons.share_outlined : Icons.save_alt_rounded,
              size: 18,
            ),
            label: Text(share ? 'Compartir' : 'Exportar'),
          ),
        ],
      );
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: wide
              ? Row(
                  children: [
                    Expanded(child: info),
                    const SizedBox(width: 20),
                    actions,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [info, const SizedBox(height: 12), actions],
                ),
        ),
      );
    },
  );
}

IconData _deviceIcon(String name) {
  final value = name.toLowerCase();
  if (value.contains('ipad') || value.contains('tablet')) {
    return Icons.tablet_mac_rounded;
  }
  if (value.contains('iphone') ||
      value.contains('android') ||
      value.contains('samsung') ||
      value.contains('pixel')) {
    return Icons.smartphone_rounded;
  }
  if (value.contains('mac') ||
      value.contains('laptop') ||
      value.contains('notebook')) {
    return Icons.laptop_mac_rounded;
  }
  if (value.contains('windows') ||
      value.contains('pc') ||
      value.contains('linux')) {
    return Icons.desktop_windows_rounded;
  }
  return Icons.devices_rounded;
}

String _size(int count) {
  if (count < 1024) return '$count B';
  if (count < 1024 * 1024) return '${(count / 1024).toStringAsFixed(1)} KB';
  if (count < 1024 * 1024 * 1024) {
    return '${(count / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(count / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
