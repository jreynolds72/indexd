import Foundation

public struct DownloadRecord: Codable, Equatable, Sendable {
    public let itemID: String
    public let remoteURL: URL
    public let localFileName: String
    public let downloadedAt: Date
    public let fileSize: Int64?
    public let itemTitle: String?
    public let itemAuthor: String?

    public init(
        itemID: String,
        remoteURL: URL,
        localFileName: String,
        downloadedAt: Date,
        fileSize: Int64?,
        itemTitle: String? = nil,
        itemAuthor: String? = nil
    ) {
        self.itemID = itemID
        self.remoteURL = remoteURL
        self.localFileName = localFileName
        self.downloadedAt = downloadedAt
        self.fileSize = fileSize
        self.itemTitle = itemTitle
        self.itemAuthor = itemAuthor
    }
}

public enum DownloadJobState: String, Codable, Equatable, Sendable {
    case queued
    case downloading
    case recovered
    case restarted
    case failed
}

public struct DownloadJobRecord: Codable, Equatable, Sendable {
    public let itemID: String
    public let itemTitle: String?
    public let itemAuthor: String?
    public let state: DownloadJobState
    public let lastKnownProgress: Double
    public let updatedAt: Date

    public init(
        itemID: String,
        itemTitle: String?,
        itemAuthor: String?,
        state: DownloadJobState,
        lastKnownProgress: Double,
        updatedAt: Date
    ) {
        self.itemID = itemID
        self.itemTitle = itemTitle
        self.itemAuthor = itemAuthor
        self.state = state
        self.lastKnownProgress = min(max(lastKnownProgress, 0), 1)
        self.updatedAt = updatedAt
    }
}

private struct DownloadManifest: Codable {
    let version: Int
    let records: [DownloadRecord]
    let jobs: [DownloadJobRecord]
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
    private var jobs: [String: DownloadJobRecord] = [:]

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
        self.jobs = loaded.jobs
    }

    public func download(
        itemID: String,
        from remoteURL: URL,
        preferredFileName: String? = nil,
        itemTitle: String? = nil,
        itemAuthor: String? = nil,
        progress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> URL {
        if let existing = localFileURL(for: itemID) {
            states[itemID] = .downloaded
            jobs.removeValue(forKey: itemID)
            await progress?(1.0)
            return existing
        }

        try transitionJob(
            itemID: itemID,
            title: itemTitle,
            author: itemAuthor,
            state: .downloading,
            progress: 0
        )
        states[itemID] = .downloading

        do {
            let tempFileURL = try await transport.download(from: remoteURL, progress: { [weak self] reported in
                guard let self else {
                    await progress?(reported)
                    return
                }
                try? await self.transitionJob(
                    itemID: itemID,
                    title: itemTitle,
                    author: itemAuthor,
                    state: .downloading,
                    progress: reported
                )
                await progress?(reported)
            })
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
                fileSize: fileSize,
                itemTitle: itemTitle,
                itemAuthor: itemAuthor
            )

            records[itemID] = record
            states[itemID] = .downloaded
            jobs.removeValue(forKey: itemID)
            try persistManifest()

            return destinationURL
        } catch {
            states[itemID] = .notDownloaded
            try transitionJob(
                itemID: itemID,
                title: itemTitle,
                author: itemAuthor,
                state: .failed
            )
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

    public func queueDownloadJob(
        itemID: String,
        itemTitle: String?,
        itemAuthor: String?
    ) throws {
        guard records[itemID] == nil else { return }
        try transitionJob(
            itemID: itemID,
            title: itemTitle,
            author: itemAuthor,
            state: .queued
        )
    }

    public func recoverInterruptedJobs() throws -> [DownloadJobRecord] {
        var didMutate = false
        var recovered: [DownloadJobRecord] = []

        for (itemID, job) in jobs {
            if records[itemID] != nil {
                jobs.removeValue(forKey: itemID)
                didMutate = true
                continue
            }

            let nextState: DownloadJobState
            switch job.state {
            case .downloading:
                nextState = .restarted
            case .queued:
                nextState = .recovered
            case .recovered, .restarted, .failed:
                nextState = job.state
            }

            let updated = DownloadJobRecord(
                itemID: job.itemID,
                itemTitle: job.itemTitle,
                itemAuthor: job.itemAuthor,
                state: nextState,
                lastKnownProgress: job.lastKnownProgress,
                updatedAt: Date()
            )

            if updated != job {
                jobs[itemID] = updated
                didMutate = true
            }

            recovered.append(updated)
        }

        if didMutate {
            try persistManifest()
        }

        return recovered.sorted { lhs, rhs in
            if lhs.state == .failed, rhs.state != .failed { return false }
            if lhs.state != .failed, rhs.state == .failed { return true }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public func pendingDownloadJobs() -> [DownloadJobRecord] {
        jobs.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func deleteDownload(itemID: String) throws {
        if let localURL = localFileURL(for: itemID), fileManager.fileExists(atPath: localURL.path) {
            try fileManager.removeItem(at: localURL)
        }

        records.removeValue(forKey: itemID)
        jobs.removeValue(forKey: itemID)
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
    ) throws -> (records: [String: DownloadRecord], states: [String: DownloadState], jobs: [String: DownloadJobRecord]) {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return ([:], [:], [:])
        }

        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        let decodedManifest: DownloadManifest
        if let manifest = try? decoder.decode(DownloadManifest.self, from: data) {
            decodedManifest = manifest
        } else {
            // Backward compatibility with older manifest shape.
            let loadedRecords = try decoder.decode([DownloadRecord].self, from: data)
            decodedManifest = DownloadManifest(version: 1, records: loadedRecords, jobs: [])
        }

        var records: [String: DownloadRecord] = [:]
        var states: [String: DownloadState] = [:]
        var jobs: [String: DownloadJobRecord] = [:]

        for record in decodedManifest.records {
            let localURL = downloadsDirectory.appendingPathComponent(record.localFileName)
            if fileManager.fileExists(atPath: localURL.path) {
                records[record.itemID] = record
                states[record.itemID] = .downloaded
            } else {
                states[record.itemID] = .notDownloaded
            }
        }

        for job in decodedManifest.jobs {
            guard records[job.itemID] == nil else { continue }
            let normalizedState: DownloadJobState = (job.state == .downloading) ? .restarted : job.state
            jobs[job.itemID] = DownloadJobRecord(
                itemID: job.itemID,
                itemTitle: job.itemTitle,
                itemAuthor: job.itemAuthor,
                state: normalizedState,
                lastKnownProgress: job.lastKnownProgress,
                updatedAt: job.updatedAt
            )
            states[job.itemID] = .notDownloaded
        }

        return (records, states, jobs)
    }

    private func persistManifest() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = DownloadManifest(
            version: 2,
            records: Array(records.values),
            jobs: Array(jobs.values)
        )
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: [.atomic])
    }

    private func transitionJob(
        itemID: String,
        title: String?,
        author: String?,
        state: DownloadJobState,
        progress: Double? = nil
    ) throws {
        let existing = jobs[itemID]
        let clampedProgress = min(max(progress ?? existing?.lastKnownProgress ?? 0, 0), 1)
        if let existing,
           existing.state == state,
           abs(existing.lastKnownProgress - clampedProgress) < 0.02,
           state == .downloading {
            return
        }

        let updated = DownloadJobRecord(
            itemID: itemID,
            itemTitle: title ?? existing?.itemTitle,
            itemAuthor: author ?? existing?.itemAuthor,
            state: state,
            lastKnownProgress: clampedProgress,
            updatedAt: Date()
        )
        jobs[itemID] = updated
        try persistManifest()
    }
}
