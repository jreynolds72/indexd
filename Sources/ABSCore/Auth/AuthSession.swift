import Foundation

public protocol AuthServicing: Sendable {
    func login(baseURL: URL, credentials: Credentials) async throws -> AuthToken
}

public actor AuthSession {
    private enum Keys {
        static let tokenAccount = "auth.token"
        static let credentialsAccount = "auth.credentials"
    }

    private let secureStore: SecureStoring
    private let authService: AuthServicing
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var serverURL: URL?
    private var token: AuthToken?
    private var credentials: Credentials?

    public init(secureStore: SecureStoring, authService: AuthServicing) {
        self.secureStore = secureStore
        self.authService = authService
    }

    public func configure(serverURL: URL) async throws {
        self.serverURL = serverURL
        let service = Self.serviceName(for: serverURL)

        if let tokenData = try await secureStore.load(account: Keys.tokenAccount, service: service) {
            token = try decoder.decode(AuthToken.self, from: tokenData)
        }

        if let credentialsData = try await secureStore.load(account: Keys.credentialsAccount, service: service) {
            credentials = try decoder.decode(Credentials.self, from: credentialsData)
        }
    }

    public func login(username: String, password: String) async throws {
        guard let serverURL else {
            throw AuthenticationError.missingSession
        }

        let newCredentials = Credentials(username: username, password: password)
        let newToken: AuthToken

        do {
            newToken = try await authService.login(baseURL: serverURL, credentials: newCredentials)
        } catch {
            throw AuthenticationError.invalidCredentials
        }

        let service = Self.serviceName(for: serverURL)
        try await secureStore.save(try encoder.encode(newToken), account: Keys.tokenAccount, service: service)
        try await secureStore.save(try encoder.encode(newCredentials), account: Keys.credentialsAccount, service: service)

        token = newToken
        credentials = newCredentials
    }

    public func accessToken() async throws -> String {
        if let token, !token.isExpired {
            return token.value
        }

        try await reauthenticate()

        guard let token else {
            throw AuthenticationError.missingSession
        }

        return token.value
    }

    public func reauthenticate() async throws {
        guard let serverURL else {
            throw AuthenticationError.missingSession
        }

        guard let credentials else {
            throw AuthenticationError.reauthenticationUnavailable
        }

        let refreshed: AuthToken

        do {
            refreshed = try await authService.login(baseURL: serverURL, credentials: credentials)
        } catch {
            throw AuthenticationError.networkFailure(error.localizedDescription)
        }

        let service = Self.serviceName(for: serverURL)
        try await secureStore.save(try encoder.encode(refreshed), account: Keys.tokenAccount, service: service)
        token = refreshed
    }

    public func clear() async throws {
        guard let serverURL else {
            token = nil
            credentials = nil
            return
        }

        let service = Self.serviceName(for: serverURL)
        try await secureStore.delete(account: Keys.tokenAccount, service: service)
        try await secureStore.delete(account: Keys.credentialsAccount, service: service)

        token = nil
        credentials = nil
    }

    public func hasPersistedLogin() async -> Bool {
        token != nil
    }

    private static func serviceName(for serverURL: URL) -> String {
        "com.indexd.auth.\(serverURL.host ?? serverURL.absoluteString)"
    }
}
