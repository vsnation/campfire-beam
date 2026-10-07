import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Campfire for BEAM: see windowShouldClose.
    self.delegate = self

    super.awakeFromNib()
  }

  // Campfire for BEAM: closing the window quits the app
  // (applicationShouldTerminateAfterLastWindowClosed), but only after the
  // window is gone, so the app could not ask anything. Go through the quit
  // path first, with the window still on screen: it may ask to wait for a
  // swap that is still being confirmed (lib/widgets/beam/quit/), and it
  // exits the app itself when quitting goes ahead.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    NSApp.terminate(nil)
    return false
  }
}
