import Foundation
import AVFoundation

public enum PlaybackStatus: Equatable, Sendable {
    case idle
    case ready(itemID: String)
    case playing(itemID: String)
    case paused(itemID: String)
    case ended(itemID: String)
    case failed(message: String)
}

public struct PlaybackState: Equatable, Sendable {
    public let status: PlaybackStatus
    public let currentTime: TimeInterval
    public let duration: TimeInterval?
    public let playbackRate: Double
    public let currentChapterIndex: Int?

    public init(
        status: PlaybackStatus,
        currentTime: TimeInterval,
        duration: TimeInterval?,
        playbackRate: Double,
        currentChapterIndex: Int?
    ) {
        self.status = status
        self.currentTime = currentTime
        self.duration = duration
        self.playbackRate = playbackRate
        self.currentChapterIndex = currentChapterIndex
    }
}

public protocol PlaybackSpeedStoring: AnyObject {
    var playbackRate: Double { get set }
}

public protocol PlayerControlling: AnyObject {
    var currentTime: TimeInterval { get }
    var duration: TimeInterval? { get }
    var rate: Float { get set }

    func replaceCurrentItem(with url: URL)
    func play()
    func pause()
    func seek(to seconds: TimeInterval)
    func addPeriodicTimeObserver(interval: TimeInterval, handler: @escaping (TimeInterval) -> Void) -> Any
    func removeTimeObserver(_ observer: Any)
    func setDidPlayToEndHandler(_ handler: (() -> Void)?)
}

public final class UserDefaultsPlaybackSpeedStore: PlaybackSpeedStoring {
    private let key: String
    private let userDefaults: UserDefaults

    public init(
        key: String = "com.absclient.playback.rate",
        userDefaults: UserDefaults = .standard
    ) {
        self.key = key
        self.userDefaults = userDefaults
    }

    public var playbackRate: Double {
        get {
            let value = userDefaults.double(forKey: key)
            return value == 0 ? 1.0 : value
        }
        set {
            userDefaults.set(newValue, forKey: key)
        }
    }
}

public final class InMemoryPlaybackSpeedStore: PlaybackSpeedStoring, @unchecked Sendable {
    public var playbackRate: Double

    public init(playbackRate: Double = 1.0) {
        self.playbackRate = playbackRate
    }
}

@MainActor
public final class PlaybackEngine {
    public private(set) var state: PlaybackState {
        didSet {
            onStateChange?(state)
        }
    }

    public var onStateChange: ((PlaybackState) -> Void)?

    private let playerController: PlayerControlling
    private var speedStore: PlaybackSpeedStoring

    private var currentItem: LibraryItem?
    private var periodicObserver: Any?

    public init(
        playerController: PlayerControlling = AVPlayerController(),
        speedStore: PlaybackSpeedStoring = UserDefaultsPlaybackSpeedStore()
    ) {
        self.playerController = playerController
        self.speedStore = speedStore

        let persistedRate = Self.clampedRate(speedStore.playbackRate)
        self.state = PlaybackState(
            status: .idle,
            currentTime: 0,
            duration: nil,
            playbackRate: persistedRate,
            currentChapterIndex: nil
        )

        speedStore.playbackRate = persistedRate
        setupObservers()
    }

    deinit {
        if let periodicObserver {
            playerController.removeTimeObserver(periodicObserver)
        }
        playerController.setDidPlayToEndHandler(nil)
    }

    public func load(item: LibraryItem, streamURL: URL, startPosition: TimeInterval? = nil) {
        currentItem = item
        playerController.replaceCurrentItem(with: streamURL)
        attachEndObserver()

        let persistedRate = Self.clampedRate(speedStore.playbackRate)
        speedStore.playbackRate = persistedRate
        if let startPosition {
            playerController.seek(to: max(0, startPosition))
        }

        updateState(status: .ready(itemID: item.id), currentTime: playerController.currentTime)
    }

    public func play() {
        guard let item = currentItem else {
            updateState(status: .failed(message: "No item loaded"), currentTime: 0)
            return
        }

        let rate = Self.clampedRate(speedStore.playbackRate)
        playerController.rate = Float(rate)
        playerController.play()
        playerController.rate = Float(rate)

        updateState(status: .playing(itemID: item.id), currentTime: playerController.currentTime)
    }

    public func pause() {
        guard let item = currentItem else { return }

        playerController.pause()
        updateState(status: .paused(itemID: item.id), currentTime: playerController.currentTime)
    }

    public func seek(to seconds: TimeInterval) {
        guard currentItem != nil else { return }

        let safeTime = max(0, seconds)
        playerController.seek(to: safeTime)
        updateState(status: state.status, currentTime: safeTime)
    }

    public func selectChapter(at index: Int) {
        guard let item = currentItem, item.chapters.indices.contains(index) else { return }

        let chapter = item.chapters[index]
        seek(to: chapter.startTime)
    }

    public func setPlaybackRate(_ rate: Double) {
        let clamped = Self.clampedRate(rate)
        speedStore.playbackRate = clamped

        if case .playing(itemID: _) = state.status {
            playerController.rate = Float(clamped)
        }

        updateState(status: state.status, currentTime: playerController.currentTime)
    }

    private func setupObservers() {
        periodicObserver = playerController.addPeriodicTimeObserver(interval: 1.0) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateState(status: self.state.status, currentTime: time)
            }
        }
    }

    private func attachEndObserver() {
        playerController.setDidPlayToEndHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let item = self.currentItem else { return }
                self.playerController.pause()
                self.updateState(status: .ended(itemID: item.id), currentTime: self.playerController.currentTime)
            }
        }
    }

    private func updateState(status: PlaybackStatus, currentTime: TimeInterval) {
        let chapters = currentItem?.chapters ?? []
        let chapterIndex = Self.chapterIndex(for: currentTime, chapters: chapters)

        let resolvedDuration = playerController.duration ?? currentItem?.duration

        state = PlaybackState(
            status: status,
            currentTime: currentTime,
            duration: resolvedDuration,
            playbackRate: Self.clampedRate(speedStore.playbackRate),
            currentChapterIndex: chapterIndex
        )
    }

    private static func chapterIndex(for time: TimeInterval, chapters: [Chapter]) -> Int? {
        guard !chapters.isEmpty else { return nil }

        for (index, chapter) in chapters.enumerated() {
            let chapterEnd = chapter.endTime ?? .greatestFiniteMagnitude
            if time >= chapter.startTime && time < chapterEnd {
                return index
            }
        }

        return time >= chapters.last?.startTime ?? 0 ? max(0, chapters.count - 1) : nil
    }

    private static func clampedRate(_ rate: Double) -> Double {
        min(max(rate, 0.5), 3.0)
    }
}
