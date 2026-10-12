import Foundation
@testable import Allspeak

final class FakeCatalogServer: CatalogTransport, @unchecked Sendable {
    static let baseURL = URL(string: "https://catalog.test")!

    private let lock = NSLock()
    private var detailsByID: [UUID: CatalogSessionDetail] = [:]
    private var filesByURL: [URL: Data] = [:]
    private var failuresLeft: [String: Int] = [:]
    private var log: [URL] = []

    var requests: [URL] {
        lock.withLock { log }
    }

    var client: CatalogClient {
        CatalogClient(baseURL: Self.baseURL, readToken: "token", transport: self)
    }

    @discardableResult
    func publish(catalogID: UUID, subtitle: Data?, fingerprint: Data?) -> (subtitleSHA: String?, fingerprintSHA: String?) {
        let subtitleData = subtitle ?? Data("1\n00:00:00,000 --> 00:00:01,000\nhi\n".utf8)
        let subtitleSHA = CatalogFileCache.sha256Hex(of: subtitleData)
        let subtitleURL = Self.baseURL.appending(path: "files/\(subtitleSHA).srt")
        var fingerprintRef: CatalogFingerprint?
        var fingerprintSHA: String?
        if let fingerprint {
            let sha = CatalogFileCache.sha256Hex(of: fingerprint)
            let url = Self.baseURL.appending(path: "files/\(sha).shazamcatalog")
            fingerprintRef = CatalogFingerprint(filename: "film.shazamcatalog", size: Int64(fingerprint.count), sha256: sha, url: url)
            fingerprintSHA = sha
            lock.withLock { filesByURL[url] = fingerprint }
        }
        let detail = CatalogSessionDetail(
            id: catalogID,
            title: "Film",
            revision: 1,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            tracks: [],
            subtitle: CatalogSubtitle(filename: "film.srt", size: Int64(subtitleData.count), sha256: subtitleSHA, url: subtitleURL),
            fingerprint: fingerprintRef,
            urlsExpireAt: Date(timeIntervalSince1970: 3600)
        )
        lock.withLock {
            detailsByID[catalogID] = detail
            filesByURL[subtitleURL] = subtitleData
        }
        return (subtitle == nil ? nil : subtitleSHA, fingerprintSHA)
    }

    func failNext(_ pathSuffix: String, times: Int = 1) {
        lock.withLock { failuresLeft[pathSuffix] = times }
    }

    func corrupt(sha256: String) {
        lock.withLock {
            for url in filesByURL.keys where url.lastPathComponent.hasPrefix(sha256) {
                filesByURL[url] = Data("corrupt".utf8)
            }
        }
    }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try require(request.url)
        let (status, body): (Int, Data) = lock.withLock {
            log.append(url)
            if let key = failuresLeft.keys.first(where: { url.path.hasSuffix($0) }), let left = failuresLeft[key], left > 0 {
                failuresLeft[key] = left - 1
                return (503, Data())
            }
            if url.path.hasPrefix("/api/v1/sessions/"),
               let id = UUID(uuidString: url.lastPathComponent),
               let detail = detailsByID[id] {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                return (200, (try? encoder.encode(detail)) ?? Data())
            }
            if let data = filesByURL[url] {
                return (200, data)
            }
            return (404, Data())
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw URLError(.badURL) }
    return value
}
