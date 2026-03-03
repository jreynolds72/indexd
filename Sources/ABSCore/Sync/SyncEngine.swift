import Foundation

public enum ProgressUpdateTrigger: String, Codable, Sendable {
    case periodic
    case pause
    case stop
    case quit
    case manual
}

public struct SyncConflict: Equatable, Sendable {
    public let itemID: String
    public let local: PlaybackProgress
    public let remote: PlaybackProgress
    public let divergenceSeconds: TimeInterval

    public init(itemID: String, local: PlaybackProgress, remote: PlaybackProgress, divergenceSeconds: TimeInterval) {
        self.itemID = itemID
        self.local = local
        self.remote = remote
        self.divergenceSeconds = divergenceSeconds
    }
}

public enum SyncConflictResolution: Sendable {
    case useLocal
    case useRemote
    case deferred
}

public enum SyncResult: Equatable, Sendable {
    case syncedLocalToRemote(itemID: String)
    case syncedRemoteToLocal(itemID: String)
    case deferredOffline(itemID: String)
    case conflict(SyncConflict)
    case noChanges(itemID: String)
}

public protocol ProgressRemoteSyncing: Sendable {
    func fetchProgress(itemID: String) async throws -> PlaybackProgress?
    func pushProgress(_ progress: PlaybackProgress) async throws
}

public protocol ConnectivityChecking: Sendable {
    func isOnline() async -> Bool
}

public struct SyncConfiguration: Equatable, Sendable {
    public let periodicUpdateInterval: TimeInterval
    public let conflictThreshold: TimeInterval

    public init(periodicUpdateInterval: TimeInterval = 15, conflictThreshold: TimeInterval = 30) {
        self.periodicUpdateInterval = periodicUpdateInterval
        self.conflictThreshold = conflictThreshold
    }
}

private struct LocalProgressRecord: Codable, Sendable {
    let progress: PlaybackProgress
    let needsUpload: Bool
    let lastPeriodicUpdateAt: Date?
}

public actor SyncEngine {
    private let remote: ProgressRemoteSyncing
    private let connectivity: ConnectivityChecking
    private let fileManager: FileManager
    private let storageURL: URL
    private let configuration: SyncConfiguration

    private var localRecords: [String: LocalProgressRecord] = [:]

    public init(
        remote: ProgressRemoteSyncing,
        connectivity: ConnectivityChecking,
        configuration: SyncConfiguration = SyncConfiguration(),
        storageDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.remote = remote
        self.connectivity = connectivity
        self.configuration = configuration
        self.fileManager = fileManager

        let baseDirectory: URL
        if let storageDirectory {
            baseDirectory = storageDirectory
        } else if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            baseDirectory = appSupport.appendingPathComponent("indexd", isDirectory: true)
        } else {
            baseDirectory = fileManager.temporaryDirectory.appendingPathComponent("indexd", isDirectory: true)
        }

        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        self.storageURL = baseDirectory.appendingPathComponent("progress-sync.json")
        self.localRecords = try Self.loadRecords(fileManager: fileManager, storageURL: storageURL)
    }

    @discardableResult
    public func recordProgress(
        itemID: String,
        positionSeconds: TimeInterval,
        durationSeconds: TimeInterval? = nil,
        trigger: ProgressUpdateTrigger,
        at timestamp: Date = Date()
    ) throws -> Bool {
        let existing = localRecords[itemID]

        if trigger == .periodic,
           let lastPeriodic = existing?.lastPeriodicUpdateAt,
           timestamp.timeIntervalSince(lastPeriodic) < configuration.periodicUpdateInterval {
            return false
        }

        let progress = PlaybackProgress(
            itemID: itemID,
            positionSeconds: max(0, positionSeconds),
            durationSeconds: durationSeconds,
            updatedAt: timestamp
        )
        let periodicTimestamp = trigger == .periodic ? timestamp : existing?.lastPeriodicUpdateAt

        localRecords[itemID] = LocalProgressRecord(
            progress: progress,
            needsUpload: true,
            lastPeriodicUpdateAt: periodicTimestamp
        )

        try persistRecords()
        return true
    }

    public func localProgress(itemID: String) -> PlaybackProgress? {
        localRecords[itemID]?.progress
    }

    public func sync(
        itemID: String,
        conflictResolver: ((SyncConflict) -> SyncConflictResolution)? = nil
    ) async throws -> SyncResult {
        guard await connectivity.isOnline() else {
            return .deferredOffline(itemID: itemID)
        }

        let local = localRecords[itemID]
        let remoteProgress = try await remote.fetchProgress(itemID: itemID)

        switch (local?.progress, remoteProgress) {
        case (nil, nil):
            return .noChanges(itemID: itemID)

        case let (localProgress?, nil):
            try await remote.pushProgress(localProgress)
            try markUploaded(itemID: itemID, progress: localProgress)
            return .syncedLocalToRemote(itemID: itemID)

        case let (nil, remoteProgress?):
            try applyRemoteProgress(remoteProgress)
            return .syncedRemoteToLocal(itemID: itemID)

        case let (localProgress?, remoteProgress?):
            let divergence = abs(localProgress.positionSeconds - remoteProgress.positionSeconds)
            if divergence > configuration.conflictThreshold {
                let conflict = SyncConflict(
                    itemID: itemID,
                    local: localProgress,
                    remote: remoteProgress,
                    divergenceSeconds: divergence
                )

                guard let conflictResolver else {
                    return .conflict(conflict)
                }

                switch conflictResolver(conflict) {
                case .useLocal:
                    try await remote.pushProgress(localProgress)
                    try markUploaded(itemID: itemID, progress: localProgress)
                    return .syncedLocalToRemote(itemID: itemID)
                case .useRemote:
                    try applyRemoteProgress(remoteProgress)
                    return .syncedRemoteToLocal(itemID: itemID)
                case .deferred:
                    return .conflict(conflict)
                }
            }

            if local?.needsUpload == true || localProgress.updatedAt >= remoteProgress.updatedAt {
                try await remote.pushProgress(localProgress)
                try markUploaded(itemID: itemID, progress: localProgress)
                return .syncedLocalToRemote(itemID: itemID)
            } else {
                try applyRemoteProgress(remoteProgress)
                return .syncedRemoteToLocal(itemID: itemID)
            }
        }
    }

    private func applyRemoteProgress(_ remoteProgress: PlaybackProgress) throws {
        let current = localRecords[remoteProgress.itemID]

        localRecords[remoteProgress.itemID] = LocalProgressRecord(
            progress: remoteProgress,
            needsUpload: false,
            lastPeriodicUpdateAt: current?.lastPeriodicUpdateAt
        )

        try persistRecords()
    }

    private func markUploaded(itemID: String, progress: PlaybackProgress) throws {
        let existing = localRecords[itemID]

        localRecords[itemID] = LocalProgressRecord(
            progress: progress,
            needsUpload: false,
            lastPeriodicUpdateAt: existing?.lastPeriodicUpdateAt
        )

        try persistRecords()
    }

    private static func loadRecords(fileManager: FileManager, storageURL: URL) throws -> [String: LocalProgressRecord] {
        guard fileManager.fileExists(atPath: storageURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: storageURL)
        let decoder = JSONDecoder()
        return try decoder.decode([String: LocalProgressRecord].self, from: data)
    }

    private func persistRecords() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(localRecords)
        try data.write(to: storageURL, options: [.atomic])
    }
}
