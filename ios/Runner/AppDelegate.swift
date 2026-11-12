import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LanLinkDownloads")!
    let downloads = LanLinkDownloads()
    let channel = FlutterMethodChannel(name: "lanlink/downloads", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in downloads.handle(call, result: result) }
  }
}

private final class LanLinkDownloads: NSObject, UIDocumentPickerDelegate {
  private let queue = DispatchQueue(label: "lanlink.downloads")
  private var pickerResult: FlutterResult?
  private let bookmarkKey = "lanlink-download-folder"

  private var localRoot: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Downloads", isDirectory: true)
  }

  private func withRoot<T>(_ action: (URL) throws -> T) throws -> T {
    guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
      try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
      return try action(localRoot)
    }
    var stale = false
    let root = try URL(resolvingBookmarkData: data, options: .withoutUI,
                       relativeTo: nil, bookmarkDataIsStale: &stale)
    guard root.startAccessingSecurityScopedResource() else {
      throw NSError(domain: "LanLink", code: 1, userInfo: [NSLocalizedDescriptionKey:
        "Se perdió el permiso de Descargas. Volvé a elegir la carpeta."])
    }
    defer { root.stopAccessingSecurityScopedResource() }
    if stale {
      UserDefaults.standard.set(try root.bookmarkData(options: .minimalBookmark,
        includingResourceValuesForKeys: nil, relativeTo: nil), forKey: bookmarkKey)
    }
    return try action(root)
  }

  private func coordinated<T>(_ url: URL, writing: Bool, _ action: (URL) throws -> T) throws -> T {
    var coordinationError: NSError?
    var outcome: Result<T, Error>?
    let accessor: (URL) -> Void = { target in outcome = Result { try action(target) } }
    let coordinator = NSFileCoordinator()
    if writing {
      coordinator.coordinate(writingItemAt: url, options: .forMerging,
        error: &coordinationError, byAccessor: accessor)
    } else {
      coordinator.coordinate(readingItemAt: url, options: [],
        error: &coordinationError, byAccessor: accessor)
    }
    if let error = coordinationError { throw error }
    guard let outcome else { throw CocoaError(.fileReadUnknown) }
    return try outcome.get()
  }

  private func destination(_ root: URL) throws -> URL {
    let directory = root.appendingPathComponent("LanLink", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func label(_ root: URL) -> String {
    if root.standardizedFileURL == localRoot.standardizedFileURL {
      return "Archivos → En mi iPhone → LanLink → Downloads/LanLink"
    }
    return "\(root.lastPathComponent)/LanLink"
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "chooseDirectory" {
      guard pickerResult == nil else { result(FlutterError(code: "busy", message: "Ya hay una selección abierta.", details: nil)); return }
      guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
        .flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController else {
        result(FlutterError(code: "window", message: "No se encontró una ventana.", details: nil)); return
      }
      var presenter = root
      while let next = presenter.presentedViewController { presenter = next }
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
      picker.delegate = self
      picker.allowsMultipleSelection = false
      pickerResult = result
      presenter.present(picker, animated: true)
      return
    }
    queue.async {
      do {
        let value = try self.perform(call)
        DispatchQueue.main.async { result(value) }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "downloads", message: error.localizedDescription, details: nil)) }
      }
    }
  }

  private func perform(_ call: FlutterMethodCall) throws -> Any {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "initialize":
      return try withRoot { root in
        try coordinated(root, writing: true) { _ = try destination($0) }
        return label(root)
      }
    case "publish":
      guard let path = args["path"] as? String, let name = args["name"] as? String,
        name == (name as NSString).lastPathComponent, name != ".", name != "..", !name.isEmpty else {
        throw CocoaError(.fileWriteInvalidFileName)
      }
      return try withRoot { root in
        try coordinated(root, writing: true) { coordinatedRoot in
          let directory = try destination(coordinatedRoot)
          var target = directory.appendingPathComponent(name)
          var index = 1
          while FileManager.default.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(index)-\(name)")
            index += 1
          }
          // Copy to a hidden sibling first so incomplete downloads aren't exposed.
          let pending = directory.appendingPathComponent(".\(UUID().uuidString).part")
          defer { try? FileManager.default.removeItem(at: pending) }
          try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: pending)
          try FileManager.default.moveItem(at: pending, to: target)
          return target.path
        }
      }
    case "list":
      return try withRoot { root in
        var roots = [root]
        if root.standardizedFileURL != localRoot.standardizedFileURL,
          FileManager.default.fileExists(atPath: localRoot.path) { roots.append(localRoot) }
        var rows = [[String: Any]]()
        for base in roots {
          rows += try coordinated(base, writing: false) { base in
            let directory = base.appendingPathComponent("LanLink", isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: directory,
              includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
              .compactMap { url -> [String: Any]? in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard values.isRegularFile == true else { return nil }
                return ["name": url.lastPathComponent, "location": url.path,
                  "modified": Int64((values.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000)]
              }
          }
        }
        return rows
      }
    case "export":
      guard let path = args["location"] as? String else { throw CocoaError(.fileReadInvalidFileName) }
      return try withRoot { root in
        let source = URL(fileURLWithPath: path).standardizedFileURL
        let allowed = [root, localRoot].map { $0.appendingPathComponent("LanLink").standardizedFileURL.path + "/" }
        guard allowed.contains(where: { source.path.hasPrefix($0) }) else { throw CocoaError(.fileReadNoPermission) }
        return try coordinated(source, writing: false) { url in
          let exportRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
          try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
          let target = exportRoot.appendingPathComponent(url.lastPathComponent)
          try FileManager.default.copyItem(at: url, to: target)
          return target.path
        }
      }
    default:
      throw CocoaError(.featureUnsupported)
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pickerResult?(nil)
    pickerResult = nil
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let result = pickerResult
    pickerResult = nil
    guard let root = urls.first else { result?(nil); return }
    queue.async {
      do {
        guard root.startAccessingSecurityScopedResource() else { throw CocoaError(.fileWriteNoPermission) }
        defer { root.stopAccessingSecurityScopedResource() }
        try self.coordinated(root, writing: true) { _ = try self.destination($0) }
        let bookmark = try root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: self.bookmarkKey)
        DispatchQueue.main.async { result?(self.label(root)) }
      } catch {
        DispatchQueue.main.async { result?(FlutterError(code: "downloads", message: error.localizedDescription, details: nil)) }
      }
    }
  }
}
