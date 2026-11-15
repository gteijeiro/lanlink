import Foundation
import CoreBluetooth

struct NativeNearbyDestination {
  let id: String
  let name: String
  let transport: String
  let chunkSize: Int
  let rpc: QuickNativeSender.RPC
}

final class NativeBluetoothClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  static let service = CBUUID(string: "d34f0001-8937-4f59-8b32-65d72c5b81ad")
  static let rx = CBUUID(string: "d34f0002-8937-4f59-8b32-65d72c5b81ad")
  static let tx = CBUUID(string: "d34f0003-8937-4f59-8b32-65d72c5b81ad")
  let queue = DispatchQueue(label: "lanlink.share.bluetooth")
  var onPeers: (([NativeNearbyDestination]) -> Void)?
  var onError: ((String) -> Void)?
  private var manager: CBCentralManager?
  private var peripherals: [UUID: CBPeripheral] = [:]
  private var characteristics: [UUID: CBCharacteristic] = [:]
  private var wires: [UUID: NativeRadioWire] = [:]
  private var destinations: [UUID: NativeNearbyDestination] = [:]
  private let identity = UUID().uuidString
  private var running = false
  func start() { queue.async { self.running = true; self.manager = CBCentralManager(delegate: self, queue: self.queue) } }
  func stop() { queue.async {
    self.running = false; self.manager?.stopScan()
    for peripheral in self.peripherals.values { self.manager?.cancelPeripheralConnection(peripheral) }
    for wire in self.wires.values { wire.close() }
    self.wires.removeAll(); self.peripherals.removeAll(); self.destinations.removeAll(); self.characteristics.removeAll(); self.manager = nil
  } }
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state == .poweredOn, running { central.scanForPeripherals(withServices: [Self.service]) }
    else { onError?("Para buscar sin red, activá Bluetooth y permití el acceso.") }
  }
  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
    guard running, peripherals.count < 4, peripherals[peripheral.identifier] == nil else { return }
    peripherals[peripheral.identifier] = peripheral; peripheral.delegate = self
    central.connect(peripheral)
  }
  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { peripheral.discoverServices([Self.service]) }
  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { remove(peripheral) }
  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { remove(peripheral) }
  private func remove(_ peripheral: CBPeripheral) {
    wires.removeValue(forKey: peripheral.identifier)?.close(); peripherals.removeValue(forKey: peripheral.identifier)
    destinations.removeValue(forKey: peripheral.identifier); characteristics.removeValue(forKey: peripheral.identifier)
    onPeers?(Array(destinations.values))
  }
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else { manager?.cancelPeripheralConnection(peripheral); return }
    peripheral.discoverCharacteristics([Self.rx, Self.tx], for: service)
  }
  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard error == nil, let rx = service.characteristics?.first(where: { $0.uuid == Self.rx }), let tx = service.characteristics?.first(where: { $0.uuid == Self.tx }) else { manager?.cancelPeripheralConnection(peripheral); return }
    characteristics[peripheral.identifier] = rx
    let wire = NativeRadioWire(queue: queue, payloadLength: min(512, max(20, peripheral.maximumWriteValueLength(for: .withoutResponse)))) { [weak peripheral] bytes in peripheral?.writeValue(bytes, for: rx, type: .withResponse) }
    wires[peripheral.identifier] = wire
    peripheral.setNotifyValue(true, for: tx)
  }
  func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
    guard error == nil, characteristic.uuid == Self.tx, characteristic.isNotifying, let wire = wires[peripheral.identifier] else { return }
    wire.request("/transport/hello", body: ["id": identity, "name": "LanLink", "v": 1, "receiving": false]) { [weak self] result in
      guard let self, self.running, case .success(let info) = result, let id = info["id"] as? String, let name = info["name"] as? String, !name.isEmpty, name.count <= 100 else { return }
      self.destinations[peripheral.identifier] = NativeNearbyDestination(id: id, name: name, transport: "Bluetooth", chunkSize: 4096, rpc: { path, body in
        try await withCheckedThrowingContinuation { continuation in self.queue.async { wire.request(path, body: body) { continuation.resume(with: $0) } } }
      })
      self.onPeers?(Array(self.destinations.values))
    }
  }
  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    if error == nil, characteristic.uuid == Self.tx, let bytes = characteristic.value { wires[peripheral.identifier]?.receive(bytes) }
  }
  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) { if error != nil { wires[peripheral.identifier]?.close() } }
}

// Mutable state is confined to the CoreBluetooth serial queue.
private final class NativeRadioWire: @unchecked Sendable {
  let queue: DispatchQueue, payloadLength: Int
  let write: (Data) -> Void
  private let tag = UInt32.random(in: 1...0x7ffffffe)
  private var tx: UInt16 = 0, rx: UInt16 = 0
  private var frames: [(Data, Int)] = []
  private var current: Data?, timer: DispatchWorkItem?
  private var attempts = 0, closed = false, receiving = false
  private var buffer = Data()
  private var pending: [String: (Result<[String: Any], Error>) -> Void] = [:]
  init(queue: DispatchQueue, payloadLength: Int, write: @escaping (Data) -> Void) { self.queue = queue; self.payloadLength = payloadLength; self.write = write }
  private func header(_ kind: UInt8, _ sequence: UInt16, _ flags: UInt8) -> Data {
    Data([kind, UInt8(sequence >> 8), UInt8(sequence & 255), flags, UInt8(tag >> 24), UInt8((tag >> 16) & 255), UInt8((tag >> 8) & 255), UInt8(tag & 255)])
  }
  func request(_ path: String, body: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
    guard !closed, pending.count < 4 else { completion(.failure(DirectError.unavailable)); return }
    let id = UUID().uuidString; pending[id] = completion
    send(["id": id, "path": path, "body": body])
    queue.asyncAfter(deadline: .now() + (path == "/quick/offer" ? 180 : 45)) { [weak self] in self?.pending.removeValue(forKey: id)?(.failure(DirectError.timeout)) }
  }
  private func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 1_048_576, frames.count < 8 else { close(); return }
    frames.append((data, 0)); if current == nil { next() }
  }
  private func next() {
    guard !closed, let (bytes, offset) = frames.first else { return }
    let end = min(offset + max(1, payloadLength - 8), bytes.count)
    var packet = header(1, tx, (offset == 0 ? 1 : 0) | (end == bytes.count ? 2 : 0)); packet.append(bytes[offset..<end])
    current = packet; attempts = 0; transmit()
  }
  private func transmit() {
    guard let current, !closed else { return }
    attempts += 1; write(current)
    let task = DispatchWorkItem { [weak self] in guard let self else { return }; if self.attempts >= 3 { self.close() } else { self.transmit() } }
    timer = task; queue.asyncAfter(deadline: .now() + 3, execute: task)
  }
  func receive(_ packet: Data) {
    guard !closed, packet.count >= 8 else { return }
    let bytes = [UInt8](packet)
    let otherTag = bytes[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard otherTag == tag else { return }
    let sequence = (UInt16(bytes[1]) << 8) | UInt16(bytes[2])
    if bytes[0] == 2 {
      guard sequence == tx, let (_, offset) = frames.first, let current else { return }
      timer?.cancel(); timer = nil
      let nextOffset = offset + current.count - 8
      if nextOffset == frames[0].0.count { frames.removeFirst() } else { frames[0].1 = nextOffset }
      self.current = nil; tx &+= 1; next(); return
    }
    guard bytes[0] == 1 else { return }
    if sequence == rx &- 1 { write(header(2, sequence, 0)); return }
    guard sequence == rx else { return }
    if bytes[3] & 1 != 0 { buffer.removeAll(); receiving = true }
    guard receiving, buffer.count + bytes.count - 8 <= 1_048_576 else { close(); return }
    buffer.append(contentsOf: bytes.dropFirst(8)); rx &+= 1
    write(header(2, sequence, 0))
    if bytes[3] & 2 != 0 { receiving = false; let message = buffer; buffer.removeAll(); dispatch(message) }
  }
  private func dispatch(_ data: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = object["id"] as? String else { close(); return }
    if object["response"] as? Bool == true {
      guard let reply = pending.removeValue(forKey: id) else { return }
      if object["ok"] as? Bool == true, let body = object["body"] as? [String: Any] { reply(.success(body)) } else { reply(.failure(DirectError.rejected)) }
    } else { send(["id": id, "response": true, "ok": false]) }
  }
  func close() {
    if closed { return }; closed = true; timer?.cancel(); timer = nil; frames.removeAll(); buffer.removeAll()
    let callbacks = Array(pending.values); pending.removeAll()
    for callback in callbacks { callback(.failure(DirectError.unavailable)) }
  }
}
