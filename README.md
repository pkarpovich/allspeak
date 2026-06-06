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
subtitle-tap resync. On a match the modal shows the matched timecode and
auto-dismisses; with no match within ~6 seconds it offers Try Again / Close. The
first tap prompts for microphone access (`NSMicrophoneUsageDescription`).
Playback is not interrupted during the listen — the audio session swaps to
`.playAndRecord` with `.mixWithOthers` for the sync window and restores
afterward. The button is hidden for sessions without a catalog. Generating the
catalog file itself is a separate Mac-side step; see
[`docs/cinema-sync.md`](docs/cinema-sync.md).

## Apple Watch remote

Allspeak ships with a companion watchOS app (`AllspeakWatch`) that lets you
resync subtitles in a cinema without taking the iPhone out of your pocket.
The watch is a thin remote: it sends commands (play/pause, skip ±0.5s / ±3s,
seek-to-cue, set volume) to the iPhone, which remains the audio host.

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
  pair of ±3s coarse skips on top, a full-width Play/Pause in the middle, a
  centered pair of ±0.5s fine skips beneath, and a slim volume bar at the
  bottom. The skip controls are circular glass buttons whose icon is a curved
  arrow with the interval inside it (`3`, `0.5`); Play/Pause is a warm-tinted
  glowing pill. The Digital Crown is wired to playback volume
  (`AVAudioPlayer.volume`, 0...1, persisted across launches) with haptic ticks
  at each detent; rotating the Crown up raises the volume, and the bar fills in
  proportion to the current level so the on-screen scale always matches the
  loudness sent to the phone. The bar brightens while the Crown is turning and
  dims when idle; rapid rotation coalesces into a single trailing-edge command.
- **Page 2** (swipe up): scrollable list of all cues with the current line
  highlighted; tap any line to seek the iPhone audio to that timestamp.
- **Page 3** (swipe up again): list of audio tracks on the current
  session, with a checkmark on the active one. Tap any track to switch
  the iPhone-side audio. Shows a `Single track` placeholder when the
  session has only one track.
- Rapid skip taps (fine or coarse) coalesce inside a 250ms window so five
  quick ±0.5s taps send a single `skip(+2.5)` command rather than five
  round-trips; mixed fine + coarse taps sum in the same window.
- Between authoritative snapshots from the iPhone, the watch interpolates
  the displayed position locally (`currentTime + (now - serverDate)` while
  playing) so the UI never feels frozen.

The commands round-tripped over WatchConnectivity are: `play`, `pause`,
`togglePlayPause`, `skip(seconds:)`, `seek(time:)`, `switchTrack(id:)`,
`setVolume(_:)`, and `requestCueBundle(sessionID:revision:)`. Session
metadata delivered to the watch carries a `tracks: [TrackInfo]` array
plus the current `activeTrackID`. The wire contract lives in
`Allspeak/Watch/WireProtocol.swift` — see the header comment there for
the protocol summary.

### Live Activity (Smart Stack)

While a session is playing, Allspeak runs an ActivityKit Live Activity that
appears on the iPhone Lock Screen / Dynamic Island and is automatically
mirrored into the watch Smart Stack (via `supplementalActivityFamilies([.small])`).
Rotating the Digital Crown down from the watch face surfaces the widget
without unlocking the phone — one tap on its Pause/Play button toggles
playback (routed through `TogglePlaybackIntent`, a `LiveActivityIntent`
whose `perform()` runs in the main iPhone app process), and tapping the
widget body deep-links into the AllspeakWatch app via the
`allspeak://session/<uuid>` URL scheme. The Activity ends automatically
when the session ends or the track finishes.

## Architecture

- **UI**: SwiftUI, dark-only, single device family (iPhone, portrait).
  Liquid Glass surfaces use iOS 26's `.glassEffect()` with warm-tint overlays
  per the design's chrome / plate variants.
- **Persistence**: Core Data with `Session` and `AudioTrack` entities
  (one-to-many, cascade delete). Persistent history tracking is enabled;
  lightweight migration carries pre-multitrack sessions forward by
  back-filling a single `AudioTrack(label: "Original", isDefault: true)`
  from the legacy `Session.audioFilename` field. The current model version,
  `Allspeak v3`, adds an optional `catalogFilename` to `Session` for the
  cinema-sync ShazamKit catalog; the v2 to v3 migration is lightweight
  (existing sessions carry forward with no catalog). File payloads (audio +
  srt) are not stored in Core Data — only filenames.
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
