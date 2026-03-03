import XCTest
@testable import ABSCore

final class DownloadManagerTests: XCTestCase {
    func testDownloadStoresFileAndUsesOfflinePlaybackURL() async throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let transport = MockDownloadTransport(payload: Data("audio-data".utf8))
        let manager = try DownloadManager(storageDirectory: root, transport: transport)

        let remoteURL = URL(string: "https://example.com/book.mp3")!
        let localURL = try await manager.download(itemID: "book-1", from: remoteURL)
        let state = await manager.state(for: "book-1")
        let playbackURL = await manager.playbackURL(for: "book-1", remoteURL: remoteURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
        XCTAssertEqual(state, .downloaded)
        XCTAssertEqual(playbackURL, localURL)
    }

    func testDownloadSurvivesManagerRestart() async throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let remoteURL = URL(string: "https://example.com/book.mp3")!

        do {
            let transport = MockDownloadTransport(payload: Data("persist-me".utf8))
            let manager = try DownloadManager(storageDirectory: root, transport: transport)
            _ = try await manager.download(itemID: "book-2", from: remoteURL)
        }

        let restarted = try DownloadManager(storageDirectory: root, transport: MockDownloadTransport(payload: Data()))
        let restoredLocal = await restarted.localFileURL(for: "book-2")
        let restoredState = await restarted.state(for: "book-2")

        XCTAssertNotNil(restoredLocal)
        XCTAssertEqual(restoredState, .downloaded)
    }

    func testDeleteDownloadRevertsToStreamingPlaybackURL() async throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let remoteURL = URL(string: "https://example.com/book.mp3")!
        let transport = MockDownloadTransport(payload: Data("to-delete".utf8))
        let manager = try DownloadManager(storageDirectory: root, transport: transport)

        _ = try await manager.download(itemID: "book-3", from: remoteURL)
        try await manager.deleteDownload(itemID: "book-3")
        let localAfterDelete = await manager.localFileURL(for: "book-3")
        let stateAfterDelete = await manager.state(for: "book-3")
        let playbackAfterDelete = await manager.playbackURL(for: "book-3", remoteURL: remoteURL)

        XCTAssertNil(localAfterDelete)
        XCTAssertEqual(stateAfterDelete, .notDownloaded)
        XCTAssertEqual(playbackAfterDelete, remoteURL)
    }

    private func makeTempDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("abs-download-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private actor MockDownloadTransport: DownloadTransport {
    private let payload: Data

    init(payload: Data) {
        self.payload = payload
    }

    func download(from remoteURL: URL) async throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mock-download-\(UUID().uuidString)")
        try payload.write(to: tempURL)
        return tempURL
    }
}
