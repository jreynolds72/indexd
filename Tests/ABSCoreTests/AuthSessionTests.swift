import XCTest
@testable import ABSCore

final class AuthSessionTests: XCTestCase {
    func testLoginPersistsTokenAndCredentials() async throws {
        let store = InMemorySecureStore()
        let authService = MockAuthService(token: AuthToken(value: "abc123", expiresAt: Date().addingTimeInterval(3600)))
        let session = AuthSession(secureStore: store, authService: authService)

        try await session.configure(serverURL: URL(string: "https://example.com")!)
        try await session.login(username: "alice", password: "secret")

        let token = try await session.accessToken()
        let hasPersistedLogin = await session.hasPersistedLogin()
        XCTAssertEqual(token, "abc123")
        XCTAssertTrue(hasPersistedLogin)
    }

    func testExpiredTokenTriggersReauthentication() async throws {
        let store = InMemorySecureStore()
        let first = AuthToken(value: "expired", expiresAt: Date().addingTimeInterval(-5))
        let second = AuthToken(value: "fresh", expiresAt: Date().addingTimeInterval(3600))
        let authService = SequencedAuthService(tokens: [first, second])
        let session = AuthSession(secureStore: store, authService: authService)

        try await session.configure(serverURL: URL(string: "https://example.com")!)
        try await session.login(username: "alice", password: "secret")

        let token = try await session.accessToken()
        XCTAssertEqual(token, "fresh")
    }
}

private actor MockAuthService: AuthServicing {
    let token: AuthToken

    init(token: AuthToken) {
        self.token = token
    }

    func login(baseURL: URL, credentials: Credentials) async throws -> AuthToken {
        token
    }
}

private actor SequencedAuthService: AuthServicing {
    private var tokens: [AuthToken]

    init(tokens: [AuthToken]) {
        self.tokens = tokens
    }

    func login(baseURL: URL, credentials: Credentials) async throws -> AuthToken {
        guard !tokens.isEmpty else {
            return AuthToken(value: "fallback", expiresAt: Date().addingTimeInterval(3600))
        }
        return tokens.removeFirst()
    }
}
