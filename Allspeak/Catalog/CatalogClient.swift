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
    case rejected
    case network
    case decoding
}

struct DiagnosticsUploadReceipt: Decodable, Equatable, Sendable {
    let key: String
    let size: Int64
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

    func uploadSessionLog(sessionID: UUID, name: String, data: Data) async throws -> DiagnosticsUploadReceipt {
        try await send(makeUpload(path: "api/v1/sessions/\(sessionID.uuidString.lowercased())/diagnostics", name: name, data: data, contentType: "application/x-ndjson"))
    }

    func uploadDiagnosticReport(name: String, data: Data) async throws -> DiagnosticsUploadReceipt {
        try await send(makeUpload(path: "api/v1/diagnostics/crashes", name: name, data: data, contentType: "application/json"))
    }

    private func makeRequest(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.setValue("Bearer \(readToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func makeUpload(path: String, name: String, data: Data, contentType: String) -> URLRequest {
        var request = makeRequest(path: path)
        request.url = request.url?.appending(queryItems: [URLQueryItem(name: "name", value: name)])
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
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
        case 400, 413:
            throw CatalogClientError.rejected
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
