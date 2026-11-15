import Foundation
import Network

struct DirectPeer {
  let token: String
  let id: String
  let name: String
  let transport: String
  let endpoint: NWEndpoint
  let direct: Bool
}

final class DirectPeerEngine {
  static let service = "_lanlink-direct._tcp"
  let queue = DispatchQueue(label: "lanlink.direct.network")
  var onPeers: (([DirectPeer]) -> Void)?
  var onError: ((String) -> Void)?
  var handle: ((String, [String: Any], @escaping (Result<[String: Any], Error>) -> Void) -> Void)?
  private var listener: NWListener?
  private var browsers: [NWBrowser] = []
  private var peers: [String: DirectPeer] = [:]
  private var wires: [String: DirectWire] = [:]
  private var identity = ""

  func start(id: String, name: String, advertise: Bool = true) throws {
    try queue.sync { try startOnQueue(id: id, name: name, advertise: advertise) }
  }
  private func startOnQueue(id: String, name: String, advertise: Bool) throws {
    if identity == id { pauseOnQueue() } else { stopOnQueue() }
    identity = id
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    if advertise {
      let listener = try NWListener(using: parameters)
      let txt = NetService.data(fromTXTRecord: ["id": Data(id.utf8), "name": Data(name.utf8), "quick": Data("1".utf8)])
      listener.service = NWListener.Service(name: "LanLink-\(id.prefix(12))", type: Self.service, txtRecord: txt)
      listener.newConnectionHandler = { [weak self] connection in
        guard let self, self.wires.count < 4 else { connection.cancel(); return }
        let token = UUID().uuidString
        let wire = self.makeWire(connection, token: token)
        self.wires[token] = wire
        wire.start()
      }
      listener.stateUpdateHandler = { [weak self] state in
        if case .failed = state { self?.onError?("No se pudo activar Wi-Fi directa. Revisá los permisos de red local.") }
      }
      self.listener = listener
      listener.start(queue: queue)
    }
    for type in [Self.service, "_lanlink._tcp", "_lanlink-quick._tcp"] {
      let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: parameters)
      browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
        guard let self, let browser, self.browsers.contains(where: { $0 === browser }) else { return }
        self.peers = self.peers.filter { !$0.key.hasPrefix(type + ":") }
        for result in results {
          guard case .bonjour(let record) = result.metadata else { continue }
          let fields = record.dictionary
          guard let otherId = fields["id"], otherId != self.identity, let name = fields["name"], !name.isEmpty, name.count <= 100 else { continue }
          if type != Self.service && fields["quick"] != "1" { continue }
          let token = type + ":" + otherId
          self.peers[token] = DirectPeer(token: token, id: otherId, name: name, transport: type == Self.service ? "Wi-Fi directa" : "Red local", endpoint: result.endpoint, direct: type == Self.service)
        }
        self.onPeers?(Array(self.peers.values))
      }
      browser.stateUpdateHandler = { [weak self] state in
        if case .failed = state { self?.onError?("No se pudieron buscar equipos. Permití el acceso a la red local.") }
      }
      browser.start(queue: queue)
      browsers.append(browser)
    }
  }

  private func makeWire(_ connection: NWConnection, token: String) -> DirectWire {
    let wire = DirectWire(connection: connection, queue: queue)
    wire.handle = { [weak self] path, body, reply in
      guard let handler = self?.handle else { reply(.failure(DirectError.unavailable)); return }
      handler(path, body, reply)
    }
    wire.onClose = { [weak self] in self?.wires.removeValue(forKey: token) }
    return wire
  }

  func request(_ token: String, path: String, body: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
    queue.async { [weak self] in
      guard let self, let peer = self.peers[token] else { completion(.failure(DirectError.unavailable)); return }
      if peer.direct {
        let wire: DirectWire
        if let existing = self.wires[token] { wire = existing }
        else {
          let parameters = NWParameters.tcp
          parameters.includePeerToPeer = true
          wire = self.makeWire(NWConnection(to: peer.endpoint, using: parameters), token: token)
          self.wires[token] = wire
          wire.start()
        }
        wire.request(path, body: body, completion: completion)
      } else {
        DirectHTTP.request(peer.endpoint, path: path, body: body, queue: self.queue, completion: completion)
      }
    }
  }

  func pauseDiscovery() { queue.async { [weak self] in self?.pauseOnQueue() } }
  private func pauseOnQueue() {
    listener?.cancel(); listener = nil
    for browser in browsers { browser.cancel() }; browsers.removeAll()
    peers.removeAll(); onPeers?([])
  }
  func stop() { queue.async { [weak self] in self?.stopOnQueue() } }
  private func stopOnQueue() {
    pauseOnQueue()
    let old = Array(wires.values); wires.removeAll()
    for wire in old { wire.close() }; peers.removeAll()
  }

}

enum DirectError: LocalizedError {
  case unavailable, invalid, rejected, timeout
  var errorDescription: String? {
    switch self {
    case .unavailable: return "El equipo ya no está disponible. Volvé a buscarlo."
    case .invalid: return "El otro equipo envió una respuesta inválida."
    case .rejected: return "El otro equipo no aceptó la operación."
    case .timeout: return "El otro equipo no respondió a tiempo."
    }
  }
}

private final class DirectWire {
  let connection: NWConnection
  let queue: DispatchQueue
  var handle: ((String, [String: Any], @escaping (Result<[String: Any], Error>) -> Void) -> Void)?
  var onClose: (() -> Void)?
  private var buffer = Data()
  private var pending: [String: (Result<[String: Any], Error>) -> Void] = [:]
  private var closed = false
  private var lastActivity = Date()
  init(connection: NWConnection, queue: DispatchQueue) { self.connection = connection; self.queue = queue }
  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      if case .ready = state { self?.read() }
      if case .failed = state { self?.close() }
      if case .cancelled = state { self?.close() }
    }
    connection.start(queue: queue)
    checkIdle()
  }
  private func checkIdle() {
    queue.asyncAfter(deadline: .now() + 15) { [weak self] in
      guard let self, !self.closed else { return }
      if Date().timeIntervalSince(self.lastActivity) > 180 { self.close() } else { self.checkIdle() }
    }
  }
  func request(_ path: String, body: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
    guard !closed, pending.count < 4 else { completion(.failure(DirectError.unavailable)); return }
    lastActivity = Date()
    let id = UUID().uuidString
    pending[id] = completion
    send(["id": id, "path": path, "body": body])
    queue.asyncAfter(deadline: .now() + (path == "/quick/offer" ? 180 : 45)) { [weak self] in
      self?.pending.removeValue(forKey: id)?(.failure(DirectError.timeout))
    }
  }
  private func send(_ object: [String: Any]) {
    guard !closed, let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 1_048_576 else { close(); return }
    var length = UInt32(data.count).bigEndian
    var frame = Data(bytes: &length, count: 4); frame.append(data)
    connection.send(content: frame, completion: .contentProcessed { [weak self] error in if error != nil { self?.close() } })
  }
  private func read() {
    guard !closed else { return }
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
      guard let self else { return }
      if let data { self.lastActivity = Date(); self.buffer.append(data) }
      if self.buffer.count > 1_048_580 { self.close(); return }
      while self.buffer.count >= 4 {
        let size = self.buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        if size < 2 || size > 1_048_576 { self.close(); return }
        if self.buffer.count < size + 4 { break }
        let payload = self.buffer.subdata(in: 4..<(4 + size)); self.buffer.removeFirst(size + 4)
        self.message(payload)
      }
      if done || error != nil { self.close() } else { self.read() }
    }
  }
  private func message(_ data: Data) {
    guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = value["id"] as? String, id.count <= 64 else { close(); return }
    if value["response"] as? Bool == true {
      if let callback = pending.removeValue(forKey: id) {
        if value["ok"] as? Bool == true, let body = value["body"] as? [String: Any] { callback(.success(body)) }
        else { callback(.failure(DirectError.rejected)) }
      }
    } else if let path = value["path"] as? String, let body = value["body"] as? [String: Any], let handler = handle {
      handler(path, body) { [weak self] result in
        self?.queue.async {
          switch result {
          case .success(let response): self?.send(["id": id, "response": true, "ok": true, "body": response])
          case .failure: self?.send(["id": id, "response": true, "ok": false])
          }
        }
      }
    }
  }
  func close() {
    if closed { return }; closed = true; connection.cancel(); buffer.removeAll()
    let callbacks = Array(pending.values); pending.removeAll()
    for callback in callbacks { callback(.failure(DirectError.unavailable)) }
    onClose?()
  }
}

private enum DirectHTTP {
  static func request(_ endpoint: NWEndpoint, path: String, body: [String: Any], queue: DispatchQueue, completion: @escaping (Result<[String: Any], Error>) -> Void) {
    guard path.hasPrefix("/quick/"), !path.contains("\r"), !path.contains("\n"), let data = try? JSONSerialization.data(withJSONObject: body) else { completion(.failure(DirectError.invalid)); return }
    let parameters = NWParameters.tcp; parameters.includePeerToPeer = true
    let connection = NWConnection(to: endpoint, using: parameters)
    let header = "POST \(path) HTTP/1.1\r\nHost: lanlink.local\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
    var request = Data(header.utf8); request.append(data)
    var response = Data(), finished = false
    func finish(_ result: Result<[String: Any], Error>) { if finished { return }; finished = true; connection.cancel(); completion(result) }
    func read() {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { bytes, _, done, error in
        if finished { return }
        if let bytes { response.append(bytes) }
        if response.count > 1_064_960 { finish(.failure(DirectError.invalid)); return }
        if done {
          guard let boundary = response.range(of: Data("\r\n\r\n".utf8)), let header = String(data: response[..<boundary.lowerBound], encoding: .utf8), header.hasPrefix("HTTP/1.1 200") || header.hasPrefix("HTTP/1.0 200"), let object = try? JSONSerialization.jsonObject(with: response[boundary.upperBound...]) as? [String: Any] else { finish(.failure(DirectError.rejected)); return }
          finish(.success(object))
        } else if error != nil { finish(.failure(DirectError.unavailable)) }
        else { read() }
      }
    }
    connection.stateUpdateHandler = { state in
      if case .ready = state {
        connection.send(content: request, completion: .contentProcessed { error in
          if let error { finish(.failure(error)) } else { read() }
        })
      }
      if case .failed = state { finish(.failure(DirectError.unavailable)) }
    }
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + (path == "/quick/offer" ? 180 : 45)) { finish(.failure(DirectError.timeout)) }
  }
}
