import SwiftUI
@testable import OvercrossCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct LudusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 980, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .help) {
                Button("Ludus Help") {
                    appModel.selectedSection = .diagnostics
                }
                .keyboardShortcut("?", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
    }
}
