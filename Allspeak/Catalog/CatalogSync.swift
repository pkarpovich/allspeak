import CoreData
import Foundation

private struct TrackKey: Hashable {
    let sha256: String
    let label: String

    init(sha256: String, label: String) {
        self.sha256 = sha256.lowercased()
        self.label = label
    }
}

struct SyncFileRow: Equatable, Sendable {
    let filename: String
    let size: Int64
    let changed: Bool
}

struct SyncPlan: Equatable, Sendable {
    let newTitle: String?
    let replaceSubtitle: CatalogSubtitle?
    let addTracks: [CatalogTrack]
    let removeTrackIDs: [UUID]
    let downloadRequests: [CatalogFileRequest]
    let fileRows: [SyncFileRow]
    let revisionChanged: Bool

    var downloadBytes: Int64 {
        downloadRequests.reduce(0) { $0 + $1.size }
    }

    // A revision bump with no file/title diff (e.g. the default track moved) still needs a
    // sync: the applier unconditionally re-asserts the default track and writes the new sidecar
    // revision, so without this the Update affordance would never clear.
    var hasChanges: Bool {
        newTitle != nil
            || replaceSubtitle != nil
            || !addTracks.isEmpty
            || !removeTrackIDs.isEmpty
            || revisionChanged
    }

    init(sidecar: CatalogSidecar, manifest: CatalogSessionDetail, currentTitle: String) {
        let orderedTracks = manifest.tracks.sorted { $0.sortOrder < $1.sortOrder }
        let sidecarKeys = Set(sidecar.tracks.map { TrackKey(sha256: $0.sha256, label: $0.label) })
        let manifestKeys = Set(orderedTracks.map { TrackKey(sha256: $0.sha256, label: $0.label) })

        let added = orderedTracks.filter { !sidecarKeys.contains(TrackKey(sha256: $0.sha256, label: $0.label)) }
        let removed = sidecar.tracks
            .filter { !manifestKeys.contains(TrackKey(sha256: $0.sha256, label: $0.label)) }
            .map(\.trackID)

        let subtitleChanged = manifest.subtitle.sha256.lowercased() != sidecar.subtitle.sha256.lowercased()
        let subtitle = subtitleChanged ? manifest.subtitle : nil

        var requests = added.map { CatalogFileRequest(track: $0) }
        if let subtitle {
            requests.append(CatalogFileRequest(subtitle: subtitle))
        }

        var rows = orderedTracks.map { track in
            SyncFileRow(
                filename: track.filename,
                size: track.size,
                changed: !sidecarKeys.contains(TrackKey(sha256: track.sha256, label: track.label))
            )
        }
        rows.append(
            SyncFileRow(filename: manifest.subtitle.filename, size: manifest.subtitle.size, changed: subtitleChanged)
        )

        self.newTitle = manifest.title == currentTitle ? nil : manifest.title
        self.replaceSubtitle = subtitle
        self.addTracks = added
        self.removeTrackIDs = removed
        self.downloadRequests = requests
        self.fileRows = rows
        self.revisionChanged = manifest.revision != sidecar.revision
    }
}

enum CatalogSyncError: Error, Equatable {
    case trackResolutionFailed
}

struct CatalogSyncApplier: Sendable {
    let repository: SessionRepository
    let staging: CatalogStaging
    let storage: DocumentsStorage

    func apply(
        plan: SyncPlan,
        detail: CatalogSessionDetail,
        sessionID: NSManagedObjectID,
        sidecar: CatalogSidecar
    ) async throws {
        let serverID = detail.id

        // Add before remove: a revision that replaces every track would otherwise hit
        // removeTrack's lastTrackCannotBeRemoved guard if removals ran first.
        var keyToTrackID: [TrackKey: UUID] = [:]
        for track in plan.addTracks {
            let srcURL = staging.stagedURL(serverID: serverID, sha256: track.sha256, filename: track.filename)
            let newTrackID = try await repository.addTrackImporting(
                sessionID: sessionID, srcURL: srcURL, label: track.label
            )
            keyToTrackID[TrackKey(sha256: track.sha256, label: track.label)] = newTrackID
        }

        if !plan.removeTrackIDs.isEmpty {
            let objectIDByTrackID = Dictionary(
                try await repository.tracks(for: sessionID).map { ($0.trackID, $0.id) },
                uniquingKeysWith: { first, _ in first }
            )
            for trackID in plan.removeTrackIDs {
                guard let objectID = objectIDByTrackID[trackID] else { continue }
                try await repository.removeTrack(id: objectID)
            }
        }

        if let subtitle = plan.replaceSubtitle {
            let srcURL = staging.stagedURL(serverID: serverID, sha256: subtitle.sha256, filename: subtitle.filename)
            try await repository.replaceSubtitle(id: sessionID, srcURL: srcURL)
        }

        if let newTitle = plan.newTitle {
            try await repository.rename(id: sessionID, to: newTitle)
        }

        for old in sidecar.tracks {
            let key = TrackKey(sha256: old.sha256, label: old.label)
            if keyToTrackID[key] == nil {
                keyToTrackID[key] = old.trackID
            }
        }

        let orderedTracks = detail.tracks.sorted { $0.sortOrder < $1.sortOrder }
        var sidecarTracks: [CatalogSidecar.Track] = []
        for track in orderedTracks {
            guard let trackID = keyToTrackID[TrackKey(sha256: track.sha256, label: track.label)] else {
                throw CatalogSyncError.trackResolutionFailed
            }
            sidecarTracks.append(
                CatalogSidecar.Track(
                    filename: track.filename,
                    sha256: track.sha256.lowercased(),
                    label: track.label,
                    trackID: trackID
                )
            )
        }

        let defaultTrack = orderedTracks.first(where: \.isDefault) ?? orderedTracks.first
        guard let defaultTrack,
              let defaultTrackID = keyToTrackID[TrackKey(sha256: defaultTrack.sha256, label: defaultTrack.label)] else {
            throw CatalogSyncError.trackResolutionFailed
        }
        try await repository.setActiveTrack(sessionID: sessionID, trackID: defaultTrackID)

        let newSidecar = CatalogSidecar(
            serverID: serverID,
            revision: detail.revision,
            subtitle: CatalogSidecar.Subtitle(
                filename: detail.subtitle.filename,
                sha256: detail.subtitle.sha256.lowercased()
            ),
            tracks: sidecarTracks
        )
        let sessionUUID = try await repository.sessionUUID(id: sessionID)
        try newSidecar.save(to: storage.sessionDir(for: sessionUUID))

        try staging.clear(serverID: serverID)
    }
}
