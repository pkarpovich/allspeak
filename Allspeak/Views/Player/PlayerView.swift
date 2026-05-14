import CoreData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct PlayerView: View {
    let sessionID: NSManagedObjectID

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @State private var controller: AudioController
    @State private var sessionName: String = ""
    @State private var loadError: String?
    @State private var cinemaActive: Bool = false

    init(sessionID: NSManagedObjectID, repository: SessionRepository? = nil) {
        self.sessionID = sessionID
        let repo = repository ?? SessionRepository()
        _controller = State(initialValue: AudioController(repository: repo, sessionID: sessionID))
    }

    var body: some View {
        ZStack {
            Tokens.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                PlayerTopBar(
                    sessionName: sessionName,
                    cinemaActive: cinemaActive,
                    onBack: { dismiss() },
                    onCinema: { cinemaActive.toggle() }
                )
                .padding(.top, 18)

                if let loadError {
                    Spacer()
                    Text(loadError)
                        .font(Tokens.Font.mono)
                        .foregroundStyle(Tokens.text3)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                } else {
                    SubtitleRiverView(
                        cues: controller.subtitles,
                        currentIndex: controller.currentIndex,
                        onSeek: { controller.seek(to: $0) }
                    )
                }

                PlayerControlsView(
                    currentTime: controller.currentTime,
                    duration: controller.duration,
                    isPlaying: controller.isPlaying,
                    onPlayPause: { controller.togglePlayPause() },
                    onSkipBack: { controller.skip(by: -15) },
                    onSkipForward: { controller.skip(by: 15) },
                    onScrub: { controller.seek(to: $0) }
                )
                .padding(.bottom, 28)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task { await loadSession() }
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
            let srtText = try String(contentsOf: srtURL, encoding: .utf8)
            let cues = SRTParser.parse(srtText)
            try controller.load(audio: audioURL, subtitles: cues)
            if let pos = snap.lastPosition, pos > 0, pos < controller.duration {
                controller.seek(to: pos)
            }
        } catch {
            loadError = "Couldn't open audio or subtitles."
        }
    }
}
