import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var incoming: IncomingShareBridge?
  private var pendingFiles: [String] = []
  func configureIncoming(messenger: FlutterBinaryMessenger) {
    incoming = IncomingShareBridge(messenger: messenger)
    if !pendingFiles.isEmpty { incoming?.accept(pendingFiles); pendingFiles.removeAll() }
  }
  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    if let incoming { incoming.accept(filenames) } else { pendingFiles.append(contentsOf: filenames) }
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    sender.reply(toOpenOrPrint: .success)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
