import 'dart:typed_data';

import 'package:dbus/dbus.dart';

import 'radio_rpc.dart';

class _BluezObject extends DBusObject {
  _BluezObject(String path, this.interface, this.properties, {this.onCall})
    : super(DBusObjectPath(path));
  final String interface;
  final Map<String, DBusValue> properties;
  final Future<DBusMethodResponse> Function(DBusMethodCall)? onCall;
  @override
  Map<String, Map<String, DBusValue>> get interfacesAndProperties => {
    interface: properties,
  };
  @override
  Future<DBusMethodResponse> getAllProperties(String target) async =>
      target == interface
      ? DBusGetAllPropertiesResponse(properties)
      : DBusMethodErrorResponse.unknownInterface();
  @override
  Future<DBusMethodResponse> getProperty(String target, String name) async =>
      target == interface && properties.containsKey(name)
      ? DBusGetPropertyResponse(properties[name]!)
      : DBusMethodErrorResponse.unknownProperty();
  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async =>
      call.interface == interface && onCall != null
      ? onCall!(call)
      : DBusMethodErrorResponse.unknownMethod();
}

/// BlueZ exposes GATT servers over D-Bus; this fills the Linux peripheral gap
/// in universal_ble. No adapter pairing or system-wide power change is needed.
class LinuxBlePeripheral {
  final client = DBusClient.system();
  void Function(String device, Uint8List bytes)? onPacket;
  _BluezObject? _tx;
  bool _registered = false, _advertising = false;
  DBusRemoteObject? _remote;
  static const root = '/com/lanlink/quick';

  Future<void> start() async {
    final manager = DBusRemoteObjectManager(
      client,
      name: 'org.bluez',
      path: DBusObjectPath('/'),
    );
    final objects = await manager.getManagedObjects();
    final adapter = objects.entries.where(
      (entry) =>
          entry.value.containsKey('org.bluez.GattManager1') &&
          entry.value.containsKey('org.bluez.LEAdvertisingManager1'),
    );
    if (adapter.isEmpty) {
      throw StateError('El adaptador no permite recibir por Bluetooth.');
    }
    final path = adapter.first.key;
    await client.registerObject(
      DBusObject(DBusObjectPath(root), isObjectManager: true),
    );
    final service = _BluezObject('$root/service0', 'org.bluez.GattService1', {
      'UUID': const DBusString(quickBleService),
      'Primary': const DBusBoolean(true),
      'Includes': DBusArray(DBusSignature('o'), []),
    });
    final rx = _BluezObject(
      '$root/service0/rx',
      'org.bluez.GattCharacteristic1',
      {
        'UUID': const DBusString(quickBleRx),
        'Service': DBusObjectPath(service.path.value),
        'Flags': DBusArray.string(['write']),
      },
      onCall: (call) async {
        if (call.name != 'WriteValue' || call.values.length != 2) {
          return DBusMethodErrorResponse.unknownMethod();
        }
        final options = call.values[1].toNative() as Map;
        final device = options['device'];
        final bytes = call.values[0].toNative();
        if (device is! String ||
            (options['offset'] ?? 0) != 0 ||
            bytes is! List ||
            bytes.length < 8 ||
            bytes.length > 512) {
          return DBusMethodErrorResponse('org.bluez.Error.InvalidArguments');
        }
        onPacket?.call(device, Uint8List.fromList(bytes.cast<int>()));
        return DBusMethodSuccessResponse();
      },
    );
    late _BluezObject tx;
    tx = _BluezObject(
      '$root/service0/tx',
      'org.bluez.GattCharacteristic1',
      {
        'UUID': const DBusString(quickBleTx),
        'Service': DBusObjectPath(service.path.value),
        'Flags': DBusArray.string(['indicate']),
        'Value': DBusArray.byte([]),
        'Notifying': const DBusBoolean(false),
      },
      onCall: (call) async {
        if (call.name == 'StartNotify' || call.name == 'StopNotify') {
          tx.properties['Notifying'] = DBusBoolean(call.name == 'StartNotify');
          await tx.emitPropertiesChanged(
            tx.interface,
            changedProperties: {'Notifying': tx.properties['Notifying']!},
          );
          return DBusMethodSuccessResponse();
        }
        if (call.name == 'Confirm') return DBusMethodSuccessResponse();
        return DBusMethodErrorResponse.unknownMethod();
      },
    );
    _tx = tx;
    final advertisement = _BluezObject(
      '$root/advertisement',
      'org.bluez.LEAdvertisement1',
      {
        'Type': const DBusString('peripheral'),
        'ServiceUUIDs': DBusArray.string([quickBleService]),
        'LocalName': const DBusString('LanLink'),
      },
      onCall: (_) async => DBusMethodSuccessResponse(),
    );
    for (final object in [service, rx, tx, advertisement]) {
      await client.registerObject(object);
    }
    final remote = DBusRemoteObject(client, name: 'org.bluez', path: path);
    _remote = remote;
    await remote.callMethod('org.bluez.GattManager1', 'RegisterApplication', [
      DBusObjectPath(root),
      DBusDict.stringVariant({}),
    ], replySignature: DBusSignature(''));
    await setAdvertising(true);
    _registered = true;
  }

  Future<void> setAdvertising(bool value) async {
    if (_remote == null || _advertising == value) return;
    await _remote!.callMethod(
      'org.bluez.LEAdvertisingManager1',
      value ? 'RegisterAdvertisement' : 'UnregisterAdvertisement',
      [
        DBusObjectPath('$root/advertisement'),
        if (value) DBusDict.stringVariant({}),
      ],
      replySignature: DBusSignature(''),
    );
    _advertising = value;
  }

  Future<void> notify(Uint8List packet) async {
    final tx = _tx;
    if (!_registered ||
        tx == null ||
        tx.properties['Notifying']?.toNative() != true) {
      throw StateError('Bluetooth no está suscrito.');
    }
    tx.properties['Value'] = DBusArray.byte(packet);
    await tx.emitPropertiesChanged(
      tx.interface,
      changedProperties: {'Value': tx.properties['Value']!},
    );
  }

  Future<void> stop() async {
    _registered = false;
    _tx = null;
    await client.close();
  }
}
