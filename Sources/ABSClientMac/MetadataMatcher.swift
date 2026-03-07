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
    let durationSeconds: TimeInterval?
    let isExactRuntimeMatch: Bool
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

        let openLibraryCandidates = mergedDocuments.compactMap { doc in
            candidate(from: doc, localItem: item, localTitle: queryTitle, localAuthors: localAuthors)
        }

        let googleVolumes = try await googleBooksSearch(
            queryTitle: queryTitle,
            firstAuthor: localAuthors.first,
            limit: max(1, min(limit * 2, 20))
        )
        let googleCandidates = googleVolumes.compactMap { volume in
            googleCandidate(from: volume, localItem: item, localTitle: queryTitle, localAuthors: localAuthors)
        }

        let audibleProducts = try await audibleSearch(
            queryTitle: queryTitle,
            firstAuthor: localAuthors.first,
            limit: max(1, min(limit * 2, 20))
        )
        let audibleCandidates = audibleProducts.compactMap { product in
            audibleCandidate(from: product, localItem: item, localTitle: queryTitle, localAuthors: localAuthors)
        }

        let amazonItems = try await amazonSearch(
            queryTitle: queryTitle,
            firstAuthor: localAuthors.first,
            limit: max(1, min(limit * 2, 20))
        )
        let amazonCandidates = amazonItems.compactMap { amazon in
            amazonCandidate(from: amazon, localItem: item, localTitle: queryTitle, localAuthors: localAuthors)
        }

        return deduplicatedCandidates(openLibraryCandidates + googleCandidates + audibleCandidates + amazonCandidates)
            .sorted { lhs, rhs in
                if lhs.confidence == rhs.confidence {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.confidence > rhs.confidence
            }
            .prefix(limit)
            .map { $0 }
    }

    private func googleBooksSearch(
        queryTitle: String,
        firstAuthor: String?,
        limit: Int
    ) async throws -> [GoogleBooksResponse.Volume] {
        var queryParts: [String] = []
        queryParts.append("intitle:\(queryTitle)")
        if let firstAuthor, !firstAuthor.isEmpty {
            queryParts.append("inauthor:\(firstAuthor)")
        }

        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")
        components?.queryItems = [
            URLQueryItem(name: "q", value: queryParts.joined(separator: "+")),
            URLQueryItem(name: "maxResults", value: String(max(1, min(limit, 40))))
        ]
        guard let url = components?.url else {
            return []
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            return []
        }

        let decoded = try JSONDecoder().decode(GoogleBooksResponse.self, from: data)
        return decoded.items ?? []
    }

    private func audibleSearch(
        queryTitle: String,
        firstAuthor: String?,
        limit: Int
    ) async throws -> [AudibleCatalogResponse.Product] {
        var queryParts = [queryTitle]
        if let firstAuthor, !firstAuthor.isEmpty {
            queryParts.append(firstAuthor)
        }

        var components = URLComponents(string: "https://api.audible.com/1.0/catalog/products")
        components?.queryItems = [
            URLQueryItem(name: "response_groups", value: "contributors,series,product_desc,product_attrs"),
            URLQueryItem(name: "num_results", value: String(max(1, min(limit, 50)))),
            URLQueryItem(name: "keywords", value: queryParts.joined(separator: " "))
        ]
        guard let url = components?.url else {
            return []
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            return []
        }

        let decoded = try JSONDecoder().decode(AudibleCatalogResponse.self, from: data)
        return decoded.products ?? []
    }

    private func amazonSearch(
        queryTitle: String,
        firstAuthor: String?,
        limit: Int
    ) async throws -> [AmazonSearchItem] {
        let query = [queryTitle, firstAuthor, "audiobook"].compactMap { $0 }.joined(separator: " ")
        var components = URLComponents(string: "https://www.amazon.com/s")
        components?.queryItems = [
            URLQueryItem(name: "i", value: "audible"),
            URLQueryItem(name: "k", value: query)
        ]
        guard let url = components?.url else {
            return []
        }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            return []
        }

        if html.localizedCaseInsensitiveContains("To discuss automated access to Amazon data") {
            return []
        }
        return parseAmazonSearchHTML(html, limit: limit)
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
            language: (language?.isEmpty == false) ? language : nil,
            durationSeconds: nil,
            isExactRuntimeMatch: false
        )
    }

    private func googleCandidate(
        from volume: GoogleBooksResponse.Volume,
        localItem: ABSCore.LibraryItem,
        localTitle: String,
        localAuthors: [String]
    ) -> MetadataMatchCandidate? {
        let info = volume.volumeInfo
        let candidateTitle = normalizedCandidateTitle(info.title ?? "")
        guard !candidateTitle.isEmpty else { return nil }

        let candidateAuthors = (info.authors ?? [])
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

        let yearScore = publicationYearScore(localItem.publishedYear, publishedYear(from: info.publishedDate))
        let subtitle = info.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sequenceScore = sequenceAlignmentScore(
            localItem.seriesSequence,
            sequenceFromText(subtitle ?? candidateTitle)
        )
        let confidence = max(0, min(1, (titleScore * 0.62) + (authorScore * 0.25) + (yearScore * 0.08) + (sequenceScore * 0.05)))
        guard confidence >= 0.52 else { return nil }

        let categories = normalizedUnique(info.categories ?? [], limit: 10)
        let language = normalizedLanguage(info.language)
        let seriesFromSubtitle = seriesInfo(from: subtitle ?? "", fallback: nil).name

        return MetadataMatchCandidate(
            id: UUID().uuidString,
            source: "GoogleBooks",
            sourceID: volume.id,
            confidence: confidence,
            confidenceReason: "title \(percent(titleScore)), author \(percent(authorScore)), year \(percent(yearScore)), sequence \(percent(sequenceScore))",
            title: candidateTitle,
            authors: candidateAuthors,
            narrator: nil,
            seriesName: seriesFromSubtitle,
            seriesSequence: sequenceFromText(subtitle ?? candidateTitle),
            collections: [],
            genres: categories,
            tags: categories,
            blurb: info.description?.trimmingCharacters(in: .whitespacesAndNewlines),
            publisher: info.publisher?.trimmingCharacters(in: .whitespacesAndNewlines),
            publishedYear: publishedYear(from: info.publishedDate),
            language: (language?.isEmpty == false) ? language : nil,
            durationSeconds: nil,
            isExactRuntimeMatch: false
        )
    }

    private func audibleCandidate(
        from product: AudibleCatalogResponse.Product,
        localItem: ABSCore.LibraryItem,
        localTitle: String,
        localAuthors: [String]
    ) -> MetadataMatchCandidate? {
        let candidateTitle = normalizedCandidateTitle(product.title ?? "")
        guard !candidateTitle.isEmpty else { return nil }

        let candidateAuthors = (product.authors ?? [])
            .compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let candidateNarrators = (product.narrators ?? [])
            .compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let firstSeries = product.series?.first
        let seriesName = normalizedCandidateTitle(firstSeries?.title ?? "")
        let seriesSequence = Int(firstSeries?.sequence ?? "")
        let candidateDurationSeconds = product.runtimeLengthMinutes.map { Double($0) * 60 }

        let titleScore = titleSimilarity(localTitle, candidateTitle)
        let authorScore: Double
        if localAuthors.isEmpty {
            authorScore = candidateAuthors.isEmpty ? 0.5 : 0.68
        } else if candidateAuthors.isEmpty {
            authorScore = 0.2
        } else {
            authorScore = localAuthors.map { local in
                candidateAuthors.map { candidate in titleSimilarity(local, candidate) }.max() ?? 0
            }.reduce(0, +) / Double(max(1, localAuthors.count))
        }

        let publishedYear = publishedYear(from: product.issueDate ?? product.releaseDate ?? product.publicationDatetime)
        let yearScore = publicationYearScore(localItem.publishedYear, publishedYear)
        let sequenceScore = sequenceAlignmentScore(localItem.seriesSequence, seriesSequence)
        let runtimeScore = runtimeAlignmentScore(localItem.duration, candidateDurationSeconds)
        let runtimeDelta = runtimeDifference(localItem.duration, candidateDurationSeconds)
        let exactRuntimeMatch = (runtimeDelta ?? 1) <= 0.01
        let confidence = max(0, min(1, (titleScore * 0.56) + (authorScore * 0.23) + (yearScore * 0.07) + (sequenceScore * 0.04) + (runtimeScore * 0.10)))
        guard confidence >= 0.5 else { return nil }

        return MetadataMatchCandidate(
            id: UUID().uuidString,
            source: "Audible",
            sourceID: product.asin,
            confidence: confidence,
            confidenceReason: "title \(percent(titleScore)), author \(percent(authorScore)), year \(percent(yearScore)), sequence \(percent(sequenceScore)), runtime \(percent(runtimeScore))",
            title: candidateTitle,
            authors: candidateAuthors,
            narrator: candidateNarrators.joined(separator: ", "),
            seriesName: seriesName.isEmpty ? nil : seriesName,
            seriesSequence: seriesSequence,
            collections: [],
            genres: [],
            tags: [],
            blurb: stripHTMLTags(product.merchandisingSummary),
            publisher: product.publisherName?.trimmingCharacters(in: .whitespacesAndNewlines),
            publishedYear: publishedYear,
            language: normalizedLanguage(product.language),
            durationSeconds: candidateDurationSeconds,
            isExactRuntimeMatch: exactRuntimeMatch
        )
    }

    private func amazonCandidate(
        from amazon: AmazonSearchItem,
        localItem: ABSCore.LibraryItem,
        localTitle: String,
        localAuthors: [String]
    ) -> MetadataMatchCandidate? {
        let candidateTitle = normalizedCandidateTitle(amazon.title)
        guard !candidateTitle.isEmpty else { return nil }

        let candidateAuthors = normalizedUnique(amazon.authors, limit: 5)
        let titleScore = titleSimilarity(localTitle, candidateTitle)
        let authorScore: Double
        if localAuthors.isEmpty {
            authorScore = candidateAuthors.isEmpty ? 0.5 : 0.65
        } else if candidateAuthors.isEmpty {
            // Amazon result cards sometimes omit author in scrapeable text.
            authorScore = 0.35
        } else {
            authorScore = localAuthors.map { local in
                candidateAuthors.map { candidate in titleSimilarity(local, candidate) }.max() ?? 0
            }.reduce(0, +) / Double(max(1, localAuthors.count))
        }
        let yearScore = publicationYearScore(localItem.publishedYear, amazon.publishedYear)
        let sequenceScore = sequenceAlignmentScore(localItem.seriesSequence, sequenceFromText(candidateTitle))
        let confidence = max(0, min(1, (titleScore * 0.66) + (authorScore * 0.24) + (yearScore * 0.06) + (sequenceScore * 0.04)))
        guard confidence >= 0.53 else { return nil }

        return MetadataMatchCandidate(
            id: UUID().uuidString,
            source: "Amazon",
            sourceID: amazon.asin,
            confidence: confidence,
            confidenceReason: "title \(percent(titleScore)), author \(percent(authorScore)), year \(percent(yearScore)), sequence \(percent(sequenceScore))",
            title: candidateTitle,
            authors: candidateAuthors,
            narrator: nil,
            seriesName: nil,
            seriesSequence: nil,
            collections: [],
            genres: [],
            tags: [],
            blurb: nil,
            publisher: nil,
            publishedYear: amazon.publishedYear,
            language: nil,
            durationSeconds: nil,
            isExactRuntimeMatch: false
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

    private func runtimeDifference(_ localDuration: TimeInterval?, _ candidateDuration: TimeInterval?) -> Double? {
        guard let localDuration, let candidateDuration, localDuration > 0, candidateDuration > 0 else { return nil }
        return abs(localDuration - candidateDuration) / candidateDuration
    }

    private func runtimeAlignmentScore(_ localDuration: TimeInterval?, _ candidateDuration: TimeInterval?) -> Double {
        guard let delta = runtimeDifference(localDuration, candidateDuration) else { return 0.5 }
        switch delta {
        case ...0.01: return 1.0
        case ...0.03: return 0.85
        case ...0.05: return 0.7
        case ...0.10: return 0.45
        default: return 0.1
        }
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

    private func publishedYear(from publishedDate: String?) -> Int? {
        guard let publishedDate else { return nil }
        let trimmed = publishedDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return nil }
        let prefix = String(trimmed.prefix(4))
        return Int(prefix)
    }

    private func parseAmazonSearchHTML(_ html: String, limit: Int) -> [AmazonSearchItem] {
        guard let blockRegex = try? NSRegularExpression(
            pattern: #"<div[^>]*data-component-type=\"s-search-result\"[^>]*data-asin=\"([A-Z0-9]{8,14})\"[^>]*>([\s\S]*?)</div>\s*</div>"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = blockRegex.matches(in: html, options: [], range: nsRange)
        var items: [AmazonSearchItem] = []
        var seen = Set<String>()
        for match in matches {
            guard match.numberOfRanges > 2,
                  let asinRange = Range(match.range(at: 1), in: html),
                  let blockRange = Range(match.range(at: 2), in: html) else {
                continue
            }
            let asin = String(html[asinRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !asin.isEmpty else { continue }
            let block = String(html[blockRange])
            guard let title = firstRegexGroup(
                in: block,
                pattern: #"<h2[^>]*>[\s\S]*?<span[^>]*>(.*?)</span>"#,
                options: [.caseInsensitive]
            ) else {
                continue
            }

            let normalizedTitle = decodeHTMLEntities(stripHTMLTags(title) ?? title)
            guard !normalizedTitle.isEmpty else { continue }
            let authors = extractAmazonAuthors(from: block)
            let year = extractFirstYear(in: block)
            let dedupeKey = "\(asin.lowercased())::\(normalizedTitle.lowercased())"
            if seen.insert(dedupeKey).inserted {
                items.append(AmazonSearchItem(asin: asin, title: normalizedTitle, authors: authors, publishedYear: year))
            }
            if items.count >= limit {
                break
            }
        }
        return items
    }

    private func extractAmazonAuthors(from block: String) -> [String] {
        let bylineText = firstRegexGroup(
            in: block,
            pattern: #"(?:by|By)\s*</span>\s*<span[^>]*>(.*?)</span>"#,
            options: [.caseInsensitive]
        ) ?? firstRegexGroup(
            in: block,
            pattern: #"(?:by|By)\s+([^<\|]+)"#,
            options: [.caseInsensitive]
        )

        guard let bylineText else { return [] }
        let cleaned = decodeHTMLEntities(stripHTMLTags(bylineText) ?? bylineText)
        return cleaned
            .replacingOccurrences(of: "\\(.*?\\)", with: " ", options: .regularExpression)
            .split(separator: ",")
            .map { $0.replacingOccurrences(of: " and ", with: ",") }
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func extractFirstYear(in text: String) -> Int? {
        guard let yearText = firstRegexGroup(in: text, pattern: #"\b((?:19|20)\d{2})\b"#, options: []) else {
            return nil
        }
        return Int(yearText)
    }

    private func firstRegexGroup(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripHTMLTags(_ html: String?) -> String? {
        guard let html else { return nil }
        let noTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let collapsed = noTags.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let cleaned = decodeHTMLEntities(collapsed).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private func deduplicatedCandidates(_ candidates: [MetadataMatchCandidate]) -> [MetadataMatchCandidate] {
        var dedupedByKey: [String: MetadataMatchCandidate] = [:]
        for candidate in candidates {
            let firstAuthor = candidate.authors.first?.lowercased() ?? ""
            let yearPart = candidate.publishedYear.map(String.init) ?? ""
            let key = "\(candidate.title.lowercased())::\(firstAuthor)::\(yearPart)"
            if let existing = dedupedByKey[key] {
                if candidate.confidence > existing.confidence {
                    dedupedByKey[key] = candidate
                }
            } else {
                dedupedByKey[key] = candidate
            }
        }
        return Array(dedupedByKey.values)
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

private struct GoogleBooksResponse: Decodable {
    struct Volume: Decodable {
        let id: String?
        let volumeInfo: VolumeInfo
    }

    struct VolumeInfo: Decodable {
        let title: String?
        let subtitle: String?
        let authors: [String]?
        let publishedDate: String?
        let language: String?
        let publisher: String?
        let description: String?
        let categories: [String]?
    }

    let items: [Volume]?
}

private struct AudibleCatalogResponse: Decodable {
    struct Contributor: Decodable {
        let name: String?
    }

    struct Series: Decodable {
        let title: String?
        let sequence: String?
    }

    struct Product: Decodable {
        let asin: String?
        let title: String?
        let subtitle: String?
        let authors: [Contributor]?
        let narrators: [Contributor]?
        let series: [Series]?
        let publisherName: String?
        let language: String?
        let merchandisingSummary: String?
        let issueDate: String?
        let releaseDate: String?
        let publicationDatetime: String?
        let runtimeLengthMinutes: Int?

        enum CodingKeys: String, CodingKey {
            case asin
            case title
            case subtitle
            case authors
            case narrators
            case series
            case publisherName = "publisher_name"
            case language
            case merchandisingSummary = "merchandising_summary"
            case issueDate = "issue_date"
            case releaseDate = "release_date"
            case publicationDatetime = "publication_datetime"
            case runtimeLengthMinutes = "runtime_length_min"
        }
    }

    let products: [Product]?
}

private struct AmazonSearchItem {
    let asin: String
    let title: String
    let authors: [String]
    let publishedYear: Int?
}
