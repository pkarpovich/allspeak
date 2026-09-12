import Foundation
import Testing
@testable import Allspeak

private actor MockCatalogTransport: CatalogTransport {
    private let response: Result<(Data, HTTPURLResponse), Error>
    private(set) var recordedRequests: [URLRequest] = []

    init(data: Data, statusCode: Int) {
        let http = HTTPURLResponse(
            url: URL(string: "https://allspeak.pkarpovich.dev")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        self.response = .success((data, http))
    }

    init(error: Error) {
        self.response = .failure(error)
    }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        recordedRequests.append(request)
        switch response {
        case let .success((data, http)):
            return (data, http)
        case let .failure(error):
            throw error
        }
    }
}

private let catalogListJSON = """
{
  "sessions": [
    {
      "id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
      "title": "The Invite \\u00b7 RU dub",
      "revision": 1,
      "updatedAt": "2026-07-15T09:14:22.512Z",
      "totalSize": 233533616,
      "trackLabels": ["original", "ft.vocals", "ft.sidon"]
    },
    {
      "id": "6BA7B810-9DAD-11D1-80B4-00C04FD430C8",
      "title": "Toy Story 5 \\u00b7 RU dub",
      "revision": 2,
      "updatedAt": "2026-07-14T18:02:00Z",
      "totalSize": 512000000,
      "trackLabels": ["original", "ft.sidon"]
    }
  ]
}
"""

private let sessionDetailJSON = """
{
  "id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
  "title": "The Invite \\u00b7 RU dub",
  "revision": 1,
  "createdAt": "2026-07-10T08:00:00.000Z",
  "updatedAt": "2026-07-15T09:14:22.512Z",
  "tracks": [
    {
      "filename": "original.m4a",
      "size": 78000000,
      "sha256": "aaaa0000000000000000000000000000000000000000000000000000000000aa",
      "label": "original",
      "sortOrder": 0,
      "isDefault": false,
      "url": "https://r2.example.com/original.m4a?sig=1"
    },
    {
      "filename": "ft.sidon.m4a",
      "size": 79000000,
      "sha256": "bbbb0000000000000000000000000000000000000000000000000000000000bb",
      "label": "ft.sidon",
      "sortOrder": 2,
      "isDefault": true,
      "url": "https://r2.example.com/ft.sidon.m4a?sig=2"
    }
  ],
  "subtitle": {
    "filename": "the-invite.srt",
    "size": 41234,
    "sha256": "cccc0000000000000000000000000000000000000000000000000000000000cc",
    "url": "https://r2.example.com/the-invite.srt?sig=3"
  },
  "urlsExpireAt": "2026-07-15T10:14:22.512Z"
}
"""

@Suite("Catalog API client", .tags(.catalog))
struct CatalogClientTests {

    private func makeClient(transport: any CatalogTransport, token: String = "read-token") -> CatalogClient {
        CatalogClient(
            baseURL: URL(string: "https://allspeak.pkarpovich.dev")!,
            readToken: token,
            transport: transport
        )
    }

    @Test("decodes the catalog list endpoint into ordered session summaries")
    func decodesCatalogList() async throws {
        let transport = MockCatalogTransport(data: Data(catalogListJSON.utf8), statusCode: 200)
        let client = makeClient(transport: transport)

        let summaries = try await client.fetchCatalog()

        #expect(summaries.count == 2)
        let first = try #require(summaries.first)
        #expect(first.id == UUID(uuidString: "1B4E28BA-2FA1-11D2-883F-0016D3CCA427"))
        #expect(first.title == "The Invite \u{b7} RU dub")
        #expect(first.revision == 1)
        #expect(first.totalSize == 233533616)
        #expect(first.trackLabels == ["original", "ft.vocals", "ft.sidon"])
    }

    @Test("parses fractional and whole-second ISO8601 dates in the catalog list")
    func parsesISO8601Dates() async throws {
        let transport = MockCatalogTransport(data: Data(catalogListJSON.utf8), statusCode: 200)
        let client = makeClient(transport: transport)

        let summaries = try await client.fetchCatalog()

        let fractional = try #require(summaries.first)
        let whole = try #require(summaries.last)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let fractionalComponents = utc.dateComponents([.year, .month, .day, .hour, .minute], from: fractional.updatedAt)
        #expect(fractionalComponents.year == 2026)
        #expect(fractionalComponents.month == 7)
        #expect(fractionalComponents.day == 15)
        let wholeComponents = utc.dateComponents([.hour, .minute, .second], from: whole.updatedAt)
        #expect(wholeComponents.hour == 18)
        #expect(wholeComponents.minute == 2)
        #expect(wholeComponents.second == 0)
    }

    @Test("decodes the session detail endpoint with tracks and subtitle")
    func decodesSessionDetail() async throws {
        let transport = MockCatalogTransport(data: Data(sessionDetailJSON.utf8), statusCode: 200)
        let client = makeClient(transport: transport)
        let id = try #require(UUID(uuidString: "1B4E28BA-2FA1-11D2-883F-0016D3CCA427"))

        let detail = try await client.fetchSession(id: id)

        #expect(detail.id == id)
        #expect(detail.revision == 1)
        #expect(detail.tracks.count == 2)
        let candidate = detail.tracks.first { $0.isDefault }
        let defaultTrack = try #require(candidate)
        #expect(defaultTrack.label == "ft.sidon")
        #expect(defaultTrack.sortOrder == 2)
        #expect(defaultTrack.sha256 == "bbbb0000000000000000000000000000000000000000000000000000000000bb")
        #expect(defaultTrack.url == URL(string: "https://r2.example.com/ft.sidon.m4a?sig=2"))
        #expect(detail.subtitle.filename == "the-invite.srt")
        #expect(detail.subtitle.size == 41234)
        #expect(detail.clip == nil)
    }

    @Test("decodes an optional clip in the session detail and lists it for import last")
    func decodesSessionDetailClip() async throws {
        let json = sessionDetailJSON.replacingOccurrences(
            of: "\"urlsExpireAt\"",
            with: """
            "clip": {
              "filename": "the-invite.first-line.mp4",
              "size": 6200000,
              "sha256": "dddd0000000000000000000000000000000000000000000000000000000000dd",
              "url": "https://r2.example.com/the-invite.first-line.mp4?sig=4"
            },
            "urlsExpireAt"
            """
        )
        let transport = MockCatalogTransport(data: Data(json.utf8), statusCode: 200)
        let client = makeClient(transport: transport)
        let id = try #require(UUID(uuidString: "1B4E28BA-2FA1-11D2-883F-0016D3CCA427"))

        let detail = try await client.fetchSession(id: id)

        let clip = try #require(detail.clip)
        #expect(clip.filename == "the-invite.first-line.mp4")
        #expect(clip.size == 6200000)
        #expect(clip.url == URL(string: "https://r2.example.com/the-invite.first-line.mp4?sig=4"))
        #expect(detail.importFileRequests.map(\.filename) == [
            "original.m4a", "ft.sidon.m4a", "the-invite.srt", "the-invite.first-line.mp4"
        ])
    }

    @Test("sends a Bearer authorization header on every request")
    func sendsBearerHeader() async throws {
        let transport = MockCatalogTransport(data: Data(catalogListJSON.utf8), statusCode: 200)
        let client = makeClient(transport: transport, token: "secret-123")

        _ = try await client.fetchCatalog()

        let recorded = await transport.recordedRequests
        let request = try #require(recorded.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-123")
        #expect(request.url?.path() == "/api/v1/catalog")
    }

    @Test("targets the lowercase session id path for detail requests")
    func targetsLowercaseSessionPath() async throws {
        let transport = MockCatalogTransport(data: Data(sessionDetailJSON.utf8), statusCode: 200)
        let client = makeClient(transport: transport)
        let id = try #require(UUID(uuidString: "1B4E28BA-2FA1-11D2-883F-0016D3CCA427"))

        _ = try await client.fetchSession(id: id)

        let recorded = await transport.recordedRequests
        let request = try #require(recorded.first)
        #expect(request.url?.path() == "/api/v1/sessions/1b4e28ba-2fa1-11d2-883f-0016d3cca427")
    }

    @Test("maps a 401 response to the unauthorized error")
    func mapsUnauthorized() async throws {
        let transport = MockCatalogTransport(data: Data("{}".utf8), statusCode: 401)
        let client = makeClient(transport: transport)

        await #expect(throws: CatalogClientError.unauthorized) {
            _ = try await client.fetchCatalog()
        }
    }

    @Test("maps a 404 response to the notFound error")
    func mapsNotFound() async throws {
        let transport = MockCatalogTransport(data: Data("{}".utf8), statusCode: 404)
        let client = makeClient(transport: transport)
        let id = try #require(UUID(uuidString: "1B4E28BA-2FA1-11D2-883F-0016D3CCA427"))

        await #expect(throws: CatalogClientError.notFound) {
            _ = try await client.fetchSession(id: id)
        }
    }

    @Test("maps malformed JSON to the decoding error")
    func mapsDecodingFailure() async throws {
        let transport = MockCatalogTransport(data: Data("{ not json".utf8), statusCode: 200)
        let client = makeClient(transport: transport)

        await #expect(throws: CatalogClientError.decoding) {
            _ = try await client.fetchCatalog()
        }
    }

    @Test("maps a transport failure to the network error")
    func mapsNetworkFailure() async throws {
        let transport = MockCatalogTransport(error: URLError(.notConnectedToInternet))
        let client = makeClient(transport: transport)

        await #expect(throws: CatalogClientError.network) {
            _ = try await client.fetchCatalog()
        }
    }
}
