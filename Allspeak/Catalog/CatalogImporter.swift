import CoreData
import Foundation

struct CatalogImporter: Sendable {
    let repository: SessionRepository
    let staging: CatalogStaging
    let storage: DocumentsStorage

    @discardableResult
    func run(detail: CatalogSessionDetail) async throws -> NSManagedObjectID {
        let serverID = detail.id
        let orderedTracks = detail.tracks.sorted { $0.sortOrder < $1.sortOrder }

        let audioSources = orderedTracks.map { track in
            PendingTrackImport(
                url: staging.stagedURL(serverID: serverID, sha256: track.sha256, filename: track.filename),
                label: track.label
            )
        }
        let srtSrc = staging.stagedURL(
            serverID: serverID, sha256: detail.subtitle.sha256, filename: detail.subtitle.filename
        )

        let sessionID = try await repository.importMultiTrackSession(
            name: detail.title,
            audioSources: audioSources,
            srtSrc: srtSrc
        )

        let snapshots = try await repository.tracks(for: sessionID)
        let defaultIndex = orderedTracks.firstIndex(where: \.isDefault) ?? 0
        try await repository.setActiveTrack(sessionID: sessionID, trackID: snapshots[defaultIndex].trackID)

        let sidecarTracks = zip(orderedTracks, snapshots).map { manifest, snapshot in
            CatalogSidecar.Track(
                filename: manifest.filename,
                sha256: manifest.sha256.lowercased(),
                label: manifest.label,
                trackID: snapshot.trackID
            )
        }
        let sidecar = CatalogSidecar(
            serverID: serverID,
            revision: detail.revision,
            subtitle: CatalogSidecar.Subtitle(
                filename: detail.subtitle.filename,
                sha256: detail.subtitle.sha256.lowercased()
            ),
            tracks: sidecarTracks
        )
        let sessionUUID = try await repository.sessionUUID(id: sessionID)
        try sidecar.save(to: storage.sessionDir(for: sessionUUID))

        try staging.clear(serverID: serverID)
        return sessionID
    }
}
