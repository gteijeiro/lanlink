import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var directBridge: DirectFlutterBridge?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    directBridge = DirectFlutterBridge(messenger: flutterViewController.engine.binaryMessenger)
    (NSApp.delegate as? AppDelegate)?.configureIncoming(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
