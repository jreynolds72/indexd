import Foundation
import ABSCore

@MainActor
final class AppViewModel: ObservableObject {
    private enum DownloadFeatureError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Download storage unavailable on this device"
            }
        }
    }

    @Published var serverScheme: String = "http"
    @Published var serverHost: String = ""
    @Published var serverPortText: String = "13378"
    @Published var username: String = ""
    @Published var password: String = ""
    @Published var isConnecting = false
    @Published var isAuthenticated = false
    @Published var errorMessage: String?
    @Published private(set) var isProgressSyncing = false
    @Published private(set) var lastProgressSyncAt: Date?
    @Published private(set) var liveTransportProbe: LiveTransportProbeResult?

    @Published var libraries: [ABSCore.Library] = []
    @Published var selectedLibraryID: String?
    @Published var displayedItems: [ABSCore.LibraryItem] = []

    private let defaults = UserDefaults.standard
    private let serverDefaultsKey = "abs.server.url"
    private let defaultABSPort = 13378

    private var itemsByLibrary: [String: [ABSCore.LibraryItem]] = [:]
    private var coverDataByItemID: [String: Data] = [:]
    private var apiClient: ABSAPIClient?
    private let downloadManager: DownloadManager?
    private let directDownloadTransport: DownloadTransport
    private let secureStore: SecureStoring
    private var syncEngine: SyncEngine?
    private var syncOperationCount = 0

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ABS_DEV_LOCAL_AUTH_STORE"] == "1" {
            secureStore = UserDefaultsSecureStore()
        } else {
            secureStore = KeychainSecureStore()
        }
        #else
        secureStore = KeychainSecureStore()
        #endif
        downloadManager = try? DownloadManager()
        directDownloadTransport = URLSessionDownloadTransport()
    }

    func bootstrap() async {
        if let savedServer = defaults.string(forKey: serverDefaultsKey), !savedServer.isEmpty {
            applyServerAddress(savedServer)
            await initializeClientFromSavedServer()
        }
    }

    func connect() async {
        errorMessage = nil

        guard let url = composedServerURL() else {
            errorMessage = "Enter a valid server host and port"
            return
        }

        guard !username.isEmpty, !password.isEmpty else {
            errorMessage = "Enter username and password"
            return
        }

        isConnecting = true
        defer { isConnecting = false }

        do {
            let client = try await ABSAPIClient(baseURL: url, secureStore: secureStore)
            try await client.signIn(username: username, password: password)

            apiClient = client
            try await configureSyncEngine()
            await updateLiveTransportProbe(using: client)
            isAuthenticated = true
            defaults.set(url.absoluteString, forKey: serverDefaultsKey)

            try await reloadLibraries()
        } catch {
            isAuthenticated = false
            liveTransportProbe = nil
            errorMessage = "Connection failed: \(describe(error))"
        }
    }

    func reloadLibraries() async throws {
        guard let apiClient else { return }

        let loaded = try await apiClient.libraries()
        libraries = loaded

        if selectedLibraryID == nil || !loaded.contains(where: { $0.id == selectedLibraryID }) {
            selectedLibraryID = loaded.first?.id
        }

        if let selectedLibraryID {
            try await loadItems(for: selectedLibraryID)
        } else {
            displayedItems = []
        }
    }

    func refreshLibrariesMetadataOnly() async throws {
        guard let apiClient else { return }

        let loaded = try await apiClient.libraries()
        libraries = loaded

        if selectedLibraryID == nil || !loaded.contains(where: { $0.id == selectedLibraryID }) {
            selectedLibraryID = loaded.first?.id
        }
    }

    func selectLibrary(id: String?) async {
        selectedLibraryID = id
        guard let id else {
            displayedItems = []
            return
        }

        do {
            try await loadItems(for: id)
        } catch {
            errorMessage = "Failed loading items: \(describe(error))"
        }
    }

    func search(query: String) async {
        guard let apiClient else { return }

        let baseItems = itemsByLibrary[selectedLibraryID ?? ""] ?? []

        if query.isEmpty {
            displayedItems = baseItems
            return
        }

        do {
            let results = try await apiClient.search(query: query, in: selectedLibraryID)
            displayedItems = mergeSearchResultsPreservingKnownFields(results, baseItems: baseItems)
        } catch {
            if case APIError.requestFailed(statusCode: 404) = error {
                // Fallback for servers without exposed search endpoint.
                displayedItems = baseItems.filter { item in
                    item.title.localizedCaseInsensitiveContains(query)
                        || (item.author?.localizedCaseInsensitiveContains(query) ?? false)
                }
                return
            }

            errorMessage = "Search failed: \(describe(error))"
        }
    }

    func liveRefreshCurrentContext(searchQuery: String) async {
        guard let apiClient else { return }
        guard let libraryID = selectedLibraryID else { return }

        do {
            let freshItems = try await apiClient.items(in: libraryID)
            itemsByLibrary[libraryID] = freshItems

            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty {
                displayedItems = freshItems
                return
            }

            do {
                let results = try await apiClient.search(query: query, in: libraryID)
                displayedItems = mergeSearchResultsPreservingKnownFields(results, baseItems: freshItems)
            } catch {
                if case APIError.requestFailed(statusCode: 404) = error {
                    displayedItems = freshItems.filter { item in
                        item.title.localizedCaseInsensitiveContains(query)
                            || (item.author?.localizedCaseInsensitiveContains(query) ?? false)
                    }
                } else {
                    // Preserve currently visible results on transient search failures.
                    errorMessage = "Search failed: \(describe(error))"
                }
            }
        } catch {
            errorMessage = "Failed loading items: \(describe(error))"
        }
    }

    func refreshDetailsForSelectedItem(itemID: String?) async {
        guard let itemID, let apiClient else { return }

        do {
            let details = try await apiClient.itemDetails(itemID: itemID, fallbackLibraryID: selectedLibraryID)
            mergeDetailedItem(details)
        } catch {
            // Keep existing list item if details request fails.
        }
    }

    func liveUpdateEvents() async -> AsyncThrowingStream<Void, Error>? {
        guard isAuthenticated, let apiClient else { return nil }
        return await apiClient.liveUpdateEvents(preferred: liveTransportProbe?.recommended)
    }

    func streamURL(for itemID: String) async throws -> URL {
        guard let apiClient else {
            throw APIError.invalidResponse
        }
        return try await apiClient.streamURL(for: itemID)
    }

    func playbackChapters(for itemID: String) async throws -> [ABSCore.Chapter] {
        guard let apiClient else {
            throw APIError.invalidResponse
        }
        return try await apiClient.playbackChapters(itemID: itemID)
    }

    func localDownloadURL(for itemID: String) async -> URL? {
        guard let downloadManager else { return nil }
        return await downloadManager.localFileURL(for: itemID)
    }

    func downloadState(for itemID: String) async -> DownloadState {
        guard let downloadManager else { return .notDownloaded }
        return await downloadManager.state(for: itemID)
    }

    func downloadedItemIDs() async -> Set<String> {
        guard let downloadManager else { return [] }
        return Set(await downloadManager.allDownloads().map(\.itemID))
    }

    func queueDownloadJob(itemID: String) async {
        guard let downloadManager else { return }
        let itemMetadata = item(withID: itemID)
        let itemTitle = itemMetadata?.title
        let itemAuthor = itemMetadata?.authors.joined(separator: ", ")
        try? await downloadManager.queueDownloadJob(
            itemID: itemID,
            itemTitle: itemTitle,
            itemAuthor: itemAuthor
        )
    }

    func recoverPendingDownloadJobs() async -> [DownloadJobRecord] {
        guard let downloadManager else { return [] }
        return (try? await downloadManager.recoverInterruptedJobs()) ?? []
    }

    func pendingDownloadJobs() async -> [DownloadJobRecord] {
        guard let downloadManager else { return [] }
        return await downloadManager.pendingDownloadJobs()
    }

    @discardableResult
    func downloadItem(
        itemID: String,
        progress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> URL {
        guard let downloadManager else {
            throw DownloadFeatureError.unavailable
        }
        let remoteURL = try await streamURL(for: itemID)
        let itemMetadata = item(withID: itemID)
        let preferredFileName = itemMetadata?.title
        let itemTitle = itemMetadata?.title
        let itemAuthor = itemMetadata?.authors.joined(separator: ", ")
        return try await downloadManager.download(
            itemID: itemID,
            from: remoteURL,
            preferredFileName: preferredFileName,
            itemTitle: itemTitle,
            itemAuthor: itemAuthor,
            progress: progress
        )
    }

    func removeDownloadedItem(itemID: String) async throws {
        guard let downloadManager else { return }
        try await downloadManager.deleteDownload(itemID: itemID)
    }

    func clearAllDownloads() async throws {
        guard let downloadManager else { return }
        let records = await downloadManager.allDownloads()
        for record in records {
            try await downloadManager.deleteDownload(itemID: record.itemID)
        }
    }

    func downloadCacheDirectoryURL() async -> URL? {
        guard let downloadManager else { return nil }
        let records = await downloadManager.allDownloads()
        if let first = records.first {
            return await downloadManager.localFileURL(for: first.itemID)?.deletingLastPathComponent()
        }
        // Triggered path by asking a state lookup and then inferring via app support.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return support?.appendingPathComponent("indexd/Downloads", isDirectory: true)
    }

    @discardableResult
    func downloadItemToDirectory(
        itemID: String,
        directoryURL: URL,
        progress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> URL {
        let remoteURL = try await streamURL(for: itemID)
        let tempURL = try await directDownloadTransport.download(from: remoteURL, progress: progress)
        let destinationURL = uniqueDestinationURL(
            in: directoryURL,
            itemID: itemID,
            remoteURL: remoteURL
        )

        do {
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.copyItem(at: tempURL, to: destinationURL)
            try? FileManager.default.removeItem(at: tempURL)
        }

        return destinationURL
    }

    func playbackURL(for itemID: String) async throws -> URL {
        if let localURL = await localDownloadURL(for: itemID) {
            return localURL
        }
        return try await streamURL(for: itemID)
    }

    func coverData(for itemID: String) async -> Data? {
        if let cached = coverDataByItemID[itemID] {
            return cached
        }

        guard let apiClient else { return nil }

        do {
            let data = try await apiClient.coverData(for: itemID)
            coverDataByItemID[itemID] = data
            return data
        } catch {
            return nil
        }
    }

    func item(withID itemID: String) -> ABSCore.LibraryItem? {
        if let displayed = displayedItems.first(where: { $0.id == itemID }) {
            return displayed
        }

        for (_, items) in itemsByLibrary {
            if let item = items.first(where: { $0.id == itemID }) {
                return item
            }
        }

        return nil
    }

    func setError(_ message: String) {
        errorMessage = message
    }

    func logout() async {
        if let apiClient {
            try? await apiClient.signOut()
        }

        apiClient = nil
        syncEngine = nil
        isAuthenticated = false
        isConnecting = false
        errorMessage = nil
        libraries = []
        selectedLibraryID = nil
        displayedItems = []
        itemsByLibrary = [:]
        coverDataByItemID = [:]
        liveTransportProbe = nil
        password = ""
        defaults.removeObject(forKey: serverDefaultsKey)
    }

    var serverAddressDisplay: String {
        guard let url = composedServerURL() else { return "Not configured" }
        return url.absoluteString
    }

    var currentLibraryItems: [ABSCore.LibraryItem] {
        itemsByLibrary[selectedLibraryID ?? ""] ?? displayedItems
    }

    func allKnownItems() -> [ABSCore.LibraryItem] {
        let flattened = itemsByLibrary.values.flatMap { $0 } + displayedItems
        let deduped = Dictionary(grouping: flattened, by: \.id).compactMap { $0.value.first }
        return deduped
    }

    func describeError(_ error: Error) -> String {
        describe(error)
    }

    func resolvePlaybackPosition(
        itemID: String,
        localPosition: TimeInterval,
        durationSeconds: TimeInterval?
    ) async -> TimeInterval {
        guard let syncEngine else {
            return max(0, localPosition)
        }

        do {
            beginSyncOperation()
            defer { endSyncOperation() }

            _ = try await syncEngine.sync(itemID: itemID, conflictResolver: Self.resolveConflict)
            lastProgressSyncAt = Date()
            if let resolved = await syncEngine.localProgress(itemID: itemID)?.positionSeconds, resolved > 0 {
                return max(0, resolved)
            }

            // If server has no progress yet, seed from local cache and push once.
            if localPosition > 0 {
                _ = try await syncEngine.recordProgress(
                    itemID: itemID,
                    positionSeconds: max(0, localPosition),
                    durationSeconds: durationSeconds,
                    trigger: .manual
                )
                _ = try await syncEngine.sync(itemID: itemID, conflictResolver: Self.resolveConflict)
                lastProgressSyncAt = Date()
                if let resolved = await syncEngine.localProgress(itemID: itemID)?.positionSeconds {
                    return max(0, resolved)
                }
            }
        } catch {
            // Leave local position unchanged when sync is unavailable.
        }

        return max(0, localPosition)
    }

    @discardableResult
    func recordPlaybackProgress(
        itemID: String,
        positionSeconds: TimeInterval,
        durationSeconds: TimeInterval?,
        trigger: ProgressUpdateTrigger
    ) async -> TimeInterval? {
        guard let syncEngine else { return nil }

        do {
            let shouldSync = try await syncEngine.recordProgress(
                itemID: itemID,
                positionSeconds: max(0, positionSeconds),
                durationSeconds: durationSeconds,
                trigger: trigger
            )

            if shouldSync || trigger != .periodic {
                beginSyncOperation()
                defer { endSyncOperation() }
                _ = try await syncEngine.sync(itemID: itemID, conflictResolver: Self.resolveConflict)
                lastProgressSyncAt = Date()
            }

            return await syncEngine.localProgress(itemID: itemID)?.positionSeconds
        } catch {
            return nil
        }
    }

    @discardableResult
    func downloadProgressFromServer(
        itemID: String,
        localPosition: TimeInterval,
        durationSeconds: TimeInterval?
    ) async -> TimeInterval? {
        guard let syncEngine else { return nil }

        do {
            if localPosition > 0 {
                _ = try await syncEngine.recordProgress(
                    itemID: itemID,
                    positionSeconds: localPosition,
                    durationSeconds: durationSeconds,
                    trigger: .manual
                )
            }

            beginSyncOperation()
            defer { endSyncOperation() }
            _ = try await syncEngine.sync(itemID: itemID, conflictResolver: { _ in .useRemote })
            lastProgressSyncAt = Date()
            return await syncEngine.localProgress(itemID: itemID)?.positionSeconds
        } catch {
            return nil
        }
    }

    @discardableResult
    func uploadProgressToServer(
        itemID: String,
        positionSeconds: TimeInterval,
        durationSeconds: TimeInterval?
    ) async -> TimeInterval? {
        guard let syncEngine else { return nil }

        do {
            _ = try await syncEngine.recordProgress(
                itemID: itemID,
                positionSeconds: max(0, positionSeconds),
                durationSeconds: durationSeconds,
                trigger: .manual
            )

            beginSyncOperation()
            defer { endSyncOperation() }
            _ = try await syncEngine.sync(itemID: itemID, conflictResolver: { _ in .useLocal })
            lastProgressSyncAt = Date()
            return await syncEngine.localProgress(itemID: itemID)?.positionSeconds
        } catch {
            return nil
        }
    }

    func setPlayedState(
        itemID: String,
        isPlayed: Bool,
        durationSeconds: TimeInterval?,
        currentPositionSeconds: TimeInterval
    ) async -> PlaybackProgress? {
        guard let apiClient else { return nil }

        let safeCurrent = max(0, currentPositionSeconds)
        let safeDuration = (durationSeconds ?? 0) > 0 ? durationSeconds : nil
        let targetPosition: TimeInterval = {
            if isPlayed {
                if let safeDuration {
                    return max(safeCurrent, safeDuration)
                }
                return max(safeCurrent, 1)
            }
            return 0
        }()

        do {
            beginSyncOperation()
            defer { endSyncOperation() }

            let pushed = try await apiClient.pushProgress(
                itemID: itemID,
                positionSeconds: targetPosition,
                durationSeconds: safeDuration,
                isFinishedOverride: isPlayed
            )

            if let syncEngine {
                _ = try await syncEngine.recordProgress(
                    itemID: itemID,
                    positionSeconds: pushed.positionSeconds,
                    durationSeconds: pushed.durationSeconds ?? safeDuration,
                    trigger: .manual
                )
                _ = try await syncEngine.sync(itemID: itemID, conflictResolver: { _ in .useLocal })
            }

            lastProgressSyncAt = Date()
            return pushed
        } catch {
            return nil
        }
    }

    func fetchProgress(itemID: String) async throws -> PlaybackProgress? {
        guard let apiClient else { return nil }
        return try await apiClient.fetchProgress(itemID: itemID)
    }

    private func loadItems(for libraryID: String) async throws {
        guard let apiClient else { return }

        if let cached = itemsByLibrary[libraryID] {
            displayedItems = cached
            return
        }

        let items = try await apiClient.items(in: libraryID)
        itemsByLibrary[libraryID] = items
        displayedItems = items
    }

    private func uniqueDestinationURL(in directory: URL, itemID: String, remoteURL: URL) -> URL {
        let ext = remoteURL.pathExtension.isEmpty ? "m4b" : remoteURL.pathExtension
        let fallbackName = "book-\(itemID)"
        let title = item(withID: itemID)?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = sanitizedFileName((title?.isEmpty == false ? title! : fallbackName))

        var candidate = directory.appendingPathComponent("\(baseName).\(ext)")
        var attempt = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(attempt).\(ext)")
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

    private func mergeDetailedItem(_ detailed: ABSCore.LibraryItem) {
        for key in itemsByLibrary.keys {
            guard let idx = itemsByLibrary[key]?.firstIndex(where: { $0.id == detailed.id }) else { continue }
            guard let existing = itemsByLibrary[key]?[idx] else { continue }
            itemsByLibrary[key]?[idx] = mergedLibraryItem(existing: existing, incoming: detailed)
        }

        if let idx = displayedItems.firstIndex(where: { $0.id == detailed.id }) {
            let existing = displayedItems[idx]
            displayedItems[idx] = mergedLibraryItem(existing: existing, incoming: detailed)
        }
    }

    private func mergeSearchResultsPreservingKnownFields(
        _ results: [ABSCore.LibraryItem],
        baseItems: [ABSCore.LibraryItem]
    ) -> [ABSCore.LibraryItem] {
        var baseByID: [String: ABSCore.LibraryItem] = [:]
        for item in baseItems {
            baseByID[item.id] = item
        }

        return results.map { incoming in
            if let existing = baseByID[incoming.id] ?? item(withID: incoming.id) {
                return mergedLibraryItem(existing: existing, incoming: incoming)
            }
            return incoming
        }
    }

    private func mergedLibraryItem(existing: ABSCore.LibraryItem, incoming: ABSCore.LibraryItem) -> ABSCore.LibraryItem {
        let incomingTitle = incoming.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasIncomingTitle = !incomingTitle.isEmpty && incomingTitle != "Unknown Title"

        let incomingAuthor = incoming.author?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasIncomingAuthor = (incomingAuthor?.isEmpty == false)

        let incomingNarrator = incoming.narrator?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasIncomingNarrator = (incomingNarrator?.isEmpty == false)

        let incomingSeries = incoming.seriesName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasIncomingSeries = (incomingSeries?.isEmpty == false)
        let incomingBlurb = incoming.blurb?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasIncomingBlurb = (incomingBlurb?.isEmpty == false)
        let incomingPublisher = incoming.publisher?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasIncomingPublisher = (incomingPublisher?.isEmpty == false)
        let incomingLanguage = incoming.language?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasIncomingLanguage = (incomingLanguage?.isEmpty == false)

        return ABSCore.LibraryItem(
            id: existing.id,
            title: hasIncomingTitle ? incomingTitle : existing.title,
            author: hasIncomingAuthor ? incomingAuthor : existing.author,
            authors: incoming.authors.isEmpty ? existing.authors : incoming.authors,
            narrator: hasIncomingNarrator ? incomingNarrator : existing.narrator,
            seriesName: hasIncomingSeries ? incomingSeries : existing.seriesName,
            seriesSequence: incoming.seriesSequence ?? existing.seriesSequence,
            collections: incoming.collections.isEmpty ? existing.collections : incoming.collections,
            genres: incoming.genres.isEmpty ? existing.genres : incoming.genres,
            tags: incoming.tags.isEmpty ? existing.tags : incoming.tags,
            blurb: hasIncomingBlurb ? incomingBlurb : existing.blurb,
            publisher: hasIncomingPublisher ? incomingPublisher : existing.publisher,
            publishedYear: incoming.publishedYear ?? existing.publishedYear,
            language: hasIncomingLanguage ? incomingLanguage : existing.language,
            libraryID: incoming.libraryID.isEmpty ? existing.libraryID : incoming.libraryID,
            duration: (incoming.duration ?? 0) > 0 ? incoming.duration : existing.duration,
            chapters: incoming.chapters.isEmpty ? existing.chapters : incoming.chapters
        )
    }

    private func initializeClientFromSavedServer() async {
        guard let url = composedServerURL() else { return }

        do {
            let client = try await ABSAPIClient(baseURL: url, secureStore: secureStore)
            apiClient = client
            try await configureSyncEngine()
            await updateLiveTransportProbe(using: client)

            if await client.hasPersistedLogin() {
                isAuthenticated = true
                try await reloadLibraries()
            }
        } catch {
            isAuthenticated = false
            liveTransportProbe = nil
        }
    }

    private func configureSyncEngine() async throws {
        guard let apiClient else {
            syncEngine = nil
            return
        }

        syncEngine = try SyncEngine(
            remote: APIProgressRemote(client: apiClient),
            connectivity: AlwaysOnlineConnectivity(),
            configuration: SyncConfiguration(periodicUpdateInterval: 15, conflictThreshold: 30)
        )
    }

    private func updateLiveTransportProbe(using client: ABSAPIClient) async {
        liveTransportProbe = await client.probeLiveTransportSupport()
    }

    private nonisolated static func resolveConflict(_ conflict: SyncConflict) -> SyncConflictResolution {
        conflict.local.updatedAt >= conflict.remote.updatedAt ? .useLocal : .useRemote
    }

    private func beginSyncOperation() {
        syncOperationCount += 1
        isProgressSyncing = true
    }

    private func endSyncOperation() {
        syncOperationCount = max(0, syncOperationCount - 1)
        isProgressSyncing = syncOperationCount > 0
    }

    private func composedServerURL() -> URL? {
        let trimmedHost = serverHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.isEmpty {
            return nil
        }

        let trimmedPort = serverPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        let port: Int
        if trimmedPort.isEmpty {
            port = defaultABSPort
        } else {
            guard let parsedPort = Int(trimmedPort), (1...65535).contains(parsedPort) else {
                return nil
            }
            port = parsedPort
        }

        var host = trimmedHost
        var scheme = serverScheme
        if host.contains("://"), let parsed = URLComponents(string: host) {
            if let parsedScheme = parsed.scheme?.lowercased(), parsedScheme == "http" || parsedScheme == "https" {
                scheme = parsedScheme
            }
            if let parsedHost = parsed.host, !parsedHost.isEmpty {
                host = parsedHost
            }
        }

        if host.contains(":") && !host.contains("]") && !host.contains("[") {
            let segments = host.split(separator: ":", omittingEmptySubsequences: false)
            if segments.count == 2, let inlinePort = Int(segments[1]), (1...65535).contains(inlinePort) {
                host = String(segments[0])
                if trimmedPort.isEmpty {
                    return buildURL(scheme: scheme, host: host, port: inlinePort)
                }
            }
        }

        return buildURL(scheme: scheme, host: host, port: port)
    }

    private func buildURL(scheme: String, host: String, port: Int) -> URL? {
        let normalizedScheme = (scheme.lowercased() == "https") ? "https" : "http"
        var components = URLComponents()
        components.scheme = normalizedScheme
        components.host = host
        components.port = port
        components.path = "/"
        return components.url
    }

    private func applyServerAddress(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let parsed = URLComponents(string: trimmed), parsed.host != nil {
            let parsedScheme = parsed.scheme?.lowercased() ?? "http"
            serverScheme = (parsedScheme == "https") ? "https" : "http"
            serverHost = parsed.host ?? ""
            if let parsedPort = parsed.port {
                serverPortText = String(parsedPort)
            } else {
                serverPortText = String(defaultABSPort)
            }
            return
        }

        var candidate = trimmed
        if !candidate.contains("://") {
            candidate = "http://\(candidate)"
        }

        guard let parsed = URLComponents(string: candidate), parsed.host != nil else {
            serverHost = trimmed
            serverPortText = String(defaultABSPort)
            return
        }

        let parsedScheme = parsed.scheme?.lowercased() ?? "http"
        serverScheme = (parsedScheme == "https") ? "https" : "http"
        serverHost = parsed.host ?? trimmed
        if let parsedPort = parsed.port {
            serverPortText = String(parsedPort)
        } else {
            serverPortText = String(defaultABSPort)
        }
    }

    private func describe(_ error: Error) -> String {
        if let apiError = error as? APIError {
            switch apiError {
            case .invalidURL:
                return "Invalid URL"
            case .invalidResponse:
                return "Invalid server response"
            case .unauthorized:
                return "Unauthorized (check credentials)"
            case .requestFailed(let statusCode):
                return "Request failed with status \(statusCode)"
            case .decodeFailure:
                return "Unexpected response format from server"
            }
        }

        if let authError = error as? AuthenticationError {
            switch authError {
            case .missingSession:
                return "Missing session configuration"
            case .tokenExpired:
                return "Session expired"
            case .invalidCredentials:
                return "Invalid username or password"
            case .reauthenticationUnavailable:
                return "Reauthentication unavailable"
            case .networkFailure(let message):
                return "Network failure: \(message)"
            }
        }

        return error.localizedDescription
    }
}

private struct APIProgressRemote: ProgressRemoteSyncing {
    let client: ABSAPIClient

    func fetchProgress(itemID: String) async throws -> PlaybackProgress? {
        try await client.fetchProgress(itemID: itemID)
    }

    func pushProgress(_ progress: PlaybackProgress) async throws {
        _ = try await client.pushProgress(
            itemID: progress.itemID,
            positionSeconds: progress.positionSeconds,
            durationSeconds: progress.durationSeconds
        )
    }
}

private struct AlwaysOnlineConnectivity: ConnectivityChecking {
    func isOnline() async -> Bool { true }
}
