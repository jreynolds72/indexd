import XCTest
@testable import ABSCore

final class PlaybackEngineTests: XCTestCase {
    func testPlayPauseSeekUpdatesState() async {
        let player = MockPlayerController()
        let speedStore = InMemoryPlaybackSpeedStore(playbackRate: 1.0)
        let item = sampleItem
        let engine = await MainActor.run { PlaybackEngine(playerController: player, speedStore: speedStore) }

        await MainActor.run {
            engine.load(item: item, streamURL: URL(string: "https://example.com/audio.mp3")!)
            engine.play()
        }

        let stateAfterPlay = await MainActor.run { engine.state }
        XCTAssertEqual(stateAfterPlay.status, .playing(itemID: item.id))

        await MainActor.run {
            engine.seek(to: 75)
        }
        XCTAssertEqual(player.currentTime, 75)
        let stateAfterSeek = await MainActor.run { engine.state }
        XCTAssertEqual(stateAfterSeek.currentTime, 75)

        await MainActor.run {
            engine.pause()
        }
        let stateAfterPause = await MainActor.run { engine.state }
        XCTAssertEqual(stateAfterPause.status, .paused(itemID: item.id))
    }

    func testPlaybackRatePersistsAcrossEngineInstances() async {
        let speedStore = InMemoryPlaybackSpeedStore(playbackRate: 1.0)
        let item = sampleItem

        let firstPlayer = MockPlayerController()
        let firstEngine = await MainActor.run { PlaybackEngine(playerController: firstPlayer, speedStore: speedStore) }
        await MainActor.run {
            firstEngine.load(item: item, streamURL: URL(string: "https://example.com/audio.mp3")!)
            firstEngine.setPlaybackRate(1.75)
            firstEngine.play()
        }

        XCTAssertEqual(speedStore.playbackRate, 1.75)
        XCTAssertEqual(firstPlayer.rate, 1.75, accuracy: 0.001)

        let secondPlayer = MockPlayerController()
        let secondEngine = await MainActor.run { PlaybackEngine(playerController: secondPlayer, speedStore: speedStore) }
        await MainActor.run {
            secondEngine.load(item: item, streamURL: URL(string: "https://example.com/audio.mp3")!)
            secondEngine.play()
        }

        let secondState = await MainActor.run { secondEngine.state }
        XCTAssertEqual(secondState.playbackRate, 1.75, accuracy: 0.001)
        XCTAssertEqual(secondPlayer.rate, 1.75, accuracy: 0.001)
    }

    func testSelectingChapterSeeksToChapterStart() async {
        let player = MockPlayerController()
        let item = sampleItem
        let engine = await MainActor.run { PlaybackEngine(playerController: player, speedStore: InMemoryPlaybackSpeedStore()) }

        await MainActor.run {
            engine.load(item: item, streamURL: URL(string: "https://example.com/audio.mp3")!)
            engine.selectChapter(at: 1)
        }

        XCTAssertEqual(player.currentTime, 120)
        let state = await MainActor.run { engine.state }
        XCTAssertEqual(state.currentChapterIndex, 1)
    }

    func testEndOfBookStopsPlayback() async {
        let player = MockPlayerController()
        let item = sampleItem
        let engine = await MainActor.run { PlaybackEngine(playerController: player, speedStore: InMemoryPlaybackSpeedStore()) }

        await MainActor.run {
            engine.load(item: item, streamURL: URL(string: "https://example.com/audio.mp3")!)
            engine.play()
        }
        player.currentTime = 300

        await MainActor.run {
            player.triggerDidPlayToEnd()
        }

        let state = await MainActor.run { engine.state }
        XCTAssertEqual(state.status, .ended(itemID: item.id))
        XCTAssertTrue(player.pauseCalled)
    }

    private var sampleItem: ABSCore.LibraryItem {
        ABSCore.LibraryItem(
            id: "item-1",
            title: "Sample",
            author: "Author",
            libraryID: "library-1",
            duration: 300,
            chapters: [
                ABSCore.Chapter(id: "c1", title: "Start", startTime: 0, endTime: 120),
                ABSCore.Chapter(id: "c2", title: "Middle", startTime: 120, endTime: 240),
                ABSCore.Chapter(id: "c3", title: "End", startTime: 240, endTime: 300)
            ]
        )
    }
}

private final class MockPlayerController: PlayerControlling, @unchecked Sendable {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval? = 300
    var rate: Float = 0

    private(set) var pauseCalled = false
    private var periodicHandler: ((TimeInterval) -> Void)?
    private var didPlayToEndHandler: (() -> Void)?

    func replaceCurrentItem(with url: URL) {
    }

    func play() {
    }

    func pause() {
        pauseCalled = true
        rate = 0
    }

    func seek(to seconds: TimeInterval) {
        currentTime = seconds
        periodicHandler?(seconds)
    }

    func addPeriodicTimeObserver(interval: TimeInterval, handler: @escaping (TimeInterval) -> Void) -> Any {
        periodicHandler = handler
        return UUID()
    }

    func removeTimeObserver(_ observer: Any) {
    }

    func setDidPlayToEndHandler(_ handler: (() -> Void)?) {
        didPlayToEndHandler = handler
    }

    func triggerDidPlayToEnd() {
        didPlayToEndHandler?()
    }
}
