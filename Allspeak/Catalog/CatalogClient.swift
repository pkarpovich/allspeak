import Foundation

protocol CatalogTransport: Sendable {
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: CatalogTransport {
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

enum CatalogClientError: Error, Equatable {
    case unauthorized
    case notFound
    case network
    case decoding
}

struct CatalogClient: Sendable {
    let baseURL: URL
    let readToken: String
    let transport: any CatalogTransport

    init(baseURL: URL, readToken: String, transport: any CatalogTransport) {
        self.baseURL = baseURL
        self.readToken = readToken
        self.transport = transport
    }

    init(config: CatalogConfig, transport: any CatalogTransport = URLSession.shared) {
        self.init(baseURL: config.baseURL, readToken: config.readToken, transport: transport)
    }

    func fetchCatalog() async throws -> [CatalogSessionSummary] {
        let request = makeRequest(path: "api/v1/catalog")
        let response: CatalogListResponse = try await send(request)
        return response.sessions
    }

    func fetchSession(id: UUID) async throws -> CatalogSessionDetail {
        let request = makeRequest(path: "api/v1/sessions/\(id.uuidString.lowercased())")
        return try await send(request)
    }

    private func makeRequest(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.setValue("Bearer \(readToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.fetch(request)
        } catch {
            throw CatalogClientError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw CatalogClientError.network
        }

        switch http.statusCode {
        case 200...299:
            break
        case 401:
            throw CatalogClientError.unauthorized
        case 404:
            throw CatalogClientError.notFound
        default:
            throw CatalogClientError.network
        }

        do {
            return try Self.makeDecoder().decode(T.self, from: data)
        } catch {
            throw CatalogClientError.decoding
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
                return date
            }
            if let date = try? Date.ISO8601FormatStyle().parse(string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(string)"
            )
        }
        return decoder
    }
}
