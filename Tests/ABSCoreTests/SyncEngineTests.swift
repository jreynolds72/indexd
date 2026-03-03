import XCTest
@testable import ABSCore

final class SyncEngineTests: XCTestCase {
    func testPeriodicUpdatesRespectConfiguredInterval() async throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let remote = MockRemoteSync()
        let connectivity = StaticConnectivity(online: true)
        let config = SyncConfiguration(periodicUpdateInterval: 15, conflictThreshold: 30)
        let engine = try SyncEngine(remote: remote, connectivity: connectivity, configuration: config, storageDirectory: root)

        let t0 = Date()
        let first = try await engine.recordProgress(itemID: "book-1", positionSeconds: 10, trigger: .periodic, at: t0)
        let second = try await engine.recordProgress(itemID: "book-1", positionSeconds: 20, trigger: .periodic, at: t0.addingTimeInterval(5))
        let third = try await engine.recordProgress(itemID: "book-1", positionSeconds: 30, trigger: .periodic, at: t0.addingTimeInterval(16))

        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertTrue(third)

        let local = await engine.localProgress(itemID: "book-1")
        XCTAssertEqual(local?.positionSeconds, 30)
    }

    func testSyncPushesLocalWhenOnline() async throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let remote = MockRemoteSync()
        let connectivity = StaticConnectivity(online: true)
        let engine = try SyncEngine(remote: remote, connectivity: connectivity, storageDirectory: root)

        _ = try await engine.recordProgress(itemID: "book-2", positionSeconds: 120, trigger: .pause)
        let result = try await engine.sync(itemID: "book-2")

        XCTAssertEqual(result, .syncedLocalToRemote(itemID: "book-2"))
        let pushed = await remote.progress(itemID: "book-2")
        XCTAssertEqual(pushed?.positionSeconds, 120)
    }

    func testSyncPullsRemoteWhenNoLocalProgress() async throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let remote = MockRemoteSync()
        let remoteProgress = PlaybackProgress(itemID: "book-3", positionSeconds: 222, updatedAt: Date())
        await remote.seed(progress: remoteProgress)

        let connectivity = StaticConnectivity(online: true)
        let engine = try SyncEngine(remote: remote, connectivity: connectivity, storageDirectory: root)

        let result = try await engine.sync(itemID: "book-3")
        let local = await engine.localProgress(itemID: "book-3")

        XCTAssertEqual(result, .syncedRemoteToLocal(itemID: "book-3"))
        XCTAssertEqual(local?.positionSeconds, 222)
    }

    func testConflictDetectedWhenDivergenceExceedsThreshold() async throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let remote = MockRemoteSync()
        await remote.seed(progress: PlaybackProgress(itemID: "book-4", positionSeconds: 300, updatedAt: Date()))

        let connectivity = StaticConnectivity(online: true)
        let engine = try SyncEngine(
            remote: remote,
            connectivity: connectivity,
            configuration: SyncConfiguration(periodicUpdateInterval: 15, conflictThreshold: 20),
            storageDirectory: root
        )

        _ = try await engine.recordProgress(itemID: "book-4", positionSeconds: 100, trigger: .manual)
        let result = try await engine.sync(itemID: "book-4")

        switch result {
        case .conflict(let conflict):
            XCTAssertEqual(conflict.itemID, "book-4")
            XCTAssertEqual(conflict.divergenceSeconds, 200)
        default:
            XCTFail("Expected conflict result")
        }
    }

    func testConflictResolverCanChooseLocal() async throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let remote = MockRemoteSync()
        await remote.seed(progress: PlaybackProgress(itemID: "book-5", positionSeconds: 900, updatedAt: Date()))

        let connectivity = StaticConnectivity(online: true)
        let engine = try SyncEngine(
            remote: remote,
            connectivity: connectivity,
            configuration: SyncConfiguration(periodicUpdateInterval: 15, conflictThreshold: 30),
            storageDirectory: root
        )

        _ = try await engine.recordProgress(itemID: "book-5", positionSeconds: 1200, trigger: .quit)
        let result = try await engine.sync(itemID: "book-5") { _ in .useLocal }

        XCTAssertEqual(result, .syncedLocalToRemote(itemID: "book-5"))
        let remoteAfter = await remote.progress(itemID: "book-5")
        XCTAssertEqual(remoteAfter?.positionSeconds, 1200)
    }

    private func makeTempDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("abs-sync-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private actor MockRemoteSync: ProgressRemoteSyncing {
    private var records: [String: PlaybackProgress] = [:]

    func fetchProgress(itemID: String) async throws -> PlaybackProgress? {
        records[itemID]
    }

    func pushProgress(_ progress: PlaybackProgress) async throws {
        records[progress.itemID] = progress
    }

    func seed(progress: PlaybackProgress) {
        records[progress.itemID] = progress
    }

    func progress(itemID: String) -> PlaybackProgress? {
        records[itemID]
    }
}

private struct StaticConnectivity: ConnectivityChecking {
    let online: Bool

    func isOnline() async -> Bool {
        online
    }
}
