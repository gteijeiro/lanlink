import 'dart:async';

import 'quick_transfer.dart';
import 'radio_rpc.dart';

int _priority(QuickDestination route) => switch (route.transport) {
  'Red local' => 0,
  'Wi-Fi directa' => 1,
  'Bluetooth' => 2,
  _ => 3,
};

Map<String, List<QuickDestination>> groupQuickRoutes(
  Iterable<QuickDestination> routes,
) {
  final groups = <String, List<QuickDestination>>{};
  for (final route in routes) {
    groups.putIfAbsent(route.id, () => []).add(route);
  }
  for (final group in groups.values) {
    group.sort((a, b) => _priority(a).compareTo(_priority(b)));
  }
  return groups;
}

/// Try available transports only before opening a transfer. Once a hello is
/// selected, pin the entire cryptographic session to it: rejection, a changed
/// commitment or a failed chunk must never trigger a second offer elsewhere.
class QuickRouteSelector {
  QuickRouteSelector(
    Iterable<QuickDestination> routes, {
    this.onSelected,
    this.timeout = const Duration(seconds: 20),
    bool Function()? cancelled,
  }) : routes = List.of(routes)
         ..sort((a, b) => _priority(a).compareTo(_priority(b))),
       cancelled = cancelled ?? (() => false);

  final List<QuickDestination> routes;
  final Duration timeout;
  final bool Function() cancelled;
  final void Function(QuickDestination route)? onSelected;
  QuickDestination? selected;
  int get chunkSize => selected?.chunkSize ?? quickMaxChunk;

  Future<Map<String, dynamic>> request(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (cancelled()) throw StateError('Envío cancelado.');
    final pinned = selected;
    if (pinned != null) return pinned.rpc(path, body);
    if (path != '/quick/hello') {
      throw StateError('Primero debe abrirse la conexión.');
    }
    for (final route in routes) {
      if (cancelled()) throw StateError('Envío cancelado.');
      Map<String, dynamic> hello;
      try {
        hello = await route.rpc(path, body).timeout(timeout);
        if (hello['v'] != quickVersion ||
            hello['session'] is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(hello['session']) ||
            hello['commit'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(hello['commit'])) {
          continue;
        }
      } catch (_) {
        continue;
      }
      if (cancelled()) throw StateError('Envío cancelado.');
      selected = route;
      onSelected?.call(route);
      return hello;
    }
    throw StateError(
      'No hay una conexión compatible disponible. Abrí LanLink y activá «Recibir cerca» en el receptor; revisá Wi-Fi, Bluetooth y sus permisos.',
    );
  }
}
