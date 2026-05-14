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
3. Tap `Choose audio file` and pick the `.m4a` via the system file picker.
4. Tap `Choose subtitles file` and pick the `.srt`.
5. Save.

The picked files are copied into the app's Documents container at
`Documents/sessions/<uuid>/<filename>` and are independent of the original
source location after import.

## Architecture

- **UI**: SwiftUI, dark-only, single device family (iPhone, portrait).
  Liquid Glass surfaces use iOS 26's `.glassEffect()` with warm-tint overlays
  per the design's chrome / plate variants.
- **Persistence**: Core Data with a single `Session` entity. Persistent
  history tracking is enabled; lightweight migration is configured.
  File payloads (audio + srt) are not stored in Core Data — only filenames.
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

Suites are tagged (`.parser`, `.coreData`, `.storage`, `.audio`) so subsets
can be run with the `--filter` flag.

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
