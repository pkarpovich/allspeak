# Allspeak

Single-user, offline iOS app for cinema-goers who watch films in languages they
don't fully understand. Prepare a "session" by attaching a pre-extracted
original-language audio file (`.m4a`) and a subtitle file (`.srt`). In the
cinema, listen to the original audio through one AirPod while the on-screen
scrolling subtitle window acts as a visual sync anchor. Tapping any subtitle
line seeks the audio to that line's timestamp.

No offset arithmetic, no calibration, no cloud, no accounts, no onboarding,
no settings.

## Requirements

- macOS with Xcode 26+
- iOS 26+ target (device or simulator)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Build

```fish
xcodegen generate
open Allspeak.xcodeproj
```

Then in Xcode: pick the `Allspeak` scheme, choose a destination, and build /
run. There are no third-party Swift packages; all dependencies are system
frameworks (SwiftUI, AVFoundation, CoreData).

## Preparing files

The MVP does not bundle audio extraction. You supply the `.m4a` and `.srt`
pair yourself (e.g. via a Mac-side script that strips them from an MKV
source) and transfer them to the iPhone through the Files app, AirDrop, or
iCloud Drive. Inside Allspeak:

1. Tap `+` on the Sessions screen.
2. Name the session (e.g. `After the Light · 21:30`).
3. Tap `Choose audio files` and pick one or more `.m4a` files via the
   system file picker. Each file becomes a separate audio track on the
   session (e.g. `loudnorm-only`, `demucs+loudnorm`, `DFN v3`, or a
   different dubbing studio). Label each picked file before saving — the
   first track becomes the default.
4. Tap `Choose subtitles file` and pick the `.srt`. The subtitle timeline
   is shared across all tracks in the session.
5. Save.

Picked files are copied into the app's Documents container at
`Documents/sessions/<uuid>/track-<trackID>-<filename>` (one per track)
plus a single subtitles file, and are independent of the original source
location after import. To add more tracks to an existing session (e.g.
drop in a new dub when it becomes available), use the `Tracks` action in
the session row's context menu.

### Audio prep pipeline (`scripts/bifrost.fish`)

The `.m4a` voice track is produced by `scripts/bifrost.fish` (fish, macOS):
decode, optional FPS retime, Demucs vocal separation, Sidon speech
restoration, then loudnorm. See the header comment in the script for full
usage.

Demucs runs on the Apple Silicon GPU via the
[`demucs-mlx`](https://github.com/ssmall256/demucs-mlx) port (base `htdemucs`),
roughly 20x faster than the old CPU path (~7 min vs ~3h for a 2h film). Base
`htdemucs` is used rather than `htdemucs_ft`: the 4-model `_ft` ensemble is far
heavier on this GPU for a quality difference that is inaudible after Sidon
restoration on cam sources. Two pins are REQUIRED:

- `mlx-audio-io==1.3.10` holds `mlx` at `0.31.0`; `mlx` `0.31.2` made GPU streams
  thread-local and crashes the port with `There is no Stream(gpu, 1) in current
  thread` (upstream regression,
  [ml-explore/mlx-lm#1179](https://github.com/ml-explore/mlx-lm/issues/1179)).
  Drop it only once `demucs-mlx` runs on `mlx >= 0.31.2`.
- the `[convert]` extra converts `htdemucs`'s weights to MLX on first run (cached
  in `~/.cache/demucs-mlx/`); only `htdemucs_ft` ships pre-converted weights.

The port writes all four stems to `<out>/<track>/vocals.wav` (no per-model
subdir), so the script resolves the vocals path with `find`. Sidon stays on CPU
(~25 min for a 2h film): its checkpoints are CUDA-traced TorchScript with float64,
which Apple's MPS backend does not support.

Each session can also carry an optional `.shazamcatalog` file (the
`Cinema sync catalog` row in the create / edit form). It is opt-in: sessions
without one behave exactly as before. When attached, the catalog is copied
alongside the audio and subtitles and enables the cinema sync button in the
player — see [Cinema sync](#cinema-sync-shazamkit) below and
[`docs/cinema-sync.md`](docs/cinema-sync.md) for the full workflow.

### Switching tracks at runtime

In `PlayerView`, a toolbar `Menu` appears when a session has more than one
track. Tapping it lists every track with a checkmark on the active one;
selecting another switches the playing audio while preserving the current
position (~100-300ms gap during reload, no crossfade). The same list lives
on the Apple Watch as a third TabView page — see below.

### Cinema sync (ShazamKit)

When a session has a `.shazamcatalog` attached, the player top bar shows a sync
button (a waveform-with-magnifier glyph) between the back button and the title.
Tapping it opens a modal that listens through the iPhone mic for a few seconds,
matches the room's cinema audio against the catalog via ShazamKit, and seeks the
prepared dub track to the matched on-screen position — replacing the manual
subtitle-tap resync. The ShazamKit match is an *English* timecode; when the
session also carries an optional `.dtwmap.json` mapping (the
`Cinema sync mapping` row in the create / edit form), that English time is
converted to the corresponding Russian-dub timecode before the seek, correcting
playback drift between the two masters. Without a mapping the English offset is
used as-is (identity). On a match the modal shows the dub timecode it jumped to
and auto-dismisses; with no match within ~6 seconds it offers Try Again / Close.
The first tap prompts for microphone access (`NSMicrophoneUsageDescription`).
Playback is not interrupted during the listen — the audio session swaps to
`.playAndRecord` with `.mixWithOthers` for the sync window and restores
afterward. The button is hidden for sessions without a catalog.

The watch transport screen no longer carries a mic-sync button. Resync from the
wrist now goes through the always-available mic-free dead-reckon button (it
re-projects the dub from the last sync anchor), and a passive drift readout
shows how far the dub has drifted from the cinema. The watch's own ShazamKit
mic-match plumbing (catalog transfer, local matching) remains in the codebase
but is currently dormant; generating the catalog and mapping files is a separate
Mac-side step; see [`docs/cinema-sync.md`](docs/cinema-sync.md).

For cinema sessions, the app also writes a per-screening JSONL diagnostics log
(`Documents/diagnostics/`, pulled via the Files app) capturing every sync,
manual skip, and transport action for after-the-fact drift analysis on the Mac.
It is gated to sessions with a catalog — ordinary listening writes nothing — and
has no UI. See
[`docs/cinema-sync.md`](docs/cinema-sync.md#session-diagnostics).

## Apple Watch remote

Allspeak ships with a companion watchOS app (`AllspeakWatch`) that lets you
resync subtitles in a cinema without taking the iPhone out of your pocket.
The watch is a thin remote: it sends commands (play/pause, skip ±1s / ±3s,
seek-to-cue, set volume, mic-free dead-reckon resync) to the iPhone, which
remains the audio host.

### Pairing

1. Pair the Apple Watch with the test iPhone via the iOS `Watch` app
   (Settings → Watch).
2. Install both builds — the watch app installs automatically alongside the
   iPhone app once the bundle reaches the device (TestFlight, Xcode, or
   ad-hoc).
3. Foreground both apps at least once after install. WatchConnectivity
   requires both peers to have been launched by the user before delivery
   starts working.
4. Open a session on the iPhone. The watch will receive the session
   metadata via `updateApplicationContext` and the full cue bundle via
   `transferFile` (gzipped JSON, cached on-watch for restart resilience).

### Usage

- **Page 1** (default, transport): a stacked transport layout — a centered
  pair of ±3s coarse skips on top (with a mic-free dead-reckon resync button
  between them), a full-width Play/Pause, a non-interactive film progress bar
  (gold fill with the elapsed time on the left and a remaining countdown on the
  right, self-advancing while playing), and a centered pair of ±1s fine skips
  beneath. Between the ±1s skips sits the **sync drift readout**: big signed
  seconds plus a direction caption showing how far the dub has drifted from the
  cinema since the last sync anchor — gold `+0.8s AHEAD` / `-1.4s BEHIND`, gray
  `±0.0s IN SYNC` within a 0.3s band, and a muted `-- / NO SYNC` before any
  anchor exists (drift rides the existing playback snapshots — no extra mic
  listen or timer). The skip controls are circular glass buttons whose icon is a
  curved arrow with the interval inside it (`3`, `1`); every skip tap plays a
  click haptic. Play/Pause is a warm-tinted glowing pill. The Digital Crown
  drives the phone's real system output volume (re-synced from the phone's
  reported `outputVolume` while the Crown is idle) with haptic ticks at each
  detent; the native Crown indicator fills with loudness so a full bar = max
  volume. As a consequence of the system locking fill direction to rotation
  direction, turning the Crown **down** raises the volume. Rapid rotation
  coalesces into a single trailing-edge command.
- **Page 2** (swipe up): scrollable list of all cues with the current line
  highlighted; tap any line to seek the iPhone audio to that timestamp.
- **Page 3** (swipe up again): list of audio tracks on the current
  session, with a checkmark on the active one. Tap any track to switch
  the iPhone-side audio. Shows a `Single track` placeholder when the
  session has only one track.
- Rapid skip taps (fine or coarse) coalesce inside a 250ms window so five
  quick ±1s taps send a single `skip(+5)` command rather than five
  round-trips; mixed fine + coarse taps sum in the same window.
- Between authoritative snapshots from the iPhone, the watch interpolates
  the displayed position locally (`currentTime + (now - serverDate)` while
  playing) so the UI never feels frozen.

The commands round-tripped over WatchConnectivity are: `play`, `pause`,
`togglePlayPause`, `skip(seconds:)`, `seek(time:)`, `switchTrack(id:)`,
`setVolume(_:)`, `requestCueBundle(sessionID:revision:)`,
`requestCatalog(sessionID:stamp:)`, `cinemaMatch(sessionID:stamp:enTime:)`, and
`deadReckonSeek(sessionID:)`. Session
metadata delivered to the watch carries a `tracks: [TrackInfo]` array
plus the current `activeTrackID`. The wire contract lives in
`Allspeak/Watch/WireProtocol.swift` — see the header comment there for
the protocol summary.

## Architecture

- **UI**: SwiftUI, dark-only, single device family (iPhone, portrait).
  Liquid Glass surfaces use iOS 26's `.glassEffect()` with warm-tint overlays
  per the design's chrome / plate variants.
- **Persistence**: Core Data with `Session` and `AudioTrack` entities
  (one-to-many, cascade delete). Persistent history tracking is enabled;
  lightweight migration carries pre-multitrack sessions forward by
  back-filling a single `AudioTrack(label: "Original", isDefault: true)`
  from the legacy `Session.audioFilename` field. The current model version,
  `Allspeak v4`, adds two optional `Session` fields for cinema sync:
  `catalogFilename` (the ShazamKit catalog, added in v3) and `dtwMapFilename`
  (the DTW English-to-Russian timecode mapping, added in v4). Both the v2 to v3
  and v3 to v4 migrations are lightweight (existing sessions carry forward with
  no catalog and no mapping). File payloads (audio + srt) are not stored in
  Core Data — only filenames.
- **Audio**: Single `AVAudioPlayer` per player session, `.playback` category,
  `.spokenAudio` mode. Background audio is permitted via the `audio` entry in
  `UIBackgroundModes`.
- **Now Playing**: Lock-screen and Control Center integration via
  `MPNowPlayingInfoCenter` (metadata + elapsed time) and
  `MPRemoteCommandCenter` (play/pause, ±15s skip, scrub). The card and
  remote-command transport (lock screen, Control Center, AirPods stem,
  external Bluetooth remotes) are driven by the same `AudioController`
  state — there is no separate playback path.
- **SRT parsing**: pure Swift, parsed on demand when entering the player.
- **Design tokens**: all colors, fonts, and glyphs live in
  `Allspeak/Design/{Tokens,Glass,Icons}.swift`. No inline hex outside
  `Tokens.swift`.

## Testing

Tests use [Swift Testing](https://developer.apple.com/documentation/testing)
(`@Test`, `#expect`, `#require`), not XCTest. Run from Xcode (`⌘U`) or:

```fish
xcodebuild test -scheme Allspeak \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Suites are tagged (`.parser`, `.coreData`, `.storage`, `.audio`,
`.cinemaSync`) so subsets can be run with the `--filter` flag.

## Project-local agent skills

The repo ships with three Claude Code skills under `.claude/skills/`:

- `swiftui-expert-skill` — SwiftUI state, view composition, Liquid Glass,
  performance, Instruments traces.
- `swift-testing-expert` — Swift Testing macros, traits, parameterized tests.
- `core-data-expert` — stack setup, context discipline, `NSManagedObjectID`
  handoff, persistent history, migrations.

Future contributions touching the corresponding domain should consult these
skills before writing code — they exist to prevent predictable mistakes
(deprecated APIs, threading bugs, anti-patterns).

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/) — `feat:`,
`fix:`, `refactor:`, `docs:`, `test:`, `chore:`.
