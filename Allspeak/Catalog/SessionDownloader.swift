import Foundation
import Observation

struct CatalogFileRequest: Equatable, Sendable {
    let filename: String
    let size: Int64
    let sha256: String
    let url: URL
}

extension CatalogFileRequest {
    init(track: CatalogTrack) {
        self.init(filename: track.filename, size: track.size, sha256: track.sha256, url: track.url)
    }

    init(subtitle: CatalogSubtitle) {
        self.init(filename: subtitle.filename, size: subtitle.size, sha256: subtitle.sha256, url: subtitle.url)
    }

    init(clip: CatalogClip) {
        self.init(filename: clip.filename, size: clip.size, sha256: clip.sha256, url: clip.url)
    }
}

enum DownloadTransportError: Error, Equatable {
    case expired
    case httpStatus(Int)
}

protocol SessionDownloadTransport: Sendable {
    func download(from url: URL) async throws -> URL
}

struct URLSessionDownloadTransport: SessionDownloadTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func download(from url: URL) async throws -> URL {
        let (tempURL, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tempURL)
            throw DownloadTransportError.httpStatus(-1)
        }
        if http.statusCode == 403 {
            try? FileManager.default.removeItem(at: tempURL)
            throw DownloadTransportError.expired
        }
        guard (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw DownloadTransportError.httpStatus(http.statusCode)
        }
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("catalog-dl-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }
}

enum SessionDownloadError: Error, Equatable {
    case busy
    case expired
    case refreshFailed
    case missingFileAfterRefresh
    case cancelled
}

@MainActor
@Observable
final class SessionDownloader {
    enum State {
        case idle
        case downloading(Progress)
        case failed(resumable: Bool)
        case finished
    }

    private(set) var state: State = .idle
    private(set) var progress: Progress?
    private(set) var activeServerID: UUID?

    @ObservationIgnored private let client: CatalogClient
    @ObservationIgnored private let staging: CatalogStaging
    @ObservationIgnored private let transport: any SessionDownloadTransport

    init(client: CatalogClient, staging: CatalogStaging, transport: any SessionDownloadTransport) {
        self.client = client
        self.staging = staging
        self.transport = transport
    }

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    var isFinished: Bool {
        if case .finished = state { return true }
        return false
    }

    var failureResumable: Bool? {
        if case let .failed(resumable) = state { return resumable }
        return nil
    }

    func resetProgress() {
        progress = nil
        state = .idle
    }

    func start(serverID: UUID, files: [CatalogFileRequest], into external: Progress? = nil) async throws {
        guard activeServerID == nil else { throw SessionDownloadError.busy }
        activeServerID = serverID
        defer { activeServerID = nil }

        let progress = external ?? Progress(totalUnitCount: files.reduce(0) { $0 + $1.size })
        self.progress = progress
        state = .downloading(progress)

        var remaining = files
        var didRefresh = false

        while let file = remaining.first {
            if await staging.isStaged(serverID: serverID, sha256: file.sha256, filename: file.filename) {
                progress.completedUnitCount += file.size
                remaining.removeFirst()
                continue
            }
            do {
                try Task.checkCancellation()
                let temp = try await transport.download(from: file.url)
                defer { try? FileManager.default.removeItem(at: temp) }
                try await staging.commit(
                    tempURL: temp, serverID: serverID, sha256: file.sha256, filename: file.filename
                )
                progress.completedUnitCount += file.size
                remaining.removeFirst()
            } catch is CancellationError {
                state = .failed(resumable: true)
                throw SessionDownloadError.cancelled
            } catch DownloadTransportError.expired {
                guard !didRefresh else {
                    state = .failed(resumable: true)
                    throw SessionDownloadError.expired
                }
                didRefresh = true
                remaining = try await refreshedRequests(serverID: serverID, remaining: remaining)
            } catch {
                state = .failed(resumable: true)
                throw error
            }
        }

        state = .finished
    }

    private func refreshedRequests(
        serverID: UUID, remaining: [CatalogFileRequest]
    ) async throws -> [CatalogFileRequest] {
        let detail: CatalogSessionDetail
        do {
            detail = try await client.fetchSession(id: serverID)
        } catch {
            state = .failed(resumable: true)
            throw SessionDownloadError.refreshFailed
        }

        var urlBySHA: [String: URL] = [:]
        for track in detail.tracks {
            urlBySHA[track.sha256.lowercased()] = track.url
        }
        urlBySHA[detail.subtitle.sha256.lowercased()] = detail.subtitle.url
        if let clip = detail.clip {
            urlBySHA[clip.sha256.lowercased()] = clip.url
        }

        return try remaining.map { file in
            guard let fresh = urlBySHA[file.sha256.lowercased()] else {
                state = .failed(resumable: true)
                throw SessionDownloadError.missingFileAfterRefresh
            }
            return CatalogFileRequest(filename: file.filename, size: file.size, sha256: file.sha256, url: fresh)
        }
    }
}
