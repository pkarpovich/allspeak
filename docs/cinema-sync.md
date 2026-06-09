# Cinema sync (ShazamKit)

Optional per-session feature. A session may carry a `.shazamcatalog` file
fingerprinting the film's reference audio (the English cinema master). When
present, the player shows a sync button that listens to the room through the
mic, matches the current scene against the catalog via ShazamKit, and seeks the
prepared dub track to that position. This replaces the manual subtitle-tap
resync used to correct drift during a screening.

The catalog match is an *English* timecode. A session may additionally carry an
optional `.dtwmap.json` file that maps English time to the Russian dub's time
(see [Attaching a DTW mapping](#attaching-a-dtw-mapping) below); when present,
the English match is converted to the dub timecode before the seek. Without a
mapping the English offset is used as-is.

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

## Attaching a DTW mapping

1. In the create or edit form, find the `Cinema sync mapping (optional)` row
   (next to the catalog row).
2. Pick a `.dtwmap.json` file via the system file picker. The picker accepts any
   `public.json` file (`UTType.dtwMap = .json`), so it is not extension-filtered
   the way the catalog is — pick the right file by name.
3. Save. The file is copied into the session's Documents folder at
   `Documents/sessions/<uuid>/<dtwMapFilename>`.

The mapping is independent of the catalog: it can be added, replaced, or cleared
without touching the catalog (and vice versa). Clearing the row deletes the
stored file and nulls the session's `dtwMapFilename`, after which a match's
English offset is seeked to directly (identity). If a mapping file is set but
fails to load (missing, malformed, wrong version), the sync silently falls back
to the same identity behavior.

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

## Generating the catalog and mapping (out of scope here)

Building the `.shazamcatalog` and `.dtwmap.json` is a separate Mac-side step,
not part of the app (the `cinema-prep` skill's `build_catalog.py` and
`export_dtwmap.py` produce them):

- **Catalog**: generate `SHSignature` chunks over the film from the **English
  original** audio and write them into one `SHCustomCatalog` (`.shazamcatalog`).
  A Russian dub catalog would not match what the cinema plays. The film is
  split into 30-minute signatures with 60s overlap because a single signature
  only matches queries within its first ~34 minutes (verified empirically:
  matches stop ~2060-2100s into a signature). Each chunk's media item carries
  `subtitle=abs_start=<seconds>`; the app reconstructs the absolute English
  timecode as `abs_start + predictedCurrentMatchOffset`
  (`MatchDelegateProxy.absStart(fromSubtitle:)`). Catalogs without the
  `abs_start=` marker (single-signature legacy ones) still work — `abs_start`
  defaults to 0, but they only match in the first ~34 minutes of the film.
- **Mapping**: because the catalog covers the film from minute 0, a match's
  `predictedCurrentMatchOffset` is an **English** timecode. The English and
  Russian masters are not frame-aligned (drift can reach tens of seconds), so a
  DTW alignment between the two is exported as `.dtwmap.json` — sorted
  `[en_t, ru_t]` pairs the app interpolates to convert the match offset into the
  dub's timeline. See `Allspeak/Sync/README.md` for the JSON schema and the
  `DTWMapping` lookup contract. Only when no mapping is attached does the
  English offset map directly to the dub position.
