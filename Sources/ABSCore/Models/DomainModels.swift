import Foundation

public struct Library: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Chapter: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval?

    public init(id: String, title: String, startTime: TimeInterval, endTime: TimeInterval?) {
        self.id = id
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
    }
}

public struct LibraryItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let author: String?
    public let authors: [String]
    public let narrator: String?
    public let seriesName: String?
    public let seriesSequence: Int?
    public let collections: [String]
    public let genres: [String]
    public let tags: [String]
    public let blurb: String?
    public let publisher: String?
    public let publishedYear: Int?
    public let language: String?
    public let libraryID: String
    public let duration: TimeInterval?
    public let chapters: [Chapter]

    public init(
        id: String,
        title: String,
        author: String?,
        authors: [String] = [],
        narrator: String? = nil,
        seriesName: String? = nil,
        seriesSequence: Int? = nil,
        collections: [String] = [],
        genres: [String] = [],
        tags: [String] = [],
        blurb: String? = nil,
        publisher: String? = nil,
        publishedYear: Int? = nil,
        language: String? = nil,
        libraryID: String,
        duration: TimeInterval?,
        chapters: [Chapter]
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.authors = authors
        self.narrator = narrator
        self.seriesName = seriesName
        self.seriesSequence = seriesSequence
        self.collections = collections
        self.genres = genres
        self.tags = tags
        self.blurb = blurb
        self.publisher = publisher
        self.publishedYear = publishedYear
        self.language = language
        self.libraryID = libraryID
        self.duration = duration
        self.chapters = chapters
    }
}

public struct PlaybackProgress: Codable, Equatable, Sendable {
    public let itemID: String
    public let positionSeconds: TimeInterval
    public let durationSeconds: TimeInterval?
    public let isFinished: Bool?
    public let updatedAt: Date

    public init(
        itemID: String,
        positionSeconds: TimeInterval,
        durationSeconds: TimeInterval? = nil,
        isFinished: Bool? = nil,
        updatedAt: Date
    ) {
        self.itemID = itemID
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.isFinished = isFinished
        self.updatedAt = updatedAt
    }
}

public enum DownloadState: String, Codable, Equatable, Sendable {
    case notDownloaded
    case downloading
    case downloaded
}
