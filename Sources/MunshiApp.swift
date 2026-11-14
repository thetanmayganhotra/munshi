import AVFoundation
import SwiftUI

@main
struct MunshiApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Munshi") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 440, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { model.newChat() }.keyboardShortcut("n")
            }
        }
        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
