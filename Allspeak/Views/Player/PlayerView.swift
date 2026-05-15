import CoreData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct PlayerView: View {
    let sessionID: NSManagedObjectID

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var controller: AudioController
    @State private var sessionName: String = ""
    @State private var loadError: String?
    @State private var cinema: CinemaMode = .off

    init(sessionID: NSManagedObjectID, repository: SessionRepository? = nil) {
        self.sessionID = sessionID
        let repo = repository ?? SessionRepository()
        _controller = State(initialValue: AudioController(repository: repo, sessionID: sessionID))
    }

    var body: some View {
        ZStack {
            (cinema.usesDeepBackground ? Tokens.bgDeep : Tokens.bg)
                .ignoresSafeArea()

            if let loadError {
                Text(loadError)
                    .font(Tokens.Font.mono)
                    .foregroundStyle(Tokens.text3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SubtitleRiverView(
                    cues: controller.subtitles,
                    currentIndex: controller.currentIndex,
                    cinema: cinema,
                    onSeek: { controller.seek(to: $0) },
                    onCinemaInput: { applyCinema($0) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if cinema.isCinema {
                Color.black
                    .opacity(cinema.dimOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if !cinema.hidesChrome {
                VStack(spacing: 0) {
                    PlayerTopBar(
                        sessionName: sessionName,
                        cinemaActive: cinema.isCinema,
                        onBack: { dismiss() },
                        onCinema: { applyCinema(.pill) }
                    )
                    .padding(.top, 18)

                    Spacer(minLength: 0)

                    PlayerControlsView(
                        currentTime: controller.currentTime,
                        duration: controller.duration,
                        isPlaying: controller.isPlaying,
                        onPlayPause: { controller.togglePlayPause() },
                        onSkipBack: { controller.skip(by: -0.5) },
                        onSkipForward: { controller.skip(by: 0.5) },
                        onScrub: { controller.seek(to: $0) }
                    )
                    .padding(.bottom, 28)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(true)
                .transition(.opacity)
            }

            if cinema.showsExitChip {
                VStack {
                    Spacer()
                    Text("TAP TO EXIT CINEMA")
                        .font(Tokens.Font.monoSmall)
                        .tracking(1.4)
                        .foregroundStyle(Tokens.text3)
                        .padding(.bottom, 28)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task {
            AppAudioSession.activatePlayback()
            await loadSession()
        }
        .onAppear {
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
        }
        .onDisappear {
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
            controller.pause()
            Task { await controller.persistPosition() }
            #if os(iOS) || os(tvOS) || os(visionOS)
            NowPlayingCenter.shared.clear()
            #endif
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                Task { await controller.persistPosition() }
            case .active:
                controller.syncCurrentTime()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    private func applyCinema(_ input: CinemaInput) {
        withAnimation(.easeInOut(duration: 0.25)) {
            cinema.apply(input)
        }
    }

    private func loadSession() async {
        let context = viewContext
        let id = sessionID
        struct Snap: Sendable {
            let uuid: UUID
            let name: String
            let audioFilename: String
            let srtFilename: String
            let lastPosition: Double?
        }

        let snap: Snap
        do {
            snap = try await context.perform {
                let object = try context.existingObject(with: id)
                let uuid = (object.value(forKey: "id") as? UUID) ?? UUID()
                let name = (object.value(forKey: "name") as? String) ?? ""
                let audio = (object.value(forKey: "audioFilename") as? String) ?? ""
                let srt = (object.value(forKey: "srtFilename") as? String) ?? ""
                let pos = object.value(forKey: "lastPositionSeconds") as? Double
                return Snap(uuid: uuid, name: name, audioFilename: audio, srtFilename: srt, lastPosition: pos)
            }
        } catch {
            loadError = "Couldn't load session."
            return
        }

        sessionName = snap.name

        let dir = DocumentsStorage.default.sessionDir(for: snap.uuid)
        let audioURL = dir.appendingPathComponent(snap.audioFilename)
        let srtURL = dir.appendingPathComponent(snap.srtFilename)

        do {
            let srtText = try readSubtitleText(at: srtURL)
            let cues = SRTParser.parse(srtText)
            guard !cues.isEmpty else {
                loadError = "Subtitle file has no cues — pick a valid .srt."
                return
            }
            try controller.load(audio: audioURL, subtitles: cues, title: snap.name)
            if let pos = snap.lastPosition, pos > 0, pos < controller.duration {
                controller.seek(to: pos)
            }
        } catch {
            loadError = "Couldn't open audio or subtitles."
        }
    }

    private func readSubtitleText(at url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        for encoding: String.Encoding in [.windowsCP1252, .windowsCP1251, .isoLatin1] {
            if let text = try? String(contentsOf: url, encoding: encoding) {
                return text
            }
        }
        var usedEncoding: String.Encoding = .utf8
        return try String(contentsOf: url, usedEncoding: &usedEncoding)
    }
}
