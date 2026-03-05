import Foundation
import ABSCore

struct MetadataMatchCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let source: String
    let sourceID: String?
    let confidence: Double
    let confidenceReason: String
    let title: String
    let authors: [String]
    let narrator: String?
    let seriesName: String?
    let seriesSequence: Int?
    let collections: [String]
    let genres: [String]
    let tags: [String]
    let blurb: String?
    let publisher: String?
    let publishedYear: Int?
    let language: String?
}

actor OpenLibraryMetadataMatcher {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func match(for item: ABSCore.LibraryItem, limit: Int = 5) async throws -> [MetadataMatchCandidate] {
        let queryTitle = normalizedQueryTitle(item.title)
        guard !queryTitle.isEmpty else { return [] }

        let localAuthors = localAuthorList(from: item)
        let perQueryLimit = max(1, min(limit * 3, 30))

        let querySets: [[URLQueryItem]] = [
            [
                URLQueryItem(name: "title", value: queryTitle),
                URLQueryItem(name: "author", value: localAuthors.first),
                URLQueryItem(name: "limit", value: String(perQueryLimit))
            ].compactMap { $0 },
            [
                URLQueryItem(name: "q", value: [queryTitle, localAuthors.first].compactMap { $0 }.joined(separator: " ")),
                URLQueryItem(name: "limit", value: String(perQueryLimit))
            ]
        ]

        var mergedDocuments: [OpenLibrarySearchResponse.Document] = []
        var seenDocumentKeys = Set<String>()
        for queryItems in querySets {
            let docs = try await search(queryItems: queryItems)
            for doc in docs {
                let dedupeKey = candidateKey(for: doc)
                if seenDocumentKeys.insert(dedupeKey).inserted {
                    mergedDocuments.append(doc)
                }
            }
        }

        let mapped = mergedDocuments.compactMap { doc in
            candidate(from: doc, localItem: item, localTitle: queryTitle, localAuthors: localAuthors)
        }

        return mapped
            .sorted { lhs, rhs in
                if lhs.confidence == rhs.confidence {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.confidence > rhs.confidence
            }
            .prefix(limit)
            .map { $0 }
    }

    private func search(queryItems: [URLQueryItem]) async throws -> [OpenLibrarySearchResponse.Document] {
        var components = URLComponents(string: "https://openlibrary.org/search.json")
        components?.queryItems = queryItems
        guard let url = components?.url else {
            return []
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            return []
        }
        return try JSONDecoder().decode(OpenLibrarySearchResponse.self, from: data).docs
    }

    private func candidate(
        from document: OpenLibrarySearchResponse.Document,
        localItem: ABSCore.LibraryItem,
        localTitle: String,
        localAuthors: [String]
    ) -> MetadataMatchCandidate? {
        let candidateTitle = normalizedCandidateTitle(document.title)
        guard !candidateTitle.isEmpty else {
            return nil
        }

        let candidateAuthors = (document.authorName ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let titleScore = titleSimilarity(localTitle, candidateTitle)
        let authorScore: Double
        if localAuthors.isEmpty {
            authorScore = candidateAuthors.isEmpty ? 0.5 : 0.65
        } else if candidateAuthors.isEmpty {
            authorScore = 0
        } else {
            authorScore = localAuthors.map { local in
                candidateAuthors.map { candidate in titleSimilarity(local, candidate) }.max() ?? 0
            }.reduce(0, +) / Double(max(1, localAuthors.count))
        }
        let yearScore = publicationYearScore(localItem.publishedYear, document.firstPublishYear)
        let sequenceScore = sequenceAlignmentScore(localItem.seriesSequence, sequenceFromText(candidateTitle))
        let confidence = max(0, min(1, (titleScore * 0.64) + (authorScore * 0.24) + (yearScore * 0.07) + (sequenceScore * 0.05)))
        guard confidence >= 0.5 else {
            return nil
        }

        let tags = normalizedUnique(document.subject ?? [], limit: 10)
        let language = normalizedLanguage(document.language?.first)
        let publisher = document.publisher?.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedSeries = seriesInfo(from: candidateTitle, fallback: document.series)

        return MetadataMatchCandidate(
            id: UUID().uuidString,
            source: "OpenLibrary",
            sourceID: document.key,
            confidence: confidence,
            confidenceReason: "title \(percent(titleScore)), author \(percent(authorScore)), year \(percent(yearScore)), sequence \(percent(sequenceScore))",
            title: candidateTitle,
            authors: candidateAuthors,
            narrator: nil,
            seriesName: parsedSeries.name,
            seriesSequence: parsedSeries.sequence,
            collections: [],
            genres: tags,
            tags: tags,
            blurb: document.firstSentence?.trimmingCharacters(in: .whitespacesAndNewlines),
            publisher: (publisher?.isEmpty == false) ? publisher : nil,
            publishedYear: document.firstPublishYear,
            language: (language?.isEmpty == false) ? language : nil
        )
    }

    private func localAuthorList(from item: ABSCore.LibraryItem) -> [String] {
        if !item.authors.isEmpty {
            return item.authors
        }
        guard let author = item.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty else {
            return []
        }
        return author
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func titleSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let tokenScore = tokenSimilarity(lhs, rhs)
        let levenshteinScore = normalizedLevenshtein(lhs, rhs)
        return (tokenScore * 0.7) + (levenshteinScore * 0.3)
    }

    private func tokenSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(normalizedTokens(lhs))
        let right = Set(normalizedTokens(rhs))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private func normalizedTokens(_ value: String) -> [String] {
        let lowercase = value
            .replacingOccurrences(of: "\\(.*?\\)", with: " ", options: .regularExpression)
            .lowercased()
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let filtered = String(lowercase.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        return filtered
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func normalizedLevenshtein(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(normalizedTokens(lhs).joined(separator: " "))
        let b = Array(normalizedTokens(rhs).joined(separator: " "))
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        if a == b { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }

        var previous = Array(0...b.count)
        for (i, charA) in a.enumerated() {
            var current = Array(repeating: 0, count: b.count + 1)
            current[0] = i + 1
            for (j, charB) in b.enumerated() {
                let substitutionCost = (charA == charB) ? 0 : 1
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + substitutionCost
                )
            }
            previous = current
        }

        let distance = previous[b.count]
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1 }
        return max(0, 1 - (Double(distance) / Double(maxLen)))
    }

    private func publicationYearScore(_ localYear: Int?, _ candidateYear: Int?) -> Double {
        guard let localYear, let candidateYear else { return 0.5 }
        let delta = abs(localYear - candidateYear)
        switch delta {
        case 0: return 1
        case 1: return 0.8
        case 2...3: return 0.6
        case 4...7: return 0.4
        default: return 0
        }
    }

    private func sequenceAlignmentScore(_ localSequence: Int?, _ candidateSequence: Int?) -> Double {
        guard let localSequence, let candidateSequence else { return 0.5 }
        return localSequence == candidateSequence ? 1 : 0
    }

    private func sequenceFromText(_ text: String) -> Int? {
        let patterns = [
            "#\\s*(\\d+)",
            "(?:book|vol(?:ume)?)\\s*(\\d+)"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1 else {
                continue
            }
            if let nsRange = Range(match.range(at: 1), in: text), let value = Int(text[nsRange]) {
                return value
            }
        }
        return nil
    }

    private func seriesInfo(from title: String, fallback: [String]?) -> (name: String?, sequence: Int?) {
        if let series = fallback?.first?.trimmingCharacters(in: .whitespacesAndNewlines), !series.isEmpty {
            return (series, sequenceFromText(title))
        }
        let pattern = #"^(.*?)\s*(?:#|book|vol(?:ume)?)\s*(\d+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (nil, sequenceFromText(title))
        }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        guard let match = regex.firstMatch(in: title, options: [], range: range), match.numberOfRanges > 2 else {
            return (nil, sequenceFromText(title))
        }
        let name: String? = {
            guard let r = Range(match.range(at: 1), in: title) else { return nil }
            let value = title[r].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }()
        let sequence: Int? = {
            guard let r = Range(match.range(at: 2), in: title) else { return nil }
            return Int(title[r])
        }()
        return (name, sequence ?? sequenceFromText(title))
    }

    private func normalizedCandidateTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedQueryTitle(_ value: String) -> String {
        normalizedCandidateTitle(
            value.replacingOccurrences(of: "\\(.*?\\)", with: " ", options: .regularExpression)
        )
    }

    private func normalizedLanguage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !code.isEmpty else { return nil }
        let map: [String: String] = [
            "eng": "English",
            "en": "English",
            "deu": "German",
            "de": "German",
            "fra": "French",
            "fr": "French",
            "spa": "Spanish",
            "es": "Spanish"
        ]
        return map[code] ?? raw
    }

    private func candidateKey(for doc: OpenLibrarySearchResponse.Document) -> String {
        if let key = doc.key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        let firstAuthor = doc.authorName?.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(doc.title.lowercased())::\(firstAuthor.lowercased())::\(doc.firstPublishYear ?? 0)"
    }

    private func normalizedUnique(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in values {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let key = value.lowercased()
            if seen.insert(key).inserted {
                result.append(value)
                if result.count >= limit {
                    break
                }
            }
        }
        return result
    }

    private func percent(_ score: Double) -> String {
        "\(Int((score * 100).rounded()))%"
    }
}

private struct OpenLibrarySearchResponse: Decodable {
    private enum FirstSentence: Decodable {
        case text(String)
        case values([String])
        case object(ValueObject)

        struct ValueObject: Decodable {
            let value: String?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
                return
            }
            if let values = try? container.decode([String].self) {
                self = .values(values)
                return
            }
            if let object = try? container.decode(ValueObject.self) {
                self = .object(object)
                return
            }
            self = .values([])
        }

        var normalizedValue: String? {
            switch self {
            case .text(let value):
                return value
            case .values(let values):
                return values.first
            case .object(let object):
                return object.value
            }
        }
    }

    struct Document: Decodable {
        let key: String?
        let title: String
        let authorName: [String]?
        let firstPublishYear: Int?
        let language: [String]?
        let publisher: [String]?
        let subject: [String]?
        let series: [String]?
        private let firstSentenceRaw: FirstSentence?
        var firstSentence: String? { firstSentenceRaw?.normalizedValue }

        enum CodingKeys: String, CodingKey {
            case key
            case title
            case authorName = "author_name"
            case firstPublishYear = "first_publish_year"
            case language
            case publisher
            case subject
            case series
            case firstSentenceRaw = "first_sentence"
        }
    }

    let docs: [Document]
}
