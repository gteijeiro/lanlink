import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bluetooth_transport.dart';
import 'quick_transfer.dart';
import 'radio_rpc.dart';

class DirectCoordinator extends ChangeNotifier {
  DirectCoordinator({
    required this.id,
    required this.name,
    required this.handle,
    required this.canReceive,
  });
  final String id, name;
  final QuickRpc handle;
  final bool Function() canReceive;
  static const channel = MethodChannel('lanlink/direct');
  final _owners = <String>{};
  final _apple = <String, QuickDestination>{};
  BluetoothTransport? _bluetooth;
  Future<void>? _starting;
  String? message;
  bool _paused = false;
  bool get active => _owners.isNotEmpty;
  List<QuickDestination> get destinations => [
    ..._apple.values,
    ...?_bluetooth?.destinations.values,
  ];

  Future<void> acquire(String owner) async {
    _owners.add(owner);
    if (_starting != null) {
      await _starting;
      if (_paused && !owner.startsWith('incoming-')) {
        _paused = false;
        try {
          await _bluetooth?.resumeDiscovery();
        } catch (_) {}
        if (Platform.isIOS || Platform.isMacOS) {
          try {
            await channel.invokeMethod<void>('start', {
              'id': id,
              'name': name,
              'advertise': canReceive(),
            });
          } catch (_) {}
        }
      }
      return;
    }
    _starting = _start();
    return _starting;
  }

  Future<void> _start() async {
    message = null;
    if (Platform.isIOS || Platform.isMacOS) {
      channel.setMethodCallHandler((call) async {
        if (call.method == 'error') {
          message = call.arguments as String?;
          notifyListeners();
        }
        if (call.method == 'request') {
          final args = (call.arguments as Map).cast<String, dynamic>();
          return handle(
            args['path'],
            (args['body'] as Map).cast<String, dynamic>(),
          );
        }
        if (call.method == 'peers') {
          _apple.clear();
          for (final raw in (call.arguments as List)) {
            final peer = (raw as Map).cast<String, dynamic>();
            final target = peer['id'] as String;
            // Keep each route: a stale LAN advertisement must not hide
            // a responding Apple peer-to-peer endpoint for the same device.
            final routeToken = peer['token'] as String? ?? target;
            _apple[routeToken] = QuickDestination(
              id: target,
              name: peer['name'],
              transport: peer['transport'] as String? ?? 'Wi-Fi directa',
              rpc: (path, body) async =>
                  (await channel.invokeMapMethod<String, dynamic>('request', {
                    'destination': peer['token'] ?? target,
                    'path': path,
                    'body': body,
                  }))!,
            );
          }
          notifyListeners();
        }
      });
      try {
        await channel.invokeMethod<void>('start', {
          'id': id,
          'name': name,
          'advertise': canReceive(),
        });
      } catch (_) {
        message =
            'La conexión Wi-Fi directa no está disponible en este equipo.';
      }
    }
    final bluetooth = BluetoothTransport(
      id: id,
      name: name,
      handle: handle,
      canReceive: canReceive,
    );
    _bluetooth = bluetooth;
    bluetooth.onChanged = notifyListeners;
    bluetooth.onError = (error) {
      message = error;
      notifyListeners();
    };
    try {
      await bluetooth.start();
    } catch (_) {
      message = 'No se pudo activar la búsqueda Bluetooth. Revisá los permisos y que esté encendido.';
    }
    notifyListeners();
  }

  Future<void> release(String owner) async {
    _owners.remove(owner);
    if (_owners.isNotEmpty) {
      if (_owners.every((value) => value.startsWith('incoming-'))) {
        await _starting;
        if (!_owners.every((value) => value.startsWith('incoming-'))) return;
        _paused = true;
        try {
          await _bluetooth?.pauseDiscovery();
        } catch (_) {}
        if (Platform.isIOS || Platform.isMacOS) {
          try {
            await channel.invokeMethod<void>('pauseDiscovery');
          } catch (_) {}
        }
      }
      return;
    }
    try {
      await _starting;
    } catch (_) {}
    if (_owners.isNotEmpty) return;
    await _bluetooth?.stop();
    _bluetooth = null;
    if (Platform.isIOS || Platform.isMacOS) {
      try {
        await channel.invokeMethod<void>('stop');
      } catch (_) {}
    }
    _apple.clear();
    _starting = null;
    _paused = false;
    notifyListeners();
  }
}

QuickDestination lanDestination({
  required String id,
  required String name,
  required List<String> hosts,
  required int port,
}) {
  return QuickDestination(
    id: id,
    name: name,
    transport: 'Red local',
    rpc: (path, body) async {
      Object? lastError;
      for (final host in hosts) {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 8);
        try {
          final request = await client.postUrl(
            Uri(scheme: 'http', host: host, port: port, path: path),
          );
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
          final response = await request.close().timeout(
            path == '/quick/offer'
                ? const Duration(minutes: 3)
                : const Duration(seconds: 45),
          );
          final bytes = BytesBuilder();
          await for (final block in response.timeout(
            const Duration(seconds: 45),
          )) {
            if (bytes.length + block.length > radioMaxFrame) {
              throw const FormatException('Respuesta demasiado grande.');
            }
            bytes.add(block);
          }
          if (response.statusCode != 200) {
            throw StateError(
              'El otro equipo no aceptó la operación. Revisá que tenga esta versión de LanLink y la recepción activada.',
            );
          }
          return (jsonDecode(utf8.decode(bytes.takeBytes())) as Map)
              .cast<String, dynamic>();
        } catch (error) {
          lastError = error;
        } finally {
          client.close(force: true);
        }
      }
      throw StateError('No se pudo conectar con $name: $lastError');
    },
  );
}
