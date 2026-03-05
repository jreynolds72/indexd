import Foundation

public enum LiveTransportKind: String, Sendable, Codable {
    case webSocket = "websocket"
    case serverSentEvents = "sse"
    case polling = "polling"
}

public struct LiveTransportCandidate: Sendable, Equatable {
    public let kind: LiveTransportKind
    public let connectURL: URL
    public let probeURL: URL
    public let statusCode: Int?
    public let isAvailable: Bool
    public let note: String?

    public init(
        kind: LiveTransportKind,
        connectURL: URL,
        probeURL: URL,
        statusCode: Int?,
        isAvailable: Bool,
        note: String?
    ) {
        self.kind = kind
        self.connectURL = connectURL
        self.probeURL = probeURL
        self.statusCode = statusCode
        self.isAvailable = isAvailable
        self.note = note
    }
}

public struct LiveTransportProbeResult: Sendable, Equatable {
    public let recommended: LiveTransportKind
    public let candidates: [LiveTransportCandidate]
    public let probedAt: Date

    public init(recommended: LiveTransportKind, candidates: [LiveTransportCandidate], probedAt: Date) {
        self.recommended = recommended
        self.candidates = candidates
        self.probedAt = probedAt
    }
}
