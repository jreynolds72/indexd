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

            persistedItems.append(
                PersistedItem(
                    item: item,
                    primaryFilePath: primary.path,
                    coverData: metadata.coverData
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
        ABSCore.LibraryItem(
            id: existing.id,
            title: shouldReplaceScalar(existing.title) ? candidate.title : existing.title,
            author: mergeScalar(existing.author, fallback: candidate.authors.first),
            authors: mergeArray(existing.authors, fallback: candidate.authors),
            narrator: mergeScalar(existing.narrator, fallback: candidate.narrator),
            seriesName: mergeScalar(existing.seriesName, fallback: candidate.seriesName),
            seriesSequence: existing.seriesSequence ?? candidate.seriesSequence,
            collections: mergeArray(existing.collections, fallback: candidate.collections),
            genres: mergeArray(existing.genres, fallback: candidate.genres),
            tags: mergeArray(existing.tags, fallback: candidate.tags),
            blurb: mergeScalar(existing.blurb, fallback: candidate.blurb),
            publisher: mergeScalar(existing.publisher, fallback: candidate.publisher),
            publishedYear: existing.publishedYear ?? candidate.publishedYear,
            language: mergeScalar(existing.language, fallback: candidate.language),
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
}
