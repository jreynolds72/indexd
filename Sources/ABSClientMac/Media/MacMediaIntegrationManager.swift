import Foundation
import MediaPlayer
import UserNotifications
import AppKit

extension Notification.Name {
    static let absMediaPlay = Notification.Name("abs.media.play")
    static let absMediaPause = Notification.Name("abs.media.pause")
    static let absMediaTogglePlayPause = Notification.Name("abs.media.toggle")
    static let absMediaSkipBackward = Notification.Name("abs.media.skipBackward")
    static let absMediaSkipForward = Notification.Name("abs.media.skipForward")
    static let absMediaSkipBackwardOneSecond = Notification.Name("abs.media.skipBackwardOneSecond")
    static let absMediaSkipForwardOneSecond = Notification.Name("abs.media.skipForwardOneSecond")
    static let absMediaPreviousChapter = Notification.Name("abs.media.previousChapter")
    static let absMediaNextChapter = Notification.Name("abs.media.nextChapter")
    static let absDockOpenSettings = Notification.Name("abs.dock.openSettings")
    static let absDockSyncProgressNow = Notification.Name("abs.dock.syncProgressNow")
    static let absDockOpenDownloadCache = Notification.Name("abs.dock.openDownloadCache")
    static let absDockShowNowPlaying = Notification.Name("abs.dock.showNowPlaying")
    static let absDockBrowseBooks = Notification.Name("abs.dock.browseBooks")
    static let absDockBrowseAuthors = Notification.Name("abs.dock.browseAuthors")
    static let absDockBrowseSeries = Notification.Name("abs.dock.browseSeries")
    static let absDockBrowseContinue = Notification.Name("abs.dock.browseContinue")
    static let absDockBrowseDownloaded = Notification.Name("abs.dock.browseDownloaded")
}

@MainActor
final class MacMediaIntegrationManager {
    static let shared = MacMediaIntegrationManager()

    private let commandCenter = MPRemoteCommandCenter.shared()
    private let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
    private var notificationCenter: UNUserNotificationCenter?

    private var commandTokens: [Any] = []
    private var configured = false

    private init() {}

    func start() {
        configureRemoteCommandsIfNeeded()
        configureNotificationsIfAvailable()
    }

    func updateNowPlaying(
        title: String,
        author: String?,
        elapsedSeconds: TimeInterval,
        duration: TimeInterval?,
        playbackRate: Double,
        isPlaying: Bool,
        artworkImage: NSImage?
    ) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsedSeconds),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0.0
        ]

        if let author {
            info[MPMediaItemPropertyArtist] = author
        }

        if let duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }

        if let artworkImage {
            let artwork = MPMediaItemArtwork(boundsSize: artworkImage.size) { _ in
                artworkImage
            }
            info[MPMediaItemPropertyArtwork] = artwork
        }

        nowPlayingInfoCenter.nowPlayingInfo = info
        nowPlayingInfoCenter.playbackState = isPlaying ? .playing : .paused
    }

    func clearNowPlaying() {
        nowPlayingInfoCenter.nowPlayingInfo = nil
        nowPlayingInfoCenter.playbackState = .stopped
    }

    func notifyDownloadComplete(title: String) {
        guard let notificationCenter else { return }

        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = title
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "abs.download.complete.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        notificationCenter.add(request)
    }

    private func configureRemoteCommandsIfNeeded() {
        guard !configured else { return }
        configured = true

        let play = commandCenter.playCommand.addTarget { _ in
            NotificationCenter.default.post(name: .absMediaPlay, object: nil)
            return .success
        }

        let pause = commandCenter.pauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: .absMediaPause, object: nil)
            return .success
        }

        let toggle = commandCenter.togglePlayPauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: .absMediaTogglePlayPause, object: nil)
            return .success
        }

        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        let skipBack = commandCenter.skipBackwardCommand.addTarget { _ in
            NotificationCenter.default.post(name: .absMediaSkipBackward, object: nil)
            return .success
        }

        commandCenter.skipForwardCommand.preferredIntervals = [30]
        let skipForward = commandCenter.skipForwardCommand.addTarget { _ in
            NotificationCenter.default.post(name: .absMediaSkipForward, object: nil)
            return .success
        }

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.isEnabled = true

        commandTokens = [play, pause, toggle, skipBack, skipForward]
    }

    private func requestNotificationAuthorizationIfNeeded() {
        notificationCenter?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func configureNotificationsIfAvailable() {
        // `swift run` from SwiftPM does not execute as a full app bundle.
        // UserNotifications can assert in that environment, so only enable
        // notification center for real .app launches.
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            notificationCenter = nil
            return
        }

        notificationCenter = UNUserNotificationCenter.current()
        requestNotificationAuthorizationIfNeeded()
    }
}
