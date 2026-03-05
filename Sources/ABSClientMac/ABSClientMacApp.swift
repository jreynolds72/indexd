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

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "indexd")

        menu.addItem(dockItem("Play/Pause", action: #selector(dockPlayPause)))
        menu.addItem(dockItem("Skip Backward", action: #selector(dockSkipBackward)))
        menu.addItem(dockItem("Skip Forward", action: #selector(dockSkipForward)))
        menu.addItem(dockItem("Previous Chapter", action: #selector(dockPreviousChapter)))
        menu.addItem(dockItem("Next Chapter", action: #selector(dockNextChapter)))

        menu.addItem(.separator())
        menu.addItem(dockItem("Now Playing", action: #selector(dockShowNowPlaying)))
        menu.addItem(dockItem("Books", action: #selector(dockBrowseBooks)))
        menu.addItem(dockItem("Authors", action: #selector(dockBrowseAuthors)))
        menu.addItem(dockItem("Series", action: #selector(dockBrowseSeries)))
        menu.addItem(dockItem("Continue", action: #selector(dockBrowseContinue)))
        menu.addItem(dockItem("Downloaded", action: #selector(dockBrowseDownloaded)))

        menu.addItem(.separator())
        menu.addItem(dockItem("Sync Progress Now", action: #selector(dockSyncProgressNow)))
        menu.addItem(dockItem("Open Download Cache in Finder", action: #selector(dockOpenDownloadCache)))
        menu.addItem(dockItem("Open Settings…", action: #selector(dockOpenSettings)))

        return menu
    }

    private func dockItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func postDockCommand(_ name: Notification.Name) {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: name, object: nil)
    }

    @objc private func dockPlayPause() { postDockCommand(.absMediaTogglePlayPause) }
    @objc private func dockSkipBackward() { postDockCommand(.absMediaSkipBackward) }
    @objc private func dockSkipForward() { postDockCommand(.absMediaSkipForward) }
    @objc private func dockPreviousChapter() { postDockCommand(.absMediaPreviousChapter) }
    @objc private func dockNextChapter() { postDockCommand(.absMediaNextChapter) }

    @objc private func dockShowNowPlaying() { postDockCommand(.absDockShowNowPlaying) }
    @objc private func dockBrowseBooks() { postDockCommand(.absDockBrowseBooks) }
    @objc private func dockBrowseAuthors() { postDockCommand(.absDockBrowseAuthors) }
    @objc private func dockBrowseSeries() { postDockCommand(.absDockBrowseSeries) }
    @objc private func dockBrowseContinue() { postDockCommand(.absDockBrowseContinue) }
    @objc private func dockBrowseDownloaded() { postDockCommand(.absDockBrowseDownloaded) }

    @objc private func dockSyncProgressNow() { postDockCommand(.absDockSyncProgressNow) }
    @objc private func dockOpenDownloadCache() { postDockCommand(.absDockOpenDownloadCache) }
    @objc private func dockOpenSettings() { postDockCommand(.absDockOpenSettings) }
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
