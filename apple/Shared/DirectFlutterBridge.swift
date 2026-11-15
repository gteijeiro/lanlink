import Foundation
#if os(macOS)
import FlutterMacOS
#else
import Flutter
#endif

final class DirectFlutterBridge {
  private let engine = DirectPeerEngine()
  private let channel: FlutterMethodChannel
  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "lanlink/direct", binaryMessenger: messenger)
    engine.onPeers = { [weak self] peers in DispatchQueue.main.async {
      self?.channel.invokeMethod("peers", arguments: peers.map { ["id": $0.id, "token": $0.token, "name": $0.name, "transport": $0.transport] })
    } }
    engine.onError = { [weak self] message in DispatchQueue.main.async { self?.channel.invokeMethod("error", arguments: message) } }
    engine.handle = { [weak self] path, body, completion in DispatchQueue.main.async {
      guard let self else { completion(.failure(DirectError.unavailable)); return }
      self.channel.invokeMethod("request", arguments: ["path": path, "body": body]) { result in
        if let value = result as? [String: Any] { completion(.success(value)) }
        else { completion(.failure(DirectError.rejected)) }
      }
    } }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterError(code: "closed", message: "La conexión se cerró.", details: nil)); return }
      let args = call.arguments as? [String: Any] ?? [:]
      if call.method == "start" {
        do { try self.engine.start(id: args["id"] as? String ?? UUID().uuidString, name: args["name"] as? String ?? "LanLink", advertise: args["advertise"] as? Bool ?? false); result(nil) }
        catch { result(FlutterError(code: "direct", message: error.localizedDescription, details: nil)) }
      } else if call.method == "pauseDiscovery" { self.engine.pauseDiscovery(); result(nil) }
      else if call.method == "stop" { self.engine.stop(); result(nil) }
      else if call.method == "request", let target = args["destination"] as? String, let path = args["path"] as? String, let body = args["body"] as? [String: Any] {
        self.engine.request(target, path: path, body: body) { value in DispatchQueue.main.async {
          switch value { case .success(let reply): result(reply); case .failure(let error): result(FlutterError(code: "direct", message: error.localizedDescription, details: nil)) }
        } }
      } else { result(FlutterMethodNotImplemented) }
    }
  }
}
