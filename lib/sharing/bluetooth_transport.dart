import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:universal_ble/universal_ble.dart';
import 'package:flutter/services.dart';

import 'quick_transfer.dart';
import 'radio_rpc.dart';
import 'linux_ble_peripheral.dart';

class BluetoothTransport {
  BluetoothTransport({
    required this.id,
    required this.name,
    required this.handle,
    required this.canReceive,
  });
  final String id, name;
  final QuickRpc handle;
  final bool Function() canReceive;
  final destinations = <String, QuickDestination>{};
  void Function()? onChanged;
  void Function(String message)? onError;
  final _central = <String, RadioRpc>{};
  final _peripheral = <String, RadioRpc>{};
  final _connecting = <String>{};
  final _mtus = <String, int>{};
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  LinuxBlePeripheral? _linux;
  bool running = false,
      _targeted = false,
      _advertising = false,
      _hasPeripheral = false;

  Map<String, dynamic> get _identity => {
    'v': quickVersion,
    'id': id,
    'name': name,
    'os': Platform.operatingSystem,
    'receiving': canReceive(),
  };
  Future<Map<String, dynamic>> _incoming(
    RadioRpc link,
    String path,
    Map<String, dynamic> body,
  ) async {
    if (path == '/transport/hello') {
      _register(link, body);
      return _identity;
    }
    return handle(path, body);
  }

  void _register(RadioRpc link, Map<String, dynamic> info) {
    final remoteId = info['id'], remoteName = info['name'];
    if (info['receiving'] == false) {
      if (remoteId is String) destinations.remove(remoteId);
      return;
    }
    if (remoteId is! String ||
        remoteId == id ||
        remoteId.length > 100 ||
        remoteName is! String ||
        remoteName.isEmpty ||
        remoteName.length > 100 ||
        info['v'] != quickVersion) {
      return;
    }
    destinations[remoteId] = QuickDestination(
      id: remoteId,
      name: remoteName,
      transport: 'Bluetooth',
      rpc: link.request,
      chunkSize: 4096,
    );
    onChanged?.call();
  }

  Future<void> start() async {
    if (running) return resumeDiscovery();
    await UniversalBle.requestPermissions();
    if (Platform.isAndroid) {
      final granted = await const MethodChannel('lanlink/bluetooth-permission')
          .invokeMethod<bool>('advertise');
      if (granted != true) {
        throw StateError('Hace falta permiso para recibir por Bluetooth.');
      }
    }
    final state = await UniversalBle.getBluetoothAvailabilityState();
    if (state != AvailabilityState.poweredOn) {
      throw StateError(
        'Activá Bluetooth y permití el acceso para compartir cerca.',
      );
    }
    running = true;
    UniversalBle.onScanResult = (device) {
      if (running &&
          _central.length + _connecting.length < 4 &&
          !_central.containsKey(device.deviceId) &&
          !_connecting.contains(device.deviceId)) {
        unawaited(_connect(device.deviceId));
      }
    };
    UniversalBle.onValueChange = (value) {
      if (value.characteristicId.toLowerCase() == quickBleTx) {
        _central[value.deviceId]?.receive(value.value);
      }
    };
    UniversalBle.onConnectionChange = (change) {
      if (!change.isConnected) {
        _central.remove(change.deviceId)?.close();
        destinations.clear();
        onChanged?.call();
      }
    };
    if (Platform.isLinux) {
      final linux = LinuxBlePeripheral();
      _linux = linux;
      linux.onPacket = (device, packet) {
        if (!_peripheral.containsKey(device) && _peripheral.length >= 4) return;
        final link = _peripheral.putIfAbsent(device, () {
          late RadioRpc result;
          result = RadioRpc(
            tag: RadioRpc.packetTag(packet),
            write: linux.notify,
            handle: (path, body) => _incoming(result, path, body),
          );
          return result;
        });
        link.receive(packet);
      };
      try {
        await linux.start();
      } catch (_) {
        onError?.call(
          'Este adaptador permite buscar, pero no anunciar recepción Bluetooth.',
        );
      }
    } else {
      final capabilities = await UniversalBlePeripheral.getCapabilities();
      if (capabilities.supportsPeripheralMode) {
        _targeted = capabilities.supportsTargetedCharacteristicUpdate;
        _subscriptions.add(
          UniversalBlePeripheral.mtuChangedStream.listen((event) {
            _mtus[event.deviceId] = max(20, min(512, event.mtu - 3));
            _peripheral[event.deviceId]?.payloadLength = _mtus[event.deviceId]!;
          }),
        );
        _subscriptions.add(
          UniversalBlePeripheral.connectionStateStream.listen((event) {
            if (!event.connected) _peripheral.remove(event.deviceId)?.close();
          }),
        );
        UniversalBlePeripheral.setWriteRequestHandlers((
          device,
          characteristic,
          offset,
          value,
        ) {
          if (!running ||
              characteristic.toLowerCase() != quickBleRx ||
              value == null ||
              value.length < 8 ||
              offset != 0) {
            return PeripheralWriteRequestResult(status: 6);
          }
          if (!_peripheral.containsKey(device) && _peripheral.length >= 4) {
            return PeripheralWriteRequestResult(status: 17);
          }
          final link = _peripheral.putIfAbsent(device, () {
            late RadioRpc result;
            result = RadioRpc(
              tag: RadioRpc.packetTag(value),
              write: (packet) =>
                  UniversalBlePeripheral.updateCharacteristicValue(
                    characteristicId: quickBleTx,
                    value: packet,
                    deviceId: _targeted ? device : null,
                  ),
              handle: (path, body) => _incoming(result, path, body),
            );
            result.payloadLength = _mtus[device] ?? 20;
            return result;
          });
          link.receive(value);
          return PeripheralWriteRequestResult(status: 0);
        });
        await UniversalBlePeripheral.addService(
          BlePeripheralService(
            uuid: quickBleService,
            characteristics: [
              BlePeripheralCharacteristic(
                uuid: quickBleRx,
                properties: [CharacteristicProperty.write],
                permissions: [PeripheralAttributePermission.writeable],
              ),
              BlePeripheralCharacteristic(
                uuid: quickBleTx,
                properties: [CharacteristicProperty.indicate],
                permissions: [PeripheralAttributePermission.readable],
              ),
            ],
          ),
        );
        _hasPeripheral = true;
        await UniversalBlePeripheral.startAdvertising(
          services: [quickBleService],
          localName: null,
        );
        _advertising = true;
      }
    }
    await UniversalBle.startScan(
      scanFilter: ScanFilter(withServices: [quickBleService]),
      skipDuplicates: true,
    );
  }

  Future<void> _connect(String device) async {
    _connecting.add(device);
    try {
      await UniversalBle.connect(device);
      var payload = 20;
      try {
        payload = max(
          20,
          min(512, await UniversalBle.requestMtu(device, 512) - 3),
        );
      } catch (_) {}
      await UniversalBle.discoverServices(device);
      late RadioRpc link;
      link = RadioRpc(
        tag: Random.secure().nextInt(0x7ffffffe) + 1,
        write: (value) =>
            UniversalBle.write(device, quickBleService, quickBleRx, value),
        handle: (path, body) => _incoming(link, path, body),
      );
      link.payloadLength = payload;
      _central[device] = link;
      await UniversalBle.subscribeIndications(
        device,
        quickBleService,
        quickBleTx,
      );
      final info = await link.request('/transport/hello', _identity);
      _register(link, info);
    } catch (_) {
      _central.remove(device)?.close();
      try {
        await UniversalBle.disconnect(device);
      } catch (_) {}
    } finally {
      _connecting.remove(device);
    }
  }

  Future<void> pauseDiscovery() async {
    await UniversalBle.stopScan();
    if (_linux != null) await _linux!.setAdvertising(false);
    if (_advertising) {
      await UniversalBlePeripheral.stopAdvertising();
      _advertising = false;
    }
  }

  Future<void> resumeDiscovery() async {
    if (_linux != null) await _linux!.setAdvertising(true);
    if (_hasPeripheral && !_advertising) {
      await UniversalBlePeripheral.startAdvertising(
        services: [quickBleService],
      );
      _advertising = true;
    }
    await UniversalBle.startScan(
      scanFilter: ScanFilter(withServices: [quickBleService]),
      skipDuplicates: true,
    );
  }

  Future<void> stop() async {
    running = false;
    await _linux?.stop();
    _linux = null;
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
    if (_hasPeripheral) {
      try {
        if (_advertising) await UniversalBlePeripheral.stopAdvertising();
        await UniversalBlePeripheral.removeService(quickBleService);
      } catch (_) {}
    }
    _advertising = false;
    _hasPeripheral = false;
    for (final device in _central.keys.toList()) {
      _central.remove(device)?.close();
      try {
        await UniversalBle.disconnect(device);
      } catch (_) {}
    }
    for (final link in _peripheral.values) {
      link.close();
    }
    _peripheral.clear();
    destinations.clear();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    UniversalBle.onScanResult = null;
    UniversalBle.onValueChange = null;
    UniversalBle.onConnectionChange = null;
    onChanged?.call();
  }
}
