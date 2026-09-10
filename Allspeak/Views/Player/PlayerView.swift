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

    @State private var controller: AudioController?
    @State private var sessionName: String = ""
    @State private var tracks: [TrackInfo] = []
    @State private var activeTrackID: UUID?
    @State private var loadError: String?
    @State private var cinema: CinemaMode = .off

    private let repository: SessionRepository

    init(sessionID: NSManagedObjectID, repository: SessionRepository? = nil) {
        self.sessionID = sessionID
        self.repository = repository ?? SessionRepository()
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
            } else if let controller {
                SubtitleRiverView(
                    cues: controller.subtitles,
                    currentIndex: controller.currentIndex,
                    cinema: cinema,
                    onSeek: {
                        PlaybackCoordinator.shared.seek(to: $0)
                        PlaybackCoordinator.shared.play()
                    },
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

            if !cinema.hidesChrome, let controller {
                VStack(spacing: 0) {
                    PlayerTopBar(
                        sessionName: sessionName,
                        cinemaActive: cinema.isCinema,
                        tracks: tracks,
                        activeTrackID: activeTrackID,
                        onBack: { dismiss() },
                        onCinema: { applyCinema(.pill) },
                        onSwitchTrack: switchTrack
                    )
                    .padding(.top, 18)

                    Spacer(minLength: 0)

                    PlayerControlsView(
                        currentTime: controller.currentTime,
                        duration: controller.duration,
                        isPlaying: controller.isPlaying,
                        onPlayPause: { PlaybackCoordinator.shared.togglePlayPause() },
                        onSkipBack: { PlaybackCoordinator.shared.skip(by: -0.5) },
                        onSkipForward: { PlaybackCoordinator.shared.skip(by: 0.5) },
                        onScrub: { PlaybackCoordinator.shared.seek(to: $0) }
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
        .toolbar(.hidden, for: .navigationBar, .tabBar)
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
            controller = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: PlaybackCoordinator.activeTrackChangedNotification)) { _ in
            tracks = PlaybackCoordinator.shared.tracks
            activeTrackID = PlaybackCoordinator.shared.activeTrackID
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                if let controller {
                    Task { await controller.persistPosition() }
                }
            case .active:
                controller?.syncCurrentTime()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    private func switchTrack(_ trackID: UUID) {
        Task {
            try? await PlaybackCoordinator.shared.switchTrack(to: trackID)
            activeTrackID = PlaybackCoordinator.shared.activeTrackID
        }
    }

    private func applyCinema(_ input: CinemaInput) {
        withAnimation(.easeInOut(duration: 0.25)) {
            cinema.apply(input)
        }
    }

    private func loadSession() async {
        do {
            try await PlaybackCoordinator.shared.startSession(sessionID: sessionID, repository: repository)
            controller = PlaybackCoordinator.shared.controller
            sessionName = PlaybackCoordinator.shared.sessionTitle
            tracks = PlaybackCoordinator.shared.tracks
            activeTrackID = PlaybackCoordinator.shared.activeTrackID
        } catch PlaybackCoordinator.StartError.sessionNotFound {
            loadError = "Couldn't load session."
        } catch PlaybackCoordinator.StartError.noCues {
            loadError = "Subtitle file has no cues — pick a valid .srt."
        } catch {
            loadError = "Couldn't open audio or subtitles."
        }
    }
}
