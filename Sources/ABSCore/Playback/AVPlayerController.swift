import Foundation
import AVFoundation

public final class AVPlayerController: PlayerControlling {
    private let player: AVPlayer
    private var endObserver: NSObjectProtocol?

    public init(player: AVPlayer = AVPlayer()) {
        self.player = player
    }

    public var currentTime: TimeInterval {
        player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
    }

    public var duration: TimeInterval? {
        guard let item = player.currentItem else { return nil }
        let seconds = item.duration.seconds
        return seconds.isFinite ? seconds : nil
    }

    public var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    public func replaceCurrentItem(with url: URL) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
    }

    public func play() {
        player.play()
    }

    public func pause() {
        player.pause()
    }

    public func seek(to seconds: TimeInterval) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time)
    }

    public func addPeriodicTimeObserver(interval: TimeInterval, handler: @escaping (TimeInterval) -> Void) -> Any {
        let intervalTime = CMTime(seconds: interval, preferredTimescale: 600)
        return player.addPeriodicTimeObserver(forInterval: intervalTime, queue: .main) { time in
            handler(time.seconds)
        }
    }

    public func removeTimeObserver(_ observer: Any) {
        player.removeTimeObserver(observer)
    }

    public func setDidPlayToEndHandler(_ handler: (() -> Void)?) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        guard let currentItem = player.currentItem else { return }
        guard let handler else { return }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: currentItem,
            queue: .main
        ) { _ in
            handler()
        }
    }
}
