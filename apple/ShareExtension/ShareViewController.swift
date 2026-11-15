import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#else
import Cocoa
#endif

@MainActor final class ShareModel: ObservableObject {
  @Published var files: [NativeSharedFile] = []
  @Published var peers: [NativeNearbyDestination] = []
  @Published var status = "Preparando archivos…"
  @Published var code: String?
  @Published var error: String?
  @Published var sending = false
  @Published var canConfirm = false
  @Published var finished = false
  private let wifi = DirectPeerEngine()
  private let bluetooth = NativeBluetoothClient()
  private var wifiPeers: [NativeNearbyDestination] = [], bluetoothPeers: [NativeNearbyDestination] = []
  private var sender: QuickNativeSender?
  private var confirmation: CheckedContinuation<Bool, Never>?
  private var confirmationTimeout: Task<Void, Never>?
  private var root: URL?
  private var started = false
  private var closed = false
  var completion: (() -> Void)?

  func start(_ context: NSExtensionContext) {
    guard !started else { return }; started = true
    Task { [self] in
      do {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LanLinkShare-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var urls: [URL] = []
        let providers = (context.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty, providers.count <= 100 else { throw DirectError.invalid }
        for (index, provider) in providers.enumerated() {
          let type = provider.registeredTypeIdentifiers.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) ?? "public.data"
          let destination = root.appendingPathComponent(String(index), isDirectory: true)
          try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
          let url: URL = try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { source, failure in
              do {
                if let failure { throw failure }
                guard let source, source.isFileURL else { throw DirectError.invalid }
                let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = (attributes[.size] as? NSNumber)?.int64Value, size <= 17_179_869_184 else { throw DirectError.invalid }
                let capacity = try destination.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
                guard Int64(capacity) > size + 64 * 1024 * 1024 else { throw DirectError.unavailable }
                let target = destination.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: target)
                continuation.resume(returning: target)
              } catch { continuation.resume(throwing: error) }
            }
          }
          urls.append(url)
        }
        let prepared = try await Task.detached { try QuickNativeSender.prepare(urls) }.value
        guard !closed else { return }
        files = prepared; status = "Elegí el destinatario. No se guardará una vinculación."
        wifi.onPeers = { [weak self] found in Task { @MainActor in
          guard let self else { return }
          self.wifiPeers = found.map { peer in NativeNearbyDestination(id: peer.id, name: peer.name, transport: peer.transport, chunkSize: 128 * 1024, rpc: { path, body in
            try await withCheckedThrowingContinuation { reply in self.wifi.request(peer.token, path: path, body: body) { reply.resume(with: $0) } }
          }) }
          self.merge()
        } }
        wifi.onError = { [weak self] message in Task { @MainActor in self?.error = message } }
        bluetooth.onPeers = { [weak self] found in Task { @MainActor in self?.bluetoothPeers = found; self?.merge() } }
        bluetooth.onError = { [weak self] message in Task { @MainActor in self?.error = message } }
        try wifi.start(id: UUID().uuidString, name: "LanLink", advertise: false)
        bluetooth.start()
      } catch { self.error = "No se pudieron preparar los archivos: \(error.localizedDescription)"; status = "Compartir con LanLink" }
    }
  }
  private func merge() {
    var selected: [String: NativeNearbyDestination] = [:]
    for peer in wifiPeers.sorted(by: { $0.transport == "Red local" && $1.transport != "Red local" }) + bluetoothPeers {
      if selected[peer.id] == nil { selected[peer.id] = peer }
    }
    peers = selected.values.sorted { $0.name < $1.name }
  }
  func send(_ peer: NativeNearbyDestination) {
    guard !sending else { return }
    sending = true; error = nil; status = "Conectando con \(peer.name) · \(peer.transport)…"
    let sender = QuickNativeSender(); self.sender = sender
    sender.onCode = { [weak self] code in self?.code = code; self?.status = "Compará el código con el receptor y esperá su aceptación." }
    sender.confirmCode = { [weak self] _ in
      guard let self else { return false }
      self.canConfirm = true
      return await withCheckedContinuation {
        self.confirmation = $0
        self.confirmationTimeout = Task { [weak self] in
          try? await Task.sleep(nanoseconds: 120_000_000_000)
          guard !Task.isCancelled, let self else { return }
          self.confirmation?.resume(returning: false); self.confirmation = nil; self.canConfirm = false
        }
      }
    }
    sender.onProgress = { [weak self] name, done, total in
      self?.code = nil; self?.status = "\(name) · \(total == 0 ? 100 : done * 100 / total)%"
    }
    Task {
      do {
        #if os(iOS)
        let name = UIDevice.current.name
        #else
        let name = Host.current().localizedName ?? "Mac"
        #endif
        try await sender.send(files, name: String(name.prefix(100)), rpc: peer.rpc, chunkSize: peer.chunkSize)
        finished = true; status = "El receptor verificó los archivos completos."
      } catch { self.error = error.localizedDescription; sending = false; code = nil }
    }
  }
  func confirm() { confirmationTimeout?.cancel(); canConfirm = false; confirmation?.resume(returning: true); confirmation = nil }
  func close() {
    closed = true
    confirmationTimeout?.cancel()
    sender?.cancelled = true; confirmation?.resume(returning: false); confirmation = nil
    wifi.stop(); bluetooth.stop()
    if let root { try? FileManager.default.removeItem(at: root) }
    completion?()
  }
}

private struct SharePanel: View {
  @ObservedObject var model: ShareModel
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack { Image(systemName: "arrow.left.arrow.right").foregroundColor(.teal); Text("LanLink").font(.title2).bold(); Spacer() }
        Text(model.status)
        if !model.files.isEmpty { Text("\(model.files.count) archivo(s)").font(.caption).foregroundColor(.secondary) }
        ForEach(Array(model.files.prefix(3).enumerated()), id: \.offset) { _, file in Text(file.name).font(.caption).lineLimit(2) }
        if let code = model.code {
          Text("\(code.prefix(3)) \(code.suffix(3))").font(.system(size: 36, weight: .bold, design: .monospaced)).minimumScaleFactor(0.5).lineLimit(1)
          if model.canConfirm { Button("Los códigos coinciden · Enviar") { model.confirm() } }
        }
        if !model.sending && !model.finished {
          if model.peers.isEmpty { Text("Buscando equipos… En el receptor, abrí LanLink y activá «Recibir cerca».").foregroundColor(.secondary) }
          ForEach(Array(model.peers.enumerated()), id: \.offset) { _, peer in
            Button(action: { model.send(peer) }) {
              HStack { Image(systemName: peer.transport == "Bluetooth" ? "antenna.radiowaves.left.and.right" : "laptopcomputer"); VStack(alignment: .leading) { Text(peer.name); Text(peer.transport).font(.caption) }; Spacer(); Image(systemName: "chevron.right") }
            }.buttonStyle(.bordered)
          }
          Text("Sin Wi-Fi compartida: dejá Wi-Fi y Bluetooth encendidos. Bluetooth puede ser lento para videos grandes.").font(.caption).foregroundColor(.secondary)
        }
        if let error = model.error { Text(error).foregroundColor(.red).font(.caption) }
        Divider()
        HStack { Spacer(); Button(model.finished ? "Listo" : "Cancelar") { model.close() } }
      }.padding(20)
    }.frame(minWidth: 280, idealWidth: 400, minHeight: 300, idealHeight: 460).accentColor(.teal)
  }
}

#if os(iOS)
final class ShareViewController: UIViewController {
  private let model = ShareModel()
  override func viewDidLoad() {
    super.viewDidLoad()
    let host = UIHostingController(rootView: SharePanel(model: model))
    addChild(host); host.view.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(host.view)
    NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
    host.didMove(toParent: self)
    model.completion = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
    if let context = extensionContext { model.start(context) }
  }
}
#else
final class ShareViewController: NSViewController {
  private let model = ShareModel()
  override func loadView() { view = NSHostingView(rootView: SharePanel(model: model)); preferredContentSize = NSSize(width: 420, height: 480) }
  override func viewDidAppear() {
    super.viewDidAppear()
    model.completion = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
    if let context = extensionContext { model.start(context) }
  }
}
#endif
