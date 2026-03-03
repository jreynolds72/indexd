import Foundation

public struct AuthToken: Codable, Equatable, Sendable {
    public let value: String
    public let expiresAt: Date?

    public init(value: String, expiresAt: Date?) {
        self.value = value
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }
}

public struct Credentials: Codable, Equatable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public enum AuthenticationError: Error, Equatable {
    case missingSession
    case tokenExpired
    case invalidCredentials
    case reauthenticationUnavailable
    case networkFailure(String)
}
