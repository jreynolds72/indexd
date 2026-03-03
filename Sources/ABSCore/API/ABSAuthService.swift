import Foundation
import os

public actor ABSAuthService: AuthServicing {
    private let logger = Logger(subsystem: "indexd", category: "Auth")
    private let httpClient: HTTPClient
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    public func login(baseURL: URL, credentials: Credentials) async throws -> AuthToken {
        var request = URLRequest(url: baseURL.appending(path: "login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(credentials)

        let (data, response) = try await httpClient.send(request)
        logger.debug("POST \(request.url?.absoluteString ?? "", privacy: .public) -> \(response.statusCode)")

        guard (200..<300).contains(response.statusCode) else {
            throw APIError.requestFailed(statusCode: response.statusCode)
        }

        struct LoginResponse: Decodable {
            struct User: Decodable {
                let token: String?
            }

            let token: String?
            let expiresIn: TimeInterval?
            let user: User?
        }

        guard let payload = try? decoder.decode(LoginResponse.self, from: data) else {
            logger.error("Login decode failure payload: \(String(decoding: data.prefix(400), as: UTF8.self), privacy: .public)")
            throw APIError.decodeFailure
        }

        guard let token = payload.token ?? payload.user?.token, !token.isEmpty else {
            logger.error("Login response missing token")
            throw APIError.decodeFailure
        }

        let expiresAt = payload.expiresIn.map { Date().addingTimeInterval($0) }
        return AuthToken(value: token, expiresAt: expiresAt)
    }
}
