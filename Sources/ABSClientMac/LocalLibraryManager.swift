import Foundation
import AVFoundation
import CryptoKit
import ABSCore

struct LocalLibraryRoot: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let directoryURL: URL
    let addedAt: Date
    let lastScannedAt: Date?
}

struct LocalLibraryIndexSnapshot: Sendable {
    let roots: [LocalLibraryRoot]
    let libraries: [ABSCore.Library]
    let itemsByLibrary: [String: [ABSCore.LibraryItem]]
    let fileURLByItemID: [String: URL]
    let coverDataByItemID: [String: Data]
}

actor LocalLibraryManager {
    static let libraryIDPrefix = "local:"

    private struct PersistedRoot: Codable {
        let id: String
        let name: String
        let directoryPath: String
        let addedAt: Date
        var lastScannedAt: Date?
    }

    private struct PersistedItem: Codable {
        let item: ABSCore.LibraryItem
        let primaryFilePath: String
        let coverData: Data?
    }

    private struct PersistedState: Codable {
        var roots: [PersistedRoot]
        var itemsByRootID: [String: [PersistedItem]]
    }

    private struct ExtractedMetadata {
        let title: String?
        let author: String?
        let authors: [String]
        let narrator: String?
        let seriesName: String?
        let seriesSequence: Int?
        let duration: TimeInterval?
        let chapters: [ABSCore.Chapter]
        let coverData: Data?
    }

    private let fileManager: FileManager
    private let storageURL: URL
    private var state: PersistedState

    init(fileManager: FileManager = .default, storageURL: URL? = nil) {
        self.fileManager = fileManager
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let supportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.storageURL = supportRoot
                .appendingPathComponent("indexd", isDirectory: true)
                .appendingPathComponent("LocalLibraryIndex.json", isDirectory: false)
        }

        if let loaded = Self.loadState(fileManager: fileManager, storageURL: self.storageURL) {
            self.state = loaded
        } else {
            self.state = PersistedState(roots: [], itemsByRootID: [:])
        }
    }

    func roots() -> [LocalLibraryRoot] {
        state.roots
            .map {
                LocalLibraryRoot(
                    id: $0.id,
                    name: $0.name,
                    directoryURL: URL(fileURLWithPath: $0.directoryPath, isDirectory: true),
                    addedAt: $0.addedAt,
                    lastScannedAt: $0.lastScannedAt
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func snapshot() -> LocalLibraryIndexSnapshot {
        var libraries: [ABSCore.Library] = []
        var itemsByLibrary: [String: [ABSCore.LibraryItem]] = [:]
        var fileURLByItemID: [String: URL] = [:]
        var coverDataByItemID: [String: Data] = [:]

        for root in state.roots {
            let libraryID = Self.libraryIDPrefix + root.id
            libraries.append(ABSCore.Library(id: libraryID, name: root.name))

            let persistedItems = state.itemsByRootID[root.id] ?? []
            let validItems = persistedItems.filter { fileManager.fileExists(atPath: $0.primaryFilePath) }
            let items = validItems
                .map(\ .item)
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            itemsByLibrary[libraryID] = items

            for record in validItems {
                fileURLByItemID[record.item.id] = URL(fileURLWithPath: record.primaryFilePath)
                if let coverData = record.coverData {
                    coverDataByItemID[record.item.id] = coverData
                }
            }
        }

        return LocalLibraryIndexSnapshot(
            roots: roots(),
            libraries: libraries,
            itemsByLibrary: itemsByLibrary,
            fileURLByItemID: fileURLByItemID,
            coverDataByItemID: coverDataByItemID
        )
    }

    @discardableResult
    func addRoot(directoryURL: URL) async throws -> LocalLibraryRoot {
        let standardized = directoryURL.standardizedFileURL
        let existing = state.roots.first { URL(fileURLWithPath: $0.directoryPath, isDirectory: true).standardizedFileURL == standardized }
        let rootID = existing?.id ?? Self.hash(standardized.path)
        let rootName = standardized.lastPathComponent.isEmpty ? standardized.path : standardized.lastPathComponent

        let root = PersistedRoot(
            id: rootID,
            name: rootName,
            directoryPath: standardized.path,
            addedAt: existing?.addedAt ?? Date(),
            lastScannedAt: Date()
        )

        if let index = state.roots.firstIndex(where: { $0.id == rootID }) {
            state.roots[index] = root
        } else {
            state.roots.append(root)
        }

        state.itemsByRootID[rootID] = try await scanRoot(root)
        try persist()

        return LocalLibraryRoot(
            id: root.id,
            name: root.name,
            directoryURL: standardized,
            addedAt: root.addedAt,
            lastScannedAt: root.lastScannedAt
        )
    }

    func removeRoot(id: String) throws {
        state.roots.removeAll { $0.id == id }
        state.itemsByRootID.removeValue(forKey: id)
        try persist()
    }

    func rescanAll() async throws {
        var updatedRoots: [PersistedRoot] = []
        var updatedItemsByRootID: [String: [PersistedItem]] = state.itemsByRootID

        for root in state.roots {
            var refreshedRoot = root
            refreshedRoot.lastScannedAt = Date()
            updatedRoots.append(refreshedRoot)
            updatedItemsByRootID[root.id] = try await scanRoot(refreshedRoot)
        }

        state.roots = updatedRoots
        state.itemsByRootID = updatedItemsByRootID
        try persist()
    }

    func rescanRoot(id: String) async throws {
        guard let index = state.roots.firstIndex(where: { $0.id == id }) else { return }
        var root = state.roots[index]
        root.lastScannedAt = Date()
        state.roots[index] = root
        state.itemsByRootID[id] = try await scanRoot(root)
        try persist()
    }

    func items(inRoot id: String) -> [ABSCore.LibraryItem] {
        (state.itemsByRootID[id] ?? [])
            .map(\.item)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    @discardableResult
    func ingestCopiedFile(
        rootID: String,
        fileURL: URL,
        sourceItem: ABSCore.LibraryItem
    ) async throws -> Bool {
        guard state.roots.contains(where: { $0.id == rootID }) else {
            return false
        }
        let standardizedFileURL = fileURL.standardizedFileURL
        guard fileManager.fileExists(atPath: standardizedFileURL.path) else {
            return false
        }

        let metadata = await extractMetadata(from: standardizedFileURL)
        let fallbackTitle = standardizedFileURL.deletingPathExtension().lastPathComponent
        let extractedTitle = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let localLibraryID = Self.libraryIDPrefix + rootID
        let itemID = "local-item:\(Self.hash(standardizedFileURL.path))"

        let scannedBaseline = ABSCore.LibraryItem(
            id: itemID,
            title: (extractedTitle?.isEmpty == false) ? extractedTitle! : fallbackTitle,
            author: metadata.author,
            authors: metadata.authors,
            narrator: metadata.narrator,
            seriesName: metadata.seriesName,
            seriesSequence: metadata.seriesSequence,
            collections: [],
            genres: [],
            tags: [],
            blurb: nil,
            publisher: nil,
            publishedYear: nil,
            language: nil,
            libraryID: localLibraryID,
            duration: metadata.duration,
            chapters: metadata.chapters
        )

        let overlaid = ABSCore.LibraryItem(
            id: itemID,
            title: preferredTitle(primary: sourceItem.title, fallback: scannedBaseline.title),
            author: preferredScalar(sourceItem.author, fallback: scannedBaseline.author ?? sourceItem.authors.first),
            authors: sourceItem.authors.isEmpty ? scannedBaseline.authors : sourceItem.authors,
            narrator: preferredScalar(sourceItem.narrator, fallback: scannedBaseline.narrator),
            seriesName: preferredScalar(sourceItem.seriesName, fallback: scannedBaseline.seriesName),
            seriesSequence: sourceItem.seriesSequence ?? scannedBaseline.seriesSequence,
            collections: sourceItem.collections,
            genres: sourceItem.genres,
            tags: sourceItem.tags,
            blurb: preferredScalar(sourceItem.blurb, fallback: scannedBaseline.blurb),
            publisher: preferredScalar(sourceItem.publisher, fallback: scannedBaseline.publisher),
            publishedYear: sourceItem.publishedYear ?? scannedBaseline.publishedYear,
            language: preferredScalar(sourceItem.language, fallback: scannedBaseline.language),
            libraryID: localLibraryID,
            duration: sourceItem.duration ?? scannedBaseline.duration,
            chapters: sourceItem.chapters.isEmpty ? scannedBaseline.chapters : sourceItem.chapters
        )

        var items = state.itemsByRootID[rootID] ?? []
        if let index = items.firstIndex(where: { $0.primaryFilePath == standardizedFileURL.path || $0.item.id == itemID }) {
            let existing = items[index]
            let merged = mergedScannedItem(existing: existing.item, scanned: overlaid)
            items[index] = PersistedItem(
                item: merged,
                primaryFilePath: standardizedFileURL.path,
                coverData: existing.coverData ?? metadata.coverData
            )
        } else {
            items.append(
                PersistedItem(
                    item: overlaid,
                    primaryFilePath: standardizedFileURL.path,
                    coverData: metadata.coverData
                )
            )
        }

        state.itemsByRootID[rootID] = items.sorted { $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending }
        try persist()
        return true
    }

    @discardableResult
    func applyMetadataCandidate(
        rootID: String,
        itemID: String,
        candidate: MetadataMatchCandidate
    ) throws -> Bool {
        guard var items = state.itemsByRootID[rootID] else {
            return false
        }
        guard let itemIndex = items.firstIndex(where: { $0.item.id == itemID }) else {
            return false
        }

        let existing = items[itemIndex].item
        let merged = mergedItem(existing: existing, candidate: candidate)
        guard merged != existing else {
            return false
        }

        items[itemIndex] = PersistedItem(
            item: merged,
            primaryFilePath: items[itemIndex].primaryFilePath,
            coverData: items[itemIndex].coverData
        )
        state.itemsByRootID[rootID] = items
        try persist()
        return true
    }

    @discardableResult
    func updateItemMetadata(
        rootID: String,
        itemID: String,
        updatedItem: ABSCore.LibraryItem
    ) throws -> Bool {
        guard var items = state.itemsByRootID[rootID] else {
            return false
        }
        guard let itemIndex = items.firstIndex(where: { $0.item.id == itemID }) else {
            return false
        }

        let existingRecord = items[itemIndex]
        guard existingRecord.item != updatedItem else {
            return false
        }

        items[itemIndex] = PersistedItem(
            item: updatedItem,
            primaryFilePath: existingRecord.primaryFilePath,
            coverData: existingRecord.coverData
        )
        state.itemsByRootID[rootID] = items
        try persist()
        return true
    }

    @discardableResult
    func updateItemCoverData(
        rootID: String,
        itemID: String,
        coverData: Data?
    ) throws -> Bool {
        guard var items = state.itemsByRootID[rootID] else {
            return false
        }
        guard let itemIndex = items.firstIndex(where: { $0.item.id == itemID }) else {
            return false
        }

        let existingRecord = items[itemIndex]
        let existingCover = existingRecord.coverData ?? Data()
        let incomingCover = coverData ?? Data()
        guard existingCover != incomingCover else {
            return false
        }

        items[itemIndex] = PersistedItem(
            item: existingRecord.item,
            primaryFilePath: existingRecord.primaryFilePath,
            coverData: coverData
        )
        state.itemsByRootID[rootID] = items
        try persist()
        return true
    }

    private func scanRoot(_ root: PersistedRoot) async throws -> [PersistedItem] {
        let rootURL = URL(fileURLWithPath: root.directoryPath, isDirectory: true)
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return []
        }

        let audioFiles = enumerateAudioFiles(in: rootURL)
        guard !audioFiles.isEmpty else {
            return []
        }

        // Index each discovered file as its own item. Grouping by parent
        // directory can collapse multiple standalone books into one entry.
        let grouped: [String: [URL]] = Dictionary(
            uniqueKeysWithValues: audioFiles.map { ($0.path, [$0]) }
        )

        var persistedItems: [PersistedItem] = []
        let existingByPath = Dictionary(
            uniqueKeysWithValues: (state.itemsByRootID[root.id] ?? []).map { ($0.primaryFilePath, $0) }
        )

        for (groupKey, files) in grouped {
            guard let primary = files.max(by: { Self.fileSize(of: $0, fileManager: fileManager) < Self.fileSize(of: $1, fileManager: fileManager) }) else {
                continue
            }

            let metadata = await extractMetadata(from: primary)
            let fallbackTitle: String = {
                if files.count > 1 {
                    return primary.deletingLastPathComponent().lastPathComponent
                }
                return primary.deletingPathExtension().lastPathComponent
            }()

            let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = (title?.isEmpty == false) ? title! : fallbackTitle

            let itemID = "local-item:\(Self.hash(groupKey))"
            let libraryID = Self.libraryIDPrefix + root.id

            let item = ABSCore.LibraryItem(
                id: itemID,
                title: resolvedTitle,
                author: metadata.author,
                authors: metadata.authors,
                narrator: metadata.narrator,
                seriesName: metadata.seriesName,
                seriesSequence: metadata.seriesSequence,
                collections: [],
                genres: [],
                tags: [],
                blurb: nil,
                publisher: nil,
                publishedYear: nil,
                language: nil,
                libraryID: libraryID,
                duration: metadata.duration,
                chapters: metadata.chapters
            )

            let mergedItem = existingByPath[primary.path].map { existing in
                mergedScannedItem(existing: existing.item, scanned: item)
            } ?? item

            persistedItems.append(
                PersistedItem(
                    item: mergedItem,
                    primaryFilePath: primary.path,
                    coverData: existingByPath[primary.path]?.coverData ?? metadata.coverData
                )
            )
        }

        return persistedItems.sorted { $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending }
    }

    private func enumerateAudioFiles(in rootURL: URL) -> [URL] {
        let allowedExtensions: Set<String> = [
            "m4b", "m4a", "mp3", "aac", "flac", "ogg", "opus", "wav", "aiff", "aif", "aax"
        ]
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isHiddenKey]

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { continue }

            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys), values.isRegularFile == true else {
                continue
            }

            files.append(fileURL)
        }

        return files.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private func extractMetadata(from fileURL: URL) async -> ExtractedMetadata {
        let asset = AVURLAsset(url: fileURL)
        let commonMetadata = asset.commonMetadata

        let title = Self.metadataString(from: commonMetadata, identifiers: [
            .commonIdentifierTitle,
            .iTunesMetadataTrackSubTitle,
            .quickTimeMetadataDisplayName
        ])

        let author = Self.metadataString(from: commonMetadata, identifiers: [
            .commonIdentifierArtist,
            .commonIdentifierCreator,
            .iTunesMetadataArtist,
            .quickTimeMetadataAuthor
        ])

        let authors = Self.splitPeople(author)

        let narrator = Self.metadataString(from: commonMetadata, identifiers: [
            .iTunesMetadataAlbumArtist,
            .quickTimeMetadataPerformer
        ])

        let seriesRaw = Self.metadataString(from: commonMetadata, identifiers: [
            .quickTimeMetadataAlbum,
            .iTunesMetadataAlbum
        ])
        let (seriesName, seriesSequence) = Self.parseSeries(from: seriesRaw)

        let durationSeconds = asset.duration.seconds
        let duration = durationSeconds.isFinite && durationSeconds > 0 ? durationSeconds : nil

        let coverData = Self.coverData(from: commonMetadata)
        let chapters = await Self.extractChapters(from: asset)

        return ExtractedMetadata(
            title: title,
            author: author,
            authors: authors,
            narrator: narrator,
            seriesName: seriesName,
            seriesSequence: seriesSequence,
            duration: duration,
            chapters: chapters,
            coverData: coverData
        )
    }

    private func persist() throws {
        let directory = storageURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: storageURL, options: .atomic)
    }

    private static func loadState(fileManager: FileManager, storageURL: URL) -> PersistedState? {
        guard fileManager.fileExists(atPath: storageURL.path) else { return nil }
        guard let data = try? Data(contentsOf: storageURL) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    private static func metadataString(from metadata: [AVMetadataItem], identifiers: [AVMetadataIdentifier]) -> String? {
        for identifier in identifiers {
            if let value = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier)
                .first?
                .stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func coverData(from metadata: [AVMetadataItem]) -> Data? {
        if let artwork = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first,
           let data = artwork.dataValue,
           !data.isEmpty {
            return data
        }

        return nil
    }

    private static func splitPeople(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func parseSeries(from value: String?) -> (String?, Int?) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return (nil, nil)
        }

        let components = value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true)
        if components.count == 2 {
            let name = String(components[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let sequence = Int(String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines))
            return (name.isEmpty ? value : name, sequence)
        }

        let patterns: [String] = [
            // "Series Name 1: Book Title"
            #"(?i)^\s*(.+?)\s+(\d+)\s*:\s*.+$"#,
            // "Series Name, Book 1: Book Title"
            #"(?i)^\s*(.+?)\s*,\s*book\s+(\d+)\s*:\s*.+$"#,
            // "Series Name Book 1"
            #"(?i)^\s*(.+?)\s+book\s+(\d+)\s*$"#,
            // "Series Name Vol 1"
            #"(?i)^\s*(.+?)\s+vol(?:ume)?\s+(\d+)\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = regex.firstMatch(in: value, options: [], range: range), match.numberOfRanges > 2 else {
                continue
            }
            let name: String? = {
                guard let r = Range(match.range(at: 1), in: value) else { return nil }
                let parsed = value[r].trimmingCharacters(in: .whitespacesAndNewlines)
                return parsed.isEmpty ? nil : parsed
            }()
            let sequence: Int? = {
                guard let r = Range(match.range(at: 2), in: value) else { return nil }
                return Int(value[r])
            }()
            if let name {
                return (name, sequence)
            }
        }

        return (value, nil)
    }

    private static func extractChapters(from asset: AVURLAsset) async -> [ABSCore.Chapter] {
        let preferredLanguages: [String]
        if #available(macOS 12.0, *) {
            let locales = (try? await asset.load(.availableChapterLocales)) ?? []
            preferredLanguages = locales.isEmpty ? Locale.preferredLanguages : locales.map(\ .identifier)
        } else {
            preferredLanguages = Locale.preferredLanguages
        }

        let groups = asset.chapterMetadataGroups(bestMatchingPreferredLanguages: preferredLanguages)
        guard !groups.isEmpty else { return [] }

        return groups.enumerated().map { index, group in
            let titleItem = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
            let title = titleItem?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let start = group.timeRange.start.seconds
            let duration = group.timeRange.duration.seconds
            let end: TimeInterval? = duration.isFinite ? start + duration : nil

            return ABSCore.Chapter(
                id: "local-chapter-\(index)",
                title: (title?.isEmpty == false ? title! : "Chapter \(index + 1)"),
                startTime: start.isFinite ? start : 0,
                endTime: end
            )
        }
    }

    private static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func fileSize(of url: URL, fileManager: FileManager) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private func mergedItem(existing: ABSCore.LibraryItem, candidate: MetadataMatchCandidate) -> ABSCore.LibraryItem {
        let candidateTitle = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = candidateTitle.isEmpty ? existing.title : candidateTitle
        let resolvedAuthors = candidate.authors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let resolvedAuthor = resolvedAuthors.first
        let resolvedNarrator = candidate.narrator?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSeries = candidate.seriesName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCollections = normalizedList(candidate.collections)
        let resolvedGenres = normalizedList(candidate.genres)
        let resolvedTags = normalizedList(candidate.tags)
        let resolvedBlurb = candidate.blurb?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPublisher = candidate.publisher?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLanguage = candidate.language?.trimmingCharacters(in: .whitespacesAndNewlines)

        return ABSCore.LibraryItem(
            id: existing.id,
            title: resolvedTitle,
            author: resolvedAuthor,
            authors: resolvedAuthors,
            narrator: resolvedNarrator?.isEmpty == false ? resolvedNarrator : nil,
            seriesName: resolvedSeries?.isEmpty == false ? resolvedSeries : nil,
            seriesSequence: candidate.seriesSequence,
            collections: resolvedCollections,
            genres: resolvedGenres,
            tags: resolvedTags,
            blurb: resolvedBlurb?.isEmpty == false ? resolvedBlurb : nil,
            publisher: resolvedPublisher?.isEmpty == false ? resolvedPublisher : nil,
            publishedYear: candidate.publishedYear,
            language: resolvedLanguage?.isEmpty == false ? resolvedLanguage : nil,
            libraryID: existing.libraryID,
            duration: existing.duration,
            chapters: existing.chapters
        )
    }

    private func shouldReplaceScalar(_ value: String?) -> Bool {
        guard let value else { return true }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed.caseInsensitiveCompare("Unknown Title") == .orderedSame
    }

    private func mergeScalar(_ existing: String?, fallback: String?) -> String? {
        if shouldReplaceScalar(existing) {
            guard let fallback else { return existing }
            let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? existing : trimmed
        }
        return existing
    }

    private func mergeArray(_ existing: [String], fallback: [String]) -> [String] {
        var seen = Set(existing.map { $0.lowercased() })
        var merged = existing
        for raw in fallback {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if seen.insert(value.lowercased()).inserted {
                merged.append(value)
            }
        }
        return merged
    }

    private func normalizedList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in values {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    private func preferredScalar(_ primary: String?, fallback: String?) -> String? {
        if let primary, !primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return primary.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func preferredTitle(primary: String, fallback: String) -> String {
        let trimmedPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrimary.isEmpty, trimmedPrimary.caseInsensitiveCompare("Unknown Title") != .orderedSame {
            return trimmedPrimary
        }
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? "Unknown Title" : trimmedFallback
    }

    private func mergedScannedItem(existing: ABSCore.LibraryItem, scanned: ABSCore.LibraryItem) -> ABSCore.LibraryItem {
        ABSCore.LibraryItem(
            id: scanned.id,
            title: shouldReplaceScalar(existing.title) ? scanned.title : existing.title,
            author: mergeScalar(existing.author, fallback: scanned.author),
            authors: mergeArray(existing.authors, fallback: scanned.authors),
            narrator: mergeScalar(existing.narrator, fallback: scanned.narrator),
            seriesName: mergeScalar(existing.seriesName, fallback: scanned.seriesName),
            seriesSequence: existing.seriesSequence ?? scanned.seriesSequence,
            collections: mergeArray(existing.collections, fallback: scanned.collections),
            genres: mergeArray(existing.genres, fallback: scanned.genres),
            tags: mergeArray(existing.tags, fallback: scanned.tags),
            blurb: mergeScalar(existing.blurb, fallback: scanned.blurb),
            publisher: mergeScalar(existing.publisher, fallback: scanned.publisher),
            publishedYear: existing.publishedYear ?? scanned.publishedYear,
            language: mergeScalar(existing.language, fallback: scanned.language),
            libraryID: scanned.libraryID,
            duration: scanned.duration ?? existing.duration,
            chapters: scanned.chapters.isEmpty ? existing.chapters : scanned.chapters
        )
    }
}
