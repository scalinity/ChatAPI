import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationWillTerminate(_ notification: Notification) {
    // PRIVACY: Explicit best-effort wipe signal before process teardown.
    NotificationCenter.default.post(name: .openScienceNativeWillTerminate, object: nil)
  }
}

extension Notification.Name {
  static let openScienceNativeWillTerminate = Notification.Name("OpenScienceNative.willTerminate")
}


