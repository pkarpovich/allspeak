import Foundation

// MARK: - Wire protocol contract
//
// This file is the contract between the iOS host (`Allspeak`) and the
// watchOS remote (`AllspeakWatch`). The types and their property-list
// encodings MUST stay binary-compatible between the two targets that share
// this source file — if you change a type here, both apps need to be
// reinstalled together. The in-payload `revision` field on SessionMetadata
// orders snapshots against the metadata they belong to.
//
// Commands (Watch -> iPhone):
//
//   .play, .pause, .togglePlayPause   transport-style controls
//   .skip(seconds:)                   ±0.5s / ±3s coalesced taps
//   .seek(time:)                      tap-on-cue jumps
//   .switchTrack(id:)                 swap active AudioTrack on the host
//                                     session (preserves currentTime +
//                                     isPlaying; ~100-300ms reload gap)
//   .setVolume(Float)                 watch Digital Crown -> AVAudioPlayer
//                                     volume (0...1, clamped); throttled
//                                     trailing-edge on the watch side
//   .startListening(listenID:)        start the phone listener for the active
//                                     session's fingerprint; the phone then
//                                     pushes ListenUpdates (see below) tagged
//                                     with this attempt's listenID
//   .cancelListening(listenID:)       stop the phone listener when it still
//                                     runs this attempt; a late retry for an
//                                     older attempt leaves a newer one alone
//   .listenEvent(ListenUpdate)        a phase of the watch's own listener
//                                     (source watch); the phone only logs it
//   .applySync(sessionID:,            seek to a match: the phone computes
//              trackTime:,            trackTime + (now - matchDate) +
//              matchDate:, source:,   outputLatency and seeks with the sync
//              sha256:)               source, only when sessionID is still the
//                                     active session and sha256 its fingerprint
//   .watchDownload(WatchDownloadEvent) a phase of the watch's catalog download
//                                     (subtitle or fingerprint); the phone only
//                                     logs it
//   .watchSamples(WatchListenTelemetry) memory and device samples taken during
//                                     one watch listen; the phone only logs them
//   .watchAborted(WatchListenTelemetry) a watch listen whose process died before
//                                     it finished, found on the next launch
//   .syncMark(SyncMark)               the user marked the dub out of sync on the
//                                     watch; the phone only logs it
//
// Metadata (iPhone -> Watch) carries the full track list so the watch
// can render its TrackListView without a separate request:
//
//   SessionMetadata.tracks: [TrackInfo]   (id + label, ordered by sortOrder)
//   SessionMetadata.activeTrackID: UUID?  (nil only for legacy single-track
//                                          sessions still on the v1 store)
//   SessionMetadata.serverDate: Date?     (wall-clock anchor for the watch's
//                                          progress extrapolation; decodeIfPresent,
//                                          nil from older builds without an anchor)
//   SessionMetadata.fingerprintSHA: String?  (sha256 of the session's ShazamKit
//                                             catalog; decodeIfPresent, nil when
//                                             the session has none or the build
//                                             predates cinema listen)
//   SessionMetadata.catalogID: UUID?         (allspeak-catalog session id and the
//   SessionMetadata.subtitleSHA: String?      sha256 of its subtitle; the watch
//                                             downloads the subtitle and the
//                                             fingerprint from the catalog by
//                                             these, see WatchCatalogDownloader)
//
// Transports (one-way arrows reflect actual reachability semantics):
//
//   iPhone --updateApplicationContext--> Watch   SessionMetadata
//       small, latest-state-wins; replaces any previously delivered context.
//       Rebroadcast on every switchTrack so the watch checkmark stays in
//       sync with the iPhone-side selection, and on playback state changes
//       (play/pause/seek/skip) so the latest-wins serverDate anchor is
//       fresh on the watch's next wake.
//
//   iPhone --sendMessage (no reply)-----> Watch   PlaybackSnapshot
//       fire-and-forget, 1Hz while reachable + playing; dropped silently
//       when watch is asleep or out of range
//
//   iPhone --sendMessage (no reply)-----> Watch   ListenUpdate
//       every phase of the phone listener (source phone) after a
//       startListening, tagged with its listenID; the watch drops updates
//       of any other attempt. While the watch is not reachable the latest one is
//       held and re-sent when it becomes reachable; session end drops it.
//       Optional fields (trackTime, matchDate, chunkStart, error) are omitted
//       when nil, so older and newer builds decode each other.
//
//   Watch  --transferUserInfo-----------> iPhone  WatchCommand (log only)
//       .listenEvent, .watchDownload, .watchSamples, .watchAborted, .syncMark; queued
//       while the phone is unreachable and delivered in order later, so each
//       carries its own eventDate / sample dates
//
//   Watch  --sendMessage (with reply)---> iPhone  WatchCommand
//       reply payload is a PlaybackSnapshot so the watch stays fresh after
//       every user action;
//       applySync replies with PlaybackSnapshot.empty when it did not seek
//       this is the only path that wakes the iOS app from background
//
// Wrapper dictionary shape (see WirePayloadKey / WirePayloadKind):
//
//   ["kind": "<command|snapshot|metadata|listenUpdate>", "payload": <Data: JSON>]
//
// The JSON-inside-Data wrapper exists because WCSession dictionaries are
// property-list-only (no nested Codable), and a single discriminator key
// lets the receiver route to the correct decoder without sniffing fields.
//
// Files (subtitle, fingerprint) never travel over WatchConnectivity: the watch
// downloads them from allspeak-catalog with URLSession.
//
// Adding a new command:
//   1. Add a case to `WatchCommand` + its `Kind` discriminator.
//   2. Extend the encode/decode switches above with the new associated
//      values and CodingKeys.
//   3. Extend `WatchSessionHost.dispatch(_:)` (iOS) to dispatch it to the
//      `PlaybackCoordinator`.
//   4. Watch-side UI sends it through `WatchSessionClient.send(_:)`.
//   5. Old binaries will throw `DecodingError` on the unknown kind, which
//      is acceptable — the watch retries on next user tap.

enum WatchCommand: Codable, Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case skip(seconds: Double)
    case seek(time: Double)
    case switchTrack(id: UUID)
    case setVolume(Float)
    case startListening(listenID: UUID)
    case cancelListening(listenID: UUID)
    case listenEvent(ListenUpdate)
    case applySync(sessionID: UUID, trackTime: Double, matchDate: Date, source: ListenSource, sha256: String)
    case watchDownload(WatchDownloadEvent)
    case watchSamples(WatchListenTelemetry)
    case watchAborted(WatchListenTelemetry)
    case syncMark(SyncMark)

    private enum CodingKeys: String, CodingKey {
        case kind
        case seconds
        case time
        case trackID
        case volume
        case sessionID
        case sha256
        case update
        case trackTime
        case matchDate
        case source
        case listenID
        case download
        case telemetry
        case mark
    }

    private enum Kind: String, Codable {
        case play
        case pause
        case togglePlayPause
        case skip
        case seek
        case switchTrack
        case setVolume
        case startListening
        case cancelListening
        case listenEvent
        case applySync
        case watchDownload
        case watchSamples
        case watchAborted
        case syncMark
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .play:
            try container.encode(Kind.play, forKey: .kind)
        case .pause:
            try container.encode(Kind.pause, forKey: .kind)
        case .togglePlayPause:
            try container.encode(Kind.togglePlayPause, forKey: .kind)
        case .skip(let seconds):
            try container.encode(Kind.skip, forKey: .kind)
            try container.encode(seconds, forKey: .seconds)
        case .seek(let time):
            try container.encode(Kind.seek, forKey: .kind)
            try container.encode(time, forKey: .time)
        case .switchTrack(let id):
            try container.encode(Kind.switchTrack, forKey: .kind)
            try container.encode(id, forKey: .trackID)
        case .setVolume(let volume):
            try container.encode(Kind.setVolume, forKey: .kind)
            try container.encode(volume, forKey: .volume)
        case .startListening(let listenID):
            try container.encode(Kind.startListening, forKey: .kind)
            try container.encode(listenID, forKey: .listenID)
        case .cancelListening(let listenID):
            try container.encode(Kind.cancelListening, forKey: .kind)
            try container.encode(listenID, forKey: .listenID)
        case .listenEvent(let update):
            try container.encode(Kind.listenEvent, forKey: .kind)
            try container.encode(update, forKey: .update)
        case .applySync(let sessionID, let trackTime, let matchDate, let source, let sha256):
            try container.encode(Kind.applySync, forKey: .kind)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(trackTime, forKey: .trackTime)
            try container.encode(matchDate, forKey: .matchDate)
            try container.encode(source, forKey: .source)
            try container.encode(sha256, forKey: .sha256)
        case .watchDownload(let event):
            try container.encode(Kind.watchDownload, forKey: .kind)
            try container.encode(event, forKey: .download)
        case .watchSamples(let telemetry):
            try container.encode(Kind.watchSamples, forKey: .kind)
            try container.encode(telemetry, forKey: .telemetry)
        case .watchAborted(let telemetry):
            try container.encode(Kind.watchAborted, forKey: .kind)
            try container.encode(telemetry, forKey: .telemetry)
        case .syncMark(let mark):
            try container.encode(Kind.syncMark, forKey: .kind)
            try container.encode(mark, forKey: .mark)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .play:
            self = .play
        case .pause:
            self = .pause
        case .togglePlayPause:
            self = .togglePlayPause
        case .skip:
            self = .skip(seconds: try container.decode(Double.self, forKey: .seconds))
        case .seek:
            self = .seek(time: try container.decode(Double.self, forKey: .time))
        case .switchTrack:
            self = .switchTrack(id: try container.decode(UUID.self, forKey: .trackID))
        case .setVolume:
            self = .setVolume(try container.decode(Float.self, forKey: .volume))
        case .startListening:
            self = .startListening(listenID: try container.decode(UUID.self, forKey: .listenID))
        case .cancelListening:
            self = .cancelListening(listenID: try container.decode(UUID.self, forKey: .listenID))
        case .listenEvent:
            self = .listenEvent(try container.decode(ListenUpdate.self, forKey: .update))
        case .applySync:
            self = .applySync(
                sessionID: try container.decode(UUID.self, forKey: .sessionID),
                trackTime: try container.decode(Double.self, forKey: .trackTime),
                matchDate: try container.decode(Date.self, forKey: .matchDate),
                source: try container.decode(ListenSource.self, forKey: .source),
                sha256: try container.decode(String.self, forKey: .sha256)
            )
        case .watchDownload:
            self = .watchDownload(try container.decode(WatchDownloadEvent.self, forKey: .download))
        case .watchSamples:
            self = .watchSamples(try container.decode(WatchListenTelemetry.self, forKey: .telemetry))
        case .watchAborted:
            self = .watchAborted(try container.decode(WatchListenTelemetry.self, forKey: .telemetry))
        case .syncMark:
            self = .syncMark(try container.decode(SyncMark.self, forKey: .mark))
        }
    }
}

struct TrackInfo: Codable, Equatable, Sendable, Hashable, Identifiable {
    let id: UUID
    let label: String
}

struct SessionMetadata: Codable, Equatable, Sendable {
    let sessionID: UUID
    let revision: Int
    let title: String
    let duration: Double
    let cueCount: Int
    let isPlaying: Bool
    let currentTime: Double
    let tracks: [TrackInfo]
    let activeTrackID: UUID?
    let serverDate: Date?
    let fingerprintSHA: String?
    let catalogID: UUID?
    let subtitleSHA: String?

    init(
        sessionID: UUID,
        revision: Int,
        title: String,
        duration: Double,
        cueCount: Int,
        isPlaying: Bool,
        currentTime: Double,
        tracks: [TrackInfo] = [],
        activeTrackID: UUID? = nil,
        serverDate: Date? = nil,
        fingerprintSHA: String? = nil,
        catalogID: UUID? = nil,
        subtitleSHA: String? = nil
    ) {
        self.sessionID = sessionID
        self.revision = revision
        self.title = title
        self.duration = duration
        self.cueCount = cueCount
        self.isPlaying = isPlaying
        self.currentTime = currentTime
        self.tracks = tracks
        self.activeTrackID = activeTrackID
        self.serverDate = serverDate
        self.fingerprintSHA = fingerprintSHA
        self.catalogID = catalogID
        self.subtitleSHA = subtitleSHA
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, revision, title, duration, cueCount, isPlaying, currentTime, tracks, activeTrackID, serverDate
        case fingerprintSHA, catalogID, subtitleSHA
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionID = try container.decode(UUID.self, forKey: .sessionID)
        self.revision = try container.decode(Int.self, forKey: .revision)
        self.title = try container.decode(String.self, forKey: .title)
        self.duration = try container.decode(Double.self, forKey: .duration)
        self.cueCount = try container.decode(Int.self, forKey: .cueCount)
        self.isPlaying = try container.decode(Bool.self, forKey: .isPlaying)
        self.currentTime = try container.decode(Double.self, forKey: .currentTime)
        self.tracks = try container.decodeIfPresent([TrackInfo].self, forKey: .tracks) ?? []
        self.activeTrackID = try container.decodeIfPresent(UUID.self, forKey: .activeTrackID)
        self.serverDate = try container.decodeIfPresent(Date.self, forKey: .serverDate)
        self.fingerprintSHA = try container.decodeIfPresent(String.self, forKey: .fingerprintSHA)
        self.catalogID = try container.decodeIfPresent(UUID.self, forKey: .catalogID)
        self.subtitleSHA = try container.decodeIfPresent(String.self, forKey: .subtitleSHA)
    }
}

struct WatchDownloadEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case subtitle
        case fingerprint
    }

    enum Phase: String, Codable, Sendable {
        case start
        case done
        case failed
    }

    let kind: Kind
    let phase: Phase
    let sha256: String
    let attempt: Int
    let bytes: Int?
    let seconds: Double?
    let error: String?
    var eventDate: Date?

    init(kind: Kind, phase: Phase, sha256: String, attempt: Int, bytes: Int? = nil, seconds: Double? = nil, error: String? = nil, eventDate: Date? = nil) {
        self.kind = kind
        self.phase = phase
        self.sha256 = sha256
        self.attempt = attempt
        self.bytes = bytes
        self.seconds = seconds
        self.error = error
        self.eventDate = eventDate
    }
}

struct WatchSample: Codable, Equatable, Sendable {
    let date: Date
    let listenSeconds: Double
    let virtualMB: Double
    let footprintMB: Double
    let availableMB: Double
    let appState: String
    let thermalState: String
    let lowPower: Bool
    let battery: Double?
}

struct SyncMark: Codable, Equatable, Sendable {
    let eventDate: Date
    let position: Double
}

struct WatchListenTelemetry: Codable, Equatable, Sendable {
    let listenID: UUID
    let startedAt: Date
    var samples: [WatchSample]
}

struct ListenUpdate: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case start
        case match
        case nomatch
        case timeout
        case cancel
        case interrupted
        case failed
    }

    let listenID: UUID
    let source: ListenSource
    let phase: Phase
    let trackTime: Double?
    let matchDate: Date?
    let chunkStart: Double?
    let listenSeconds: Double
    let error: String?
    let frequencySkew: Double?
    var eventDate: Date?

    init(
        listenID: UUID,
        source: ListenSource,
        phase: Phase,
        trackTime: Double? = nil,
        matchDate: Date? = nil,
        chunkStart: Double? = nil,
        listenSeconds: Double,
        error: String? = nil,
        frequencySkew: Double? = nil,
        eventDate: Date? = nil
    ) {
        self.listenID = listenID
        self.source = source
        self.phase = phase
        self.trackTime = trackTime
        self.matchDate = matchDate
        self.chunkStart = chunkStart
        self.listenSeconds = listenSeconds
        self.error = error
        self.frequencySkew = frequencySkew
        self.eventDate = eventDate
    }

    init(listenID: UUID, source: ListenSource, event: ListenEvent) {
        switch event.phase {
        case .started:
            self.init(listenID: listenID, source: source, phase: .start, listenSeconds: event.listenSeconds)
        case .matched(let match):
            self.init(
                listenID: listenID,
                source: source,
                phase: .match,
                trackTime: match.trackTime,
                matchDate: match.matchDate,
                chunkStart: match.chunkStart,
                listenSeconds: event.listenSeconds,
                frequencySkew: match.frequencySkew
            )
        case .noMatch:
            self.init(listenID: listenID, source: source, phase: .nomatch, listenSeconds: event.listenSeconds)
        case .timedOut:
            self.init(listenID: listenID, source: source, phase: .timeout, listenSeconds: event.listenSeconds)
        case .cancelled:
            self.init(listenID: listenID, source: source, phase: .cancel, listenSeconds: event.listenSeconds)
        case .interrupted:
            self.init(listenID: listenID, source: source, phase: .interrupted, listenSeconds: event.listenSeconds)
        case .failed(let message):
            self.init(listenID: listenID, source: source, phase: .failed, listenSeconds: event.listenSeconds, error: message)
        }
    }

    var event: ListenEvent? {
        let phase: ListenEvent.Phase
        switch self.phase {
        case .start:
            phase = .started
        case .match:
            guard let trackTime, let matchDate else { return nil }
            phase = .matched(FingerprintMatch(trackTime: trackTime, matchDate: matchDate, chunkStart: chunkStart ?? 0, frequencySkew: frequencySkew))
        case .nomatch:
            phase = .noMatch
        case .timeout:
            phase = .timedOut
        case .cancel:
            phase = .cancelled
        case .interrupted:
            phase = .interrupted
        case .failed:
            phase = .failed(error ?? "")
        }
        return ListenEvent(phase: phase, listenSeconds: listenSeconds)
    }
}

enum WirePayloadKey {
    static let payload = "payload"
    static let kind = "kind"
}

enum WirePayloadKind: String {
    case command
    case snapshot
    case metadata
    case sessionEnded
    case listenUpdate
}

enum SessionEndedSignal {
    static func propertyList() -> [String: Any] {
        [WirePayloadKey.kind: WirePayloadKind.sessionEnded.rawValue]
    }

    static func isSessionEnded(_ context: [String: Any]) -> Bool {
        (context[WirePayloadKey.kind] as? String) == WirePayloadKind.sessionEnded.rawValue
    }
}

enum WireCodingError: Error {
    case missingPayload
    case kindMismatch
    case compressionFailed
}

nonisolated(unsafe) private let wireDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let wireJSONEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(wireDateFormatter.string(from: date))
    }
    return encoder
}()

private let wireJSONDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let date = wireDateFormatter.date(from: string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO 8601 date with fractional seconds: \(string)"
            )
        }
        return date
    }
    return decoder
}()

extension WatchCommand {
    func toPropertyList() throws -> [String: Any] {
        let data = try wireJSONEncoder.encode(self)
        return [
            WirePayloadKey.kind: WirePayloadKind.command.rawValue,
            WirePayloadKey.payload: data,
        ]
    }

    init(propertyList: [String: Any]) throws {
        guard (propertyList[WirePayloadKey.kind] as? String) == WirePayloadKind.command.rawValue else {
            throw WireCodingError.kindMismatch
        }
        guard let data = propertyList[WirePayloadKey.payload] as? Data else {
            throw WireCodingError.missingPayload
        }
        self = try wireJSONDecoder.decode(WatchCommand.self, from: data)
    }
}

extension PlaybackSnapshot {
    func toPropertyList() throws -> [String: Any] {
        let data = try wireJSONEncoder.encode(self)
        return [
            WirePayloadKey.kind: WirePayloadKind.snapshot.rawValue,
            WirePayloadKey.payload: data,
        ]
    }

    init(propertyList: [String: Any]) throws {
        guard (propertyList[WirePayloadKey.kind] as? String) == WirePayloadKind.snapshot.rawValue else {
            throw WireCodingError.kindMismatch
        }
        guard let data = propertyList[WirePayloadKey.payload] as? Data else {
            throw WireCodingError.missingPayload
        }
        self = try wireJSONDecoder.decode(PlaybackSnapshot.self, from: data)
    }
}

extension SessionMetadata {
    func toPropertyList() throws -> [String: Any] {
        let data = try wireJSONEncoder.encode(self)
        return [
            WirePayloadKey.kind: WirePayloadKind.metadata.rawValue,
            WirePayloadKey.payload: data,
        ]
    }

    init(propertyList: [String: Any]) throws {
        guard (propertyList[WirePayloadKey.kind] as? String) == WirePayloadKind.metadata.rawValue else {
            throw WireCodingError.kindMismatch
        }
        guard let data = propertyList[WirePayloadKey.payload] as? Data else {
            throw WireCodingError.missingPayload
        }
        self = try wireJSONDecoder.decode(SessionMetadata.self, from: data)
    }
}

extension ListenUpdate {
    func toPropertyList() throws -> [String: Any] {
        let data = try wireJSONEncoder.encode(self)
        return [
            WirePayloadKey.kind: WirePayloadKind.listenUpdate.rawValue,
            WirePayloadKey.payload: data,
        ]
    }

    init(propertyList: [String: Any]) throws {
        guard (propertyList[WirePayloadKey.kind] as? String) == WirePayloadKind.listenUpdate.rawValue else {
            throw WireCodingError.kindMismatch
        }
        guard let data = propertyList[WirePayloadKey.payload] as? Data else {
            throw WireCodingError.missingPayload
        }
        self = try wireJSONDecoder.decode(ListenUpdate.self, from: data)
    }
}

