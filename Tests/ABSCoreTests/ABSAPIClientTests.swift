import XCTest
@testable import ABSCore

final class ABSAPIClientTests: XCTestCase {
    func testLibrariesDecodeFromWrappedResponse() async throws {
        let baseURL = URL(string: "https://example.com")!
        let responses = [
            MockHTTPClient.Response(
                statusCode: 200,
                data: Data("{\"token\":\"token-value\",\"expiresIn\":3600}".utf8)
            ),
            MockHTTPClient.Response(
                statusCode: 200,
                data: Data("{\"libraries\":[{\"id\":\"1\",\"name\":\"Books\"}]}".utf8)
            )
        ]

        let http = MockHTTPClient(responses: responses)
        let api = try await ABSAPIClient(baseURL: baseURL, httpClient: http, secureStore: InMemorySecureStore())

        try await api.signIn(username: "user", password: "pass")
        let libraries = try await api.libraries()

        XCTAssertEqual(libraries.count, 1)
        XCTAssertEqual(libraries.first?.name, "Books")
    }

    func testSearchDecodesResults() async throws {
        let baseURL = URL(string: "https://example.com")!
        let responses = [
            MockHTTPClient.Response(
                statusCode: 200,
                data: Data("{\"token\":\"token-value\",\"expiresIn\":3600}".utf8)
            ),
            MockHTTPClient.Response(
                statusCode: 200,
                data: Data("{\"results\":[{\"id\":\"book-1\",\"title\":\"Swift Patterns\",\"author\":\"A. Dev\",\"duration\":100.0,\"chapters\":[]}]}".utf8)
            )
        ]

        let http = MockHTTPClient(responses: responses)
        let api = try await ABSAPIClient(baseURL: baseURL, httpClient: http, secureStore: InMemorySecureStore())

        try await api.signIn(username: "user", password: "pass")
        let result = try await api.search(query: "Swift")

        XCTAssertEqual(result.map(\.title), ["Swift Patterns"])
    }
}

private actor MockHTTPClient: HTTPClient {
    struct Response {
        let statusCode: Int
        let data: Data
    }

    private let responses: [Response]
    private var index = 0

    init(responses: [Response]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard index < responses.count else {
            throw APIError.invalidResponse
        }

        let response = responses[index]
        index += 1

        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!

        return (response.data, http)
    }
}
