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

public enum DownloadError: Error {
    case invalidStorageDirectory
    case fileMoveFailed
}

public protocol DownloadTransport: Sendable {
    func download(from remoteURL: URL) async throws -> URL
}

public struct URLSessionDownloadTransport: DownloadTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(from remoteURL: URL) async throws -> URL {
        let (tempFileURL, _) = try await session.download(from: remoteURL)
        return tempFileURL
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
            rootDirectory = appSupport.appendingPathComponent("ABSClient", isDirectory: true)
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

    public func download(itemID: String, from remoteURL: URL) async throws -> URL {
        if let existing = localFileURL(for: itemID) {
            states[itemID] = .downloaded
            return existing
        }

        states[itemID] = .downloading

        do {
            let tempFileURL = try await transport.download(from: remoteURL)
            let destinationURL = destinationURL(for: itemID, remoteURL: remoteURL)

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

    private func destinationURL(for itemID: String, remoteURL: URL) -> URL {
        let ext = remoteURL.pathExtension
        let fileName = ext.isEmpty ? itemID : "\(itemID).\(ext)"
        return downloadsDirectory.appendingPathComponent(fileName)
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
