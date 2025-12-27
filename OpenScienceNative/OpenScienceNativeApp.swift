import SwiftUI

@main
struct OpenScienceNativeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var chat = ChatViewModel()

  var body: some Scene {
    WindowGroup {
      ChatView()
        .environmentObject(chat)
        .onAppear {
          // PRIVACY: API key is loaded into RAM only; never written to disk.
          chat.bootstrapFromEnvironmentIfAvailable()
          chat.refreshModels()
        }
    }
    .windowStyle(.hiddenTitleBar)
  }
}


