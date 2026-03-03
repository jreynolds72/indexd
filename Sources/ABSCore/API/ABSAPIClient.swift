import Foundation
import os

public actor ABSAPIClient {
    private let logger = Logger(subsystem: "indexd", category: "API")
    private let baseURL: URL
    private let httpClient: HTTPClient
    private let authSession: AuthSession
    private let decoder = JSONDecoder()

    public init(baseURL: URL, httpClient: HTTPClient = URLSessionHTTPClient(), secureStore: SecureStoring = KeychainSecureStore()) async throws {
        self.baseURL = baseURL
        self.httpClient = httpClient

        let authService = ABSAuthService(httpClient: httpClient)
        self.authSession = AuthSession(secureStore: secureStore, authService: authService)
        try await authSession.configure(serverURL: baseURL)
    }

    public func signIn(username: String, password: String) async throws {
        try await authSession.login(username: username, password: password)
    }

    public func hasPersistedLogin() async -> Bool {
        await authSession.hasPersistedLogin()
    }

    public func signOut() async throws {
        try await authSession.clear()
    }

    public func libraries() async throws -> [Library] {
        let data = try await authenticatedGET(path: "api/libraries")

        struct Wrapper: Decodable {
            let libraries: [LibraryDTO]
        }

        if let wrapper = try? decoder.decode(Wrapper.self, from: data) {
            return wrapper.libraries.map { $0.toDomain() }
        }

        if let direct = try? decoder.decode([LibraryDTO].self, from: data) {
            return direct.map { $0.toDomain() }
        }

        logger.error("Failed to decode libraries payload: \(self.debugPayload(data), privacy: .public)")

        throw APIError.decodeFailure
    }

    public func items(in libraryID: String) async throws -> [LibraryItem] {
        let data = try await authenticatedGET(path: "api/libraries/\(libraryID)/items")

        struct Wrapper: Decodable {
            let items: [LibraryItemDTO]
        }

        struct ResultsWrapper: Decodable {
            let results: [LibraryItemDTO]
        }

        struct LibraryItemsWrapper: Decodable {
            let libraryItems: [LibraryItemDTO]
        }

        if let wrapper = try? decoder.decode(Wrapper.self, from: data) {
            return wrapper.items.map { $0.toDomain(libraryID: libraryID) }
        }

        if let direct = try? decoder.decode([LibraryItemDTO].self, from: data) {
            return direct.map { $0.toDomain(libraryID: libraryID) }
        }

        if let wrapper = try? decoder.decode(ResultsWrapper.self, from: data) {
            return wrapper.results.map { $0.toDomain(libraryID: libraryID) }
        }

        if let wrapper = try? decoder.decode(LibraryItemsWrapper.self, from: data) {
            return wrapper.libraryItems.map { $0.toDomain(libraryID: libraryID) }
        }

        logger.error("Failed to decode items payload for library \(libraryID, privacy: .public): \(self.debugPayload(data), privacy: .public)")

        throw APIError.decodeFailure
    }

    public func search(query: String, in libraryID: String? = nil) async throws -> [LibraryItem] {
        if let libraryID, let results = try await searchInLibrary(query: query, libraryID: libraryID) {
            return results
        }

        // Fallback for older/alternate server routes.
        var fallback = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        fallback?.path = "/api/search/items"
        var queryItems = [URLQueryItem(name: "q", value: query)]
        if let libraryID {
            queryItems.append(URLQueryItem(name: "library", value: libraryID))
        }
        fallback?.queryItems = queryItems

        guard let fallbackURL = fallback?.url else {
            throw APIError.invalidURL
        }

        let data = try await authenticatedGET(url: fallbackURL)

        struct Wrapper: Decodable {
            let results: [LibraryItemDTO]
        }

        if let wrapper = try? decoder.decode(Wrapper.self, from: data) {
            return wrapper.results.map { $0.toDomain(libraryID: libraryID ?? "") }
        }

        if let direct = try? decoder.decode([LibraryItemDTO].self, from: data) {
            return direct.map { $0.toDomain(libraryID: libraryID ?? "") }
        }

        logger.error("Failed to decode search payload: \(self.debugPayload(data), privacy: .public)")
        throw APIError.decodeFailure
    }

    public func itemDetails(itemID: String, fallbackLibraryID: String? = nil) async throws -> LibraryItem {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/api/items/\(itemID)"
        components?.queryItems = [URLQueryItem(name: "expanded", value: "1")]
        guard let url = components?.url else {
            throw APIError.invalidURL
        }

        let data = try await authenticatedGET(url: url)

        struct Wrapper: Decodable {
            let libraryItem: LibraryItemDTO?
            let item: LibraryItemDTO?
        }

        if let wrapped = try? decoder.decode(Wrapper.self, from: data),
           let dto = wrapped.libraryItem ?? wrapped.item {
            return dto.toDomain(libraryID: fallbackLibraryID ?? "")
        }

        if let direct = try? decoder.decode(LibraryItemDTO.self, from: data) {
            return direct.toDomain(libraryID: fallbackLibraryID ?? "")
        }

        logger.error("Failed to decode item details for \(itemID, privacy: .public): \(self.debugPayload(data), privacy: .public)")
        throw APIError.decodeFailure
    }

    public func streamURL(for itemID: String) async throws -> URL {
        let token = try await authSession.accessToken()

        if let fromItemDetails = try await streamURLFromItemDetails(itemID: itemID, token: token) {
            return fromItemDetails
        }

        if let fromPlaybackSession = try await streamURLFromPlaybackSession(itemID: itemID, token: token) {
            return fromPlaybackSession
        }

        throw APIError.decodeFailure
    }

    public func playbackChapters(itemID: String) async throws -> [Chapter] {
        var request = URLRequest(url: baseURL.appending(path: "api/items/\(itemID)/play"))
        request.httpMethod = "POST"

        let data = try await sendAuthenticated(request)
        guard let payload = try? decoder.decode(PlaybackSessionDTO.self, from: data) else {
            throw APIError.decodeFailure
        }

        return (payload.chapters ?? []).enumerated().map { index, chapter in
            Chapter(
                id: chapter.id ?? "play-\(index)",
                title: chapter.title ?? "Chapter \(index + 1)",
                startTime: chapter.start ?? 0,
                endTime: chapter.end
            )
        }
    }

    public func coverData(for itemID: String) async throws -> Data {
        // ABS serves item artwork from this endpoint.
        try await authenticatedGET(path: "api/items/\(itemID)/cover")
    }

    public func fetchProgress(itemID: String) async throws -> PlaybackProgress? {
        do {
            let data = try await authenticatedGET(path: "api/me/progress/\(itemID)")
            if data.isEmpty {
                return nil
            }

            struct Wrapper: Decodable {
                let mediaProgress: MediaProgressDTO?
                let userMediaProgress: MediaProgressDTO?
            }

            if let wrapped = try? decoder.decode(Wrapper.self, from: data),
               let dto = wrapped.mediaProgress ?? wrapped.userMediaProgress {
                return dto.toDomain(itemID: itemID)
            }

            if let direct = try? decoder.decode(MediaProgressDTO.self, from: data) {
                return direct.toDomain(itemID: itemID)
            }

            logger.error("Failed to decode progress payload for \(itemID, privacy: .public): \(self.debugPayload(data), privacy: .public)")
            throw APIError.decodeFailure
        } catch APIError.requestFailed(statusCode: 404) {
            return nil
        }
    }

    public func pushProgress(itemID: String, positionSeconds: TimeInterval, durationSeconds: TimeInterval?) async throws -> PlaybackProgress {
        struct ProgressUpdateBody: Encodable {
            let currentTime: TimeInterval
            let duration: TimeInterval?
            let progress: Double?
            let isFinished: Bool
        }

        let safePosition = max(0, positionSeconds)
        let safeDuration: TimeInterval?
        if let durationSeconds, durationSeconds > 0 {
            safeDuration = durationSeconds
        } else {
            safeDuration = nil
        }
        let ratio = safeDuration.map { min(max(safePosition / $0, 0), 1) }

        var request = URLRequest(url: baseURL.appending(path: "api/me/progress/\(itemID)"))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ProgressUpdateBody(
                currentTime: safePosition,
                duration: safeDuration,
                progress: ratio,
                isFinished: (safeDuration.map { safePosition >= max(1, $0 - 1) }) ?? false
            )
        )

        let data = try await sendAuthenticated(request)
        if data.isEmpty {
            return PlaybackProgress(
                itemID: itemID,
                positionSeconds: safePosition,
                durationSeconds: safeDuration,
                updatedAt: Date()
            )
        }

        struct Wrapper: Decodable {
            let mediaProgress: MediaProgressDTO?
            let userMediaProgress: MediaProgressDTO?
        }

        if let wrapped = try? decoder.decode(Wrapper.self, from: data),
           let dto = wrapped.mediaProgress ?? wrapped.userMediaProgress {
            return dto.toDomain(itemID: itemID)
        }

        if let direct = try? decoder.decode(MediaProgressDTO.self, from: data) {
            return direct.toDomain(itemID: itemID)
        }

        logger.error("Failed to decode progress update response for \(itemID, privacy: .public): \(self.debugPayload(data), privacy: .public)")
        return PlaybackProgress(
            itemID: itemID,
            positionSeconds: safePosition,
            durationSeconds: safeDuration,
            updatedAt: Date()
        )
    }

    private func authenticatedGET(path: String) async throws -> Data {
        let url = baseURL.appending(path: path)
        return try await authenticatedGET(url: url)
    }

    private func authenticatedGET(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await sendAuthenticated(request)
    }

    private func sendAuthenticated(_ request: URLRequest) async throws -> Data {
        let token = try await authSession.accessToken()

        var authorized = request
        authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await httpClient.send(authorized)
        logger.debug("HTTP \(request.httpMethod ?? "GET", privacy: .public) \(request.url?.absoluteString ?? "", privacy: .public) -> \(response.statusCode)")

        if response.statusCode == 401 {
            try await authSession.reauthenticate()

            let refreshedToken = try await authSession.accessToken()
            var retried = request
            retried.setValue("Bearer \(refreshedToken)", forHTTPHeaderField: "Authorization")

            let (retriedData, retriedResponse) = try await httpClient.send(retried)
            logger.debug("HTTP retry \(request.httpMethod ?? "GET", privacy: .public) \(request.url?.absoluteString ?? "", privacy: .public) -> \(retriedResponse.statusCode)")

            guard (200..<300).contains(retriedResponse.statusCode) else {
                if retriedResponse.statusCode == 401 {
                    throw APIError.unauthorized
                }
                throw APIError.requestFailed(statusCode: retriedResponse.statusCode)
            }

            return retriedData
        }

        guard (200..<300).contains(response.statusCode) else {
            throw APIError.requestFailed(statusCode: response.statusCode)
        }

        return data
    }

    private func searchInLibrary(query: String, libraryID: String) async throws -> [LibraryItem]? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/api/libraries/\(libraryID)/search"
        components?.queryItems = [URLQueryItem(name: "q", value: query)]

        guard let url = components?.url else {
            throw APIError.invalidURL
        }

        do {
            let data = try await authenticatedGET(url: url)

            struct SearchResultItemDTO: Decodable {
                let libraryItem: LibraryItemDTO
            }

            struct SearchResponseDTO: Decodable {
                let book: [SearchResultItemDTO]?
                let podcast: [SearchResultItemDTO]?
            }

            if let wrapped = try? decoder.decode(SearchResponseDTO.self, from: data) {
                let matched = (wrapped.book ?? []) + (wrapped.podcast ?? [])
                return matched.map { $0.libraryItem.toDomain(libraryID: libraryID) }
            }

            if let direct = try? decoder.decode([LibraryItemDTO].self, from: data) {
                return direct.map { $0.toDomain(libraryID: libraryID) }
            }

            logger.error("Failed to decode library search payload: \(self.debugPayload(data), privacy: .public)")
            return nil
        } catch APIError.requestFailed(statusCode: 404) {
            logger.debug("Library search endpoint unavailable, falling back")
            return nil
        }
    }

    private func streamURLFromItemDetails(itemID: String, token: String) async throws -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/api/items/\(itemID)"
        components?.queryItems = [URLQueryItem(name: "expanded", value: "1")]
        guard let detailsURL = components?.url else {
            throw APIError.invalidURL
        }

        let data = try await authenticatedGET(url: detailsURL)
        guard let details = try? decoder.decode(ItemDetailDTO.self, from: data),
              let audioFileID = details.media?.audioFiles?.first?.ino else {
            return nil
        }

        var fileComponents = URLComponents(url: baseURL.appending(path: "api/items/\(itemID)/file/\(audioFileID)"), resolvingAgainstBaseURL: false)
        fileComponents?.queryItems = [URLQueryItem(name: "token", value: token)]
        return fileComponents?.url
    }

    private func streamURLFromPlaybackSession(itemID: String, token: String) async throws -> URL? {
        var request = URLRequest(url: baseURL.appending(path: "api/items/\(itemID)/play"))
        request.httpMethod = "POST"

        let data = try await sendAuthenticated(request)
        guard let payload = try? decoder.decode(PlaybackSessionDTO.self, from: data) else {
            return nil
        }

        let path = payload.audioTracks?.first?.contentURL
            ?? payload.audioTracks?.first?.url
            ?? payload.tracks?.first?.contentURL
            ?? payload.tracks?.first?.url

        guard let path, !path.isEmpty else {
            return nil
        }

        let resolvedURL: URL
        if let absolute = URL(string: path), absolute.scheme != nil {
            resolvedURL = absolute
        } else {
            resolvedURL = baseURL.appending(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }

        var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "token", value: token))
        components?.queryItems = items
        return components?.url
    }

    private func debugPayload(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        if text.count > 400 {
            return String(text.prefix(400)) + "..."
        }
        return text
    }
}

private struct LibraryDTO: Decodable {
    let id: String
    let name: String

    func toDomain() -> Library {
        Library(id: id, name: name)
    }
}

private struct ChapterDTO: Decodable {
    let id: String?
    let title: String
    let start: TimeInterval
    let end: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case start
        case end
        case startTime
        case endTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Chapter"
        start = try c.decodeIfPresent(TimeInterval.self, forKey: .start)
            ?? (try c.decodeIfPresent(TimeInterval.self, forKey: .startTime))
            ?? 0
        end = try c.decodeIfPresent(TimeInterval.self, forKey: .end)
            ?? (try c.decodeIfPresent(TimeInterval.self, forKey: .endTime))
    }

    func toDomain(index: Int) -> Chapter {
        Chapter(id: id ?? "chapter-\(index)", title: title, startTime: start, endTime: end)
    }
}

private struct MediaProgressDTO: Decodable {
    let currentTime: TimeInterval?
    let duration: TimeInterval?
    let progress: Double?
    let lastUpdate: Double?
    let updatedAt: Date?

    func toDomain(itemID: String) -> PlaybackProgress {
        let position: TimeInterval
        if let currentTime {
            position = max(0, currentTime)
        } else if let duration, let progress {
            position = max(0, duration * progress)
        } else {
            position = 0
        }

        let timestamp: Date
        if let updatedAt {
            timestamp = updatedAt
        } else if let lastUpdate {
            timestamp = Date(timeIntervalSince1970: lastUpdate / 1000)
        } else {
            timestamp = Date()
        }

        return PlaybackProgress(
            itemID: itemID,
            positionSeconds: position,
            durationSeconds: duration,
            updatedAt: timestamp
        )
    }
}

private struct LibraryItemDTO: Decodable {
    private struct Media: Decodable {
        struct Metadata: Decodable {
            struct NameValue: Decodable {
                let name: String?
            }

            struct Author: Decodable {
                let name: String?
            }

            struct SeriesEntry: Decodable {
                let name: String?
                let sequence: Int?

                enum CodingKeys: String, CodingKey {
                    case name
                    case sequence
                    case seq
                    case seriesSequence
                    case number
                }

                init(name: String?, sequence: Int?) {
                    self.name = name
                    self.sequence = sequence
                }

                init(from decoder: Decoder) throws {
                    if let singleValue = try? decoder.singleValueContainer(),
                       let rawName = try? singleValue.decode(String.self) {
                        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                        name = trimmed.isEmpty ? nil : trimmed
                        sequence = LibraryItemDTO.seriesSequence(fromSeriesLabel: trimmed)
                        return
                    }

                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    name = try c.decodeIfPresent(String.self, forKey: .name)
                    let decodedSequence = LibraryItemDTO.decodeFlexibleInt(from: c, keys: [.sequence, .seq, .seriesSequence, .number])
                    if let decodedSequence {
                        sequence = decodedSequence
                    } else {
                        sequence = LibraryItemDTO.seriesSequence(fromSeriesLabel: name ?? "")
                    }
                }
            }

            let title: String?
            let authorName: String?
            let authors: [Author]?
            let narratorName: String?
            let narrators: [String]
            let seriesName: String?
            let series: [SeriesEntry]
            let collections: [String]
            let genres: [String]
            let tags: [String]

            enum CodingKeys: String, CodingKey {
                case title
                case authorName
                case authors
                case narratorName
                case narrator
                case narrators
                case seriesName
                case series
                case collection
                case collections
                case genres
                case tags
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
                authorName = (try? c.decodeIfPresent(String.self, forKey: .authorName)) ?? nil
                authors = (try? c.decodeIfPresent([Author].self, forKey: .authors)) ?? nil

                let directNarrator = (try? c.decodeIfPresent(String.self, forKey: .narrator)) ?? nil
                narratorName = (try? c.decodeIfPresent(String.self, forKey: .narratorName)) ?? nil ?? directNarrator
                let narratorStrings = (try? c.decodeIfPresent([String].self, forKey: .narrators)) ?? nil ?? []
                let narratorObjects = ((try? c.decodeIfPresent([NameValue].self, forKey: .narrators)) ?? nil ?? []).compactMap(\.name)
                narrators = Array(Set((narratorStrings + narratorObjects).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()

                seriesName = (try? c.decodeIfPresent(String.self, forKey: .seriesName)) ?? nil
                let parsedSeries = (try? c.decodeIfPresent([SeriesEntry].self, forKey: .series)) ?? nil ?? []
                let stringSeries = ((try? c.decodeIfPresent([String].self, forKey: .series)) ?? nil ?? [])
                    .map { raw in
                        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        return SeriesEntry(name: trimmed.isEmpty ? nil : trimmed, sequence: LibraryItemDTO.seriesSequence(fromSeriesLabel: trimmed))
                    }
                series = parsedSeries + stringSeries

                let oneCollection = ((try? c.decodeIfPresent(String.self, forKey: .collection)) ?? nil).map { [$0] } ?? []
                collections = LibraryItemDTO.cleanStringArray(
                    oneCollection
                    + ((try? c.decodeIfPresent([String].self, forKey: .collections)) ?? nil ?? [])
                    + (((try? c.decodeIfPresent([NameValue].self, forKey: .collections)) ?? nil ?? []).compactMap(\.name))
                )
                genres = LibraryItemDTO.cleanStringArray(
                    ((try? c.decodeIfPresent([String].self, forKey: .genres)) ?? nil ?? [])
                    + (((try? c.decodeIfPresent([NameValue].self, forKey: .genres)) ?? nil ?? []).compactMap(\.name))
                )
                tags = LibraryItemDTO.cleanStringArray(
                    ((try? c.decodeIfPresent([String].self, forKey: .tags)) ?? nil ?? [])
                    + (((try? c.decodeIfPresent([NameValue].self, forKey: .tags)) ?? nil ?? []).compactMap(\.name))
                )
            }
        }

        let duration: TimeInterval?
        let chapters: [ChapterDTO]?
        let metadata: Metadata?
    }

    let id: String
    let title: String
    let author: String?
    let authors: [String]
    let narrator: String?
    let seriesName: String?
    let seriesSequence: Int?
    let collections: [String]
    let genres: [String]
    let tags: [String]
    let duration: TimeInterval?
    let chapters: [ChapterDTO]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case author
        case narrator
        case narratorName
        case seriesName
        case seriesSequence
        case sequence
        case collections
        case genres
        case tags
        case duration
        case chapters
        case media
        case mediaMetadata
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let media = (try? c.decodeIfPresent(Media.self, forKey: .media)) ?? nil
        let mediaMetadata = (try? c.decodeIfPresent(Media.Metadata.self, forKey: .mediaMetadata)) ?? nil
        let metadata = media?.metadata ?? mediaMetadata

        id = try c.decode(String.self, forKey: .id)
        title = ((try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil)
            ?? metadata?.title
            ?? "Unknown Title"
        author = ((try? c.decodeIfPresent(String.self, forKey: .author)) ?? nil)
            ?? metadata?.authorName
            ?? metadata?.authors?.compactMap(\.name).joined(separator: ", ")
        let metadataAuthors = metadata?.authors?.compactMap(\.name) ?? []
        authors = Self.normalizedPeopleNames(
            !metadataAuthors.isEmpty ? metadataAuthors : Self.splitPeopleNames(from: author)
        )
        let directNarrator = (try? c.decodeIfPresent(String.self, forKey: .narrator)) ?? nil
        let narratorName = (try? c.decodeIfPresent(String.self, forKey: .narratorName)) ?? nil
        narrator = directNarrator
            ?? narratorName
            ?? metadata?.narratorName
            ?? metadata?.narrators.first
        let rootSeriesSequence = Self.decodeFlexibleInt(
            from: c,
            keys: [.seriesSequence, .sequence]
        )
        let metadataSeriesName = metadata?.seriesName
            ?? metadata?.series.first(where: { ($0.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false })?.name
        seriesName = ((try? c.decodeIfPresent(String.self, forKey: .seriesName)) ?? nil) ?? metadataSeriesName
        seriesSequence = rootSeriesSequence
            ?? metadata?.series.first(where: { $0.sequence != nil })?.sequence
            ?? Self.seriesSequence(fromSeriesLabel: seriesName ?? "")
        collections = Self.cleanStringArray(
            ((try? c.decodeIfPresent([String].self, forKey: .collections)) ?? nil ?? [])
            + (metadata?.collections ?? [])
        )
        genres = Self.cleanStringArray(
            ((try? c.decodeIfPresent([String].self, forKey: .genres)) ?? nil ?? [])
            + (metadata?.genres ?? [])
        )
        tags = Self.cleanStringArray(
            ((try? c.decodeIfPresent([String].self, forKey: .tags)) ?? nil ?? [])
            + (metadata?.tags ?? [])
        )
        duration = ((try? c.decodeIfPresent(TimeInterval.self, forKey: .duration)) ?? nil)
            ?? media?.duration
        chapters = ((try? c.decodeIfPresent([ChapterDTO].self, forKey: .chapters)) ?? nil)
            ?? media?.chapters
    }

    func toDomain(libraryID: String) -> LibraryItem {
        let mappedChapters = (chapters ?? []).enumerated().map { index, chapter in
            chapter.toDomain(index: index)
        }

        return LibraryItem(
            id: id,
            title: title,
            author: author,
            authors: authors,
            narrator: narrator,
            seriesName: seriesName,
            seriesSequence: seriesSequence,
            collections: collections,
            genres: genres,
            tags: tags,
            libraryID: libraryID,
            duration: duration,
            chapters: mappedChapters
        )
    }

    private static func cleanStringArray(_ values: [String]) -> [String] {
        let normalized = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(normalized)).sorted()
    }

    private static func splitPeopleNames(from raw: String?) -> [String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        // Covers common ABS author formatting:
        // "A, B", "A & B", "A and B", "A; B".
        let normalized = raw
            .replacingOccurrences(of: " & ", with: ",")
            .replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: ";", with: ",")
        return normalized.components(separatedBy: ",")
    }

    private static func normalizedPeopleNames(_ values: [String]) -> [String] {
        let cleaned = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(cleaned)).sorted()
    }

    private static func decodeFlexibleInt<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        keys: [Key]
    ) -> Int? {
        for key in keys {
            if let value = (try? container.decodeIfPresent(Int.self, forKey: key)) ?? nil {
                return value
            }
            if let value = (try? container.decodeIfPresent(Double.self, forKey: key)) ?? nil {
                return Int(value)
            }
            if let value = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let intValue = Int(trimmed) {
                    return intValue
                }
            }
        }
        return nil
    }

    private static func seriesSequence(fromSeriesLabel label: String) -> Int? {
        let patterns = [
            #"(?i)#\s*(\d+)\b"#,
            #"(?i)\bbook\s*(\d+)\b"#,
            #"(?i)\bpart\s*(\d+)\b"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(label.startIndex..<label.endIndex, in: label)
            if let match = regex.firstMatch(in: label, options: [], range: range), match.numberOfRanges > 1,
               let numberRange = Range(match.range(at: 1), in: label),
               let number = Int(label[numberRange]) {
                return number
            }
        }
        return nil
    }
}

private struct ItemDetailDTO: Decodable {
    struct Media: Decodable {
        struct AudioFile: Decodable {
            let ino: String?
            let id: String?
        }

        let audioFiles: [AudioFile]?
    }

    let media: Media?
}

private struct PlaybackSessionDTO: Decodable {
    struct AudioTrack: Decodable {
        let contentURL: String?
        let url: String?

        enum CodingKeys: String, CodingKey {
            case contentURL = "contentUrl"
            case url
        }
    }

    struct ChapterDTO: Decodable {
        let id: String?
        let title: String?
        let start: TimeInterval?
        let end: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case start
            case end
            case startTime
            case endTime
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            start = try c.decodeIfPresent(TimeInterval.self, forKey: .start)
                ?? (try c.decodeIfPresent(TimeInterval.self, forKey: .startTime))
            end = try c.decodeIfPresent(TimeInterval.self, forKey: .end)
                ?? (try c.decodeIfPresent(TimeInterval.self, forKey: .endTime))
        }
    }

    let audioTracks: [AudioTrack]?
    let tracks: [AudioTrack]?
    let chapters: [ChapterDTO]?
}
