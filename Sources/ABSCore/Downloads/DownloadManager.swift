import Foundation

public struct DownloadRecord: Codable, Equatable, Sendable {
    public let itemID: String
    public let remoteURL: URL
    public let localFileName: String
    public let downloadedAt: Date
    public let fileSize: Int64?

    public init(itemID: String, remoteURL: URL, localFileName: String, downloadedAt: Date, fileSize: Int64?) {
        self.itemID = itemID
        self.remoteURL = remoteURL
        self.localFileName = localFileName
        self.downloadedAt = downloadedAt
        self.fileSize = fileSize
    }
}

public enum DownloadError: Error, LocalizedError {
    case invalidStorageDirectory
    case fileMoveFailed

    public var errorDescription: String? {
        switch self {
        case .invalidStorageDirectory:
            return "Unable to access local download storage."
        case .fileMoveFailed:
            return "Downloaded file could not be moved into local storage."
        }
    }
}

public protocol DownloadTransport: Sendable {
    func download(
        from remoteURL: URL,
        progress: (@Sendable (Double) async -> Void)?
    ) async throws -> URL
}

public extension DownloadTransport {
    func download(from remoteURL: URL) async throws -> URL {
        try await download(from: remoteURL, progress: nil)
    }
}

public struct URLSessionDownloadTransport: DownloadTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(
        from remoteURL: URL,
        progress: (@Sendable (Double) async -> Void)?
    ) async throws -> URL {
        guard progress != nil else {
            let (tempFileURL, _) = try await session.download(from: remoteURL)
            return tempFileURL
        }

        await progress?(0)
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer {
            session.finishTasksAndInvalidate()
        }

        return try await delegate.startDownload(remoteURL: remoteURL, session: session)
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: (@Sendable (Double) async -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var tempFileURL: URL?
    private let lock = NSLock()

    init(progress: (@Sendable (Double) async -> Void)?) {
        self.progress = progress
    }

    func startDownload(remoteURL: URL, session: URLSession) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let task = session.downloadTask(with: remoteURL)
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expectedBytes = resolvedExpectedBytes(
            explicit: totalBytesExpectedToWrite,
            task: downloadTask
        )
        guard expectedBytes > 0 else { return }
        let fraction = min(1, max(0, Double(totalBytesWritten) / Double(expectedBytes)))
        Task {
            await progress?(fraction)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The URL provided here is transient and may be removed immediately after callback returns.
        // Copy it to our own temporary location now so didCompleteWithError can safely consume it.
        let retainedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("indexd-download-retained-\(UUID().uuidString)")
        do {
            try? FileManager.default.removeItem(at: retainedURL)
            try FileManager.default.copyItem(at: location, to: retainedURL)
        } catch {
            lock.lock()
            tempFileURL = nil
            lock.unlock()
            return
        }

        lock.lock()
        tempFileURL = retainedURL
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        let tempFileURL = self.tempFileURL
        self.continuation = nil
        self.tempFileURL = nil
        lock.unlock()

        if let error {
            continuation?.resume(throwing: error)
            return
        }

        guard let tempFileURL else {
            continuation?.resume(throwing: DownloadError.fileMoveFailed)
            return
        }

        Task {
            await progress?(1.0)
        }
        continuation?.resume(returning: tempFileURL)
    }

    private func resolvedExpectedBytes(explicit: Int64, task: URLSessionDownloadTask) -> Int64 {
        if explicit > 0 {
            return explicit
        }
        if task.countOfBytesExpectedToReceive > 0 {
            return task.countOfBytesExpectedToReceive
        }
        guard let response = task.response as? HTTPURLResponse else {
            return -1
        }

        if let value = response.value(forHTTPHeaderField: "Content-Length"),
           let length = Int64(value),
           length > 0 {
            return length
        }

        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let total = totalBytes(fromContentRange: contentRange),
           total > 0 {
            return total
        }

        return response.expectedContentLength
    }

    private func totalBytes(fromContentRange headerValue: String) -> Int64? {
        // Example: bytes 0-1023/2048
        guard let slashIndex = headerValue.lastIndex(of: "/") else { return nil }
        let suffix = headerValue[headerValue.index(after: slashIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard suffix != "*" else { return nil }
        return Int64(suffix)
    }
}

public actor DownloadManager {
    private let fileManager: FileManager
    private let transport: DownloadTransport
    private let downloadsDirectory: URL
    private let manifestURL: URL

    private var records: [String: DownloadRecord] = [:]
    private var states: [String: DownloadState] = [:]

    public init(
        storageDirectory: URL? = nil,
        transport: DownloadTransport = URLSessionDownloadTransport(),
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        self.transport = transport

        let rootDirectory: URL
        if let storageDirectory {
            rootDirectory = storageDirectory
        } else if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            rootDirectory = appSupport.appendingPathComponent("indexd", isDirectory: true)
        } else {
            throw DownloadError.invalidStorageDirectory
        }

        self.downloadsDirectory = rootDirectory.appendingPathComponent("Downloads", isDirectory: true)
        self.manifestURL = rootDirectory.appendingPathComponent("downloads-manifest.json")

        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        let loaded = try Self.loadManifestFromDisk(
            fileManager: fileManager,
            downloadsDirectory: downloadsDirectory,
            manifestURL: manifestURL
        )
        self.records = loaded.records
        self.states = loaded.states
    }

    public func download(
        itemID: String,
        from remoteURL: URL,
        preferredFileName: String? = nil,
        progress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> URL {
        if let existing = localFileURL(for: itemID) {
            states[itemID] = .downloaded
            await progress?(1.0)
            return existing
        }

        states[itemID] = .downloading

        do {
            let tempFileURL = try await transport.download(from: remoteURL, progress: progress)
            let destinationURL = destinationURL(
                for: itemID,
                remoteURL: remoteURL,
                preferredFileName: preferredFileName
            )

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            do {
                try fileManager.moveItem(at: tempFileURL, to: destinationURL)
            } catch {
                throw DownloadError.fileMoveFailed
            }

            let fileSize = (try? fileManager.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?.int64Value

            let record = DownloadRecord(
                itemID: itemID,
                remoteURL: remoteURL,
                localFileName: destinationURL.lastPathComponent,
                downloadedAt: Date(),
                fileSize: fileSize
            )

            records[itemID] = record
            states[itemID] = .downloaded
            try persistManifest()

            return destinationURL
        } catch {
            states[itemID] = .notDownloaded
            throw error
        }
    }

    public func state(for itemID: String) -> DownloadState {
        if let state = states[itemID] {
            return state
        }

        return localFileURL(for: itemID) != nil ? .downloaded : .notDownloaded
    }

    public func localFileURL(for itemID: String) -> URL? {
        guard let record = records[itemID] else { return nil }
        let url = downloadsDirectory.appendingPathComponent(record.localFileName)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    public func playbackURL(for itemID: String, remoteURL: URL) -> URL {
        localFileURL(for: itemID) ?? remoteURL
    }

    public func allDownloads() -> [DownloadRecord] {
        records.values.sorted { $0.downloadedAt > $1.downloadedAt }
    }

    public func deleteDownload(itemID: String) throws {
        if let localURL = localFileURL(for: itemID), fileManager.fileExists(atPath: localURL.path) {
            try fileManager.removeItem(at: localURL)
        }

        records.removeValue(forKey: itemID)
        states[itemID] = .notDownloaded
        try persistManifest()
    }

    private func destinationURL(for itemID: String, remoteURL: URL, preferredFileName: String?) -> URL {
        let ext = remoteURL.pathExtension.isEmpty ? "m4b" : remoteURL.pathExtension
        let baseName = sanitizedFileName(
            (preferredFileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? preferredFileName!
            : itemID
        )

        var candidate = downloadsDirectory.appendingPathComponent("\(baseName).\(ext)")
        var attempt = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = downloadsDirectory.appendingPathComponent("\(baseName) \(attempt).\(ext)")
            attempt += 1
        }
        return candidate
    }

    private func sanitizedFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let components = value.components(separatedBy: invalid)
        let joined = components.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? "download" : joined
    }

    private static func loadManifestFromDisk(
        fileManager: FileManager,
        downloadsDirectory: URL,
        manifestURL: URL
    ) throws -> (records: [String: DownloadRecord], states: [String: DownloadState]) {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return ([:], [:])
        }

        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        let loadedRecords = try decoder.decode([DownloadRecord].self, from: data)

        var records: [String: DownloadRecord] = [:]
        var states: [String: DownloadState] = [:]

        for record in loadedRecords {
            let localURL = downloadsDirectory.appendingPathComponent(record.localFileName)
            if fileManager.fileExists(atPath: localURL.path) {
                records[record.itemID] = record
                states[record.itemID] = .downloaded
            } else {
                states[record.itemID] = .notDownloaded
            }
        }

        return (records, states)
    }

    private func persistManifest() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Array(records.values))
        try data.write(to: manifestURL, options: [.atomic])
    }
}
