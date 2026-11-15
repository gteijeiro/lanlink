import Foundation
import Cocoa
import FlutterMacOS

final class IncomingShareBridge {
  private let channel: FlutterMethodChannel
  private var ready = false
  private var pending: [[String: Any]] = []
  private let queue = DispatchQueue(label: "lanlink.incoming.files")
  private let root = FileManager.default.temporaryDirectory.appendingPathComponent("LanLinkIncoming", isDirectory: true)
  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "lanlink/incoming", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      if call.method == "drain" { self.ready = true; let data = self.pending; self.pending.removeAll(); result(data) }
      else if call.method == "release", let token = call.arguments as? String, UUID(uuidString: token) != nil {
        self.queue.async { try? FileManager.default.removeItem(at: self.root.appendingPathComponent(token)) }; result(nil)
      } else { result(FlutterMethodNotImplemented) }
    }
  }
  func accept(_ paths: [String]) {
    queue.async {
      let token = UUID().uuidString
      let directory = self.root.appendingPathComponent(token, isDirectory: true)
      do {
        guard !paths.isEmpty, paths.count <= 100 else { throw DirectError.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var total: Int64 = 0
        let files = try paths.enumerated().map { index, path -> [String: String] in
          let source = URL(fileURLWithPath: path)
          let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
          let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
          guard attributes[.type] as? FileAttributeType == .typeRegular else { throw DirectError.invalid }
          total += (attributes[.size] as? NSNumber)?.int64Value ?? 0
          guard total <= 17_179_869_184 else { throw DirectError.invalid }
          let parent = directory.appendingPathComponent(String(index), isDirectory: true)
          try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
          let target = parent.appendingPathComponent(source.lastPathComponent)
          try FileManager.default.copyItem(at: source, to: target)
          return ["path": target.path, "name": target.lastPathComponent]
        }
        DispatchQueue.main.async {
          let batch: [String: Any] = ["token": token, "files": files]
          if self.ready { self.channel.invokeMethod("files", arguments: [batch]) } else { self.pending.append(batch) }
        }
      } catch {
        try? FileManager.default.removeItem(at: directory)
        DispatchQueue.main.async {
          let message = "No se pudieron preparar los archivos compartidos: \(error.localizedDescription)"
          if self.ready { self.channel.invokeMethod("error", arguments: message) } else { self.pending.append(["error": message]) }
        }
      }
    }
  }
}
