# Cinema sync (ShazamKit)

Optional per-session feature. A session may carry a `.shazamcatalog` file
fingerprinting the film's reference audio (the English cinema master). When
present, the player shows a sync button that listens to the room through the
mic, matches the current scene against the catalog via ShazamKit, and seeks the
prepared dub track to that position. This replaces the manual subtitle-tap
resync used to correct drift during a screening.

Sessions without a catalog are unaffected — the feature is entirely opt-in and
backward compatible.

## Attaching a catalog

1. In the create or edit form, find the `Cinema sync catalog (optional)` row
   (below the subtitles row).
2. Pick a `.shazamcatalog` file via the system file picker (transferred to the
   phone through Files, AirDrop, or iCloud Drive, same as audio / subtitles).
3. Save. The file is copied into the session's Documents folder at
   `Documents/sessions/<uuid>/<catalogFilename>`.

To remove or replace it, open the session in edit mode, clear the row (or pick a
different file), and Save. Clearing deletes the stored file and nulls the
session's `catalogFilename`.

## Using the sync button

The button (a waveform-with-magnifier glyph, labeled `Sync with cinema audio`)
appears in the player top bar only when the session has a catalog, positioned
between the back button and the title.

- **Tap** -> a modal opens and listens for a few seconds.
- **Match** -> the modal shows the matched timecode and auto-dismisses; the dub
  track seeks to that position.
- **No match** (within ~6 seconds) -> the modal offers `Try Again` and `Close`.
- **Cancel / swipe down** -> listening stops, nothing seeks.

Playback continues throughout the listen. The audio session swaps to
`.playAndRecord` with `.mixWithOthers` for the sync window so the running
`AVAudioPlayer` is neither ducked nor paused, then restores its previous
category on exit.

## Microphone permission

The first sync tap prompts for microphone access via
`NSMicrophoneUsageDescription`:

> Allspeak listens briefly to the cinema audio so it can sync the dub track to
> what's playing on screen.

If denied, the modal surfaces an error and no listening occurs. The permission
can be re-granted in iOS Settings.

## Generating a catalog (out of scope here)

Building the `.shazamcatalog` is a separate Mac-side step, not part of the app:
generate an `SHSignature` over the full film from the **English original**
audio, wrap it in an `SHMediaItem` (`timeOffset: 0`, plus title metadata), and
write an `SHCustomCatalog` to a `.shazamcatalog` file. A Russian dub catalog
would not match what the cinema plays. Because the catalog covers the film from
minute 0, a match's `predictedCurrentMatchOffset` maps directly to the playback
position in the prepared dub track (both aligned to the same theatrical start).
