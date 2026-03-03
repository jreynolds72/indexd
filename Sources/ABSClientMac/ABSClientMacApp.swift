import SwiftUI
import ABSCore
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        applyBundledAppIconIfAvailable()
        MacMediaIntegrationManager.shared.start()
    }

    private func applyBundledAppIconIfAvailable() {
        let resourceCandidates = [
            "indexd-icon",
            "indexd-app-icon",
            "app-icon"
        ]

        for name in resourceCandidates {
            if let image = NSImage(named: name) {
                NSApp.applicationIconImage = image
                return
            }

            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                NSApp.applicationIconImage = image
                return
            }
        }
    }
}

@main
struct IndexdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var preferences = AppPreferences()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(preferences)
        }

        Settings {
            PreferencesView()
                .environmentObject(preferences)
        }
        .defaultSize(width: 1200, height: 560)
        .windowResizability(.automatic)

        Window("Settings", id: "indexd-settings-window") {
            PreferencesView()
                .environmentObject(preferences)
        }
        .defaultSize(width: 1200, height: 560)
        .windowResizability(.automatic)
    }
}
