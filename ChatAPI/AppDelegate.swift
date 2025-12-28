import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationWillTerminate(_ notification: Notification) {
    // PRIVACY: Explicit best-effort wipe signal before process teardown.
    NotificationCenter.default.post(name: .chatAPIWillTerminate, object: nil)
  }
}

extension Notification.Name {
  static let chatAPIWillTerminate = Notification.Name("ChatAPI.willTerminate")
}


