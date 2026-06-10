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

## Syncing from the watch

The AllspeakWatch transport screen has its own sync button (same
waveform-with-magnifier glyph, between the coarse skip buttons). It appears only
once the session's catalog has been transferred to the watch.

- **Tap** -> the watch listens through its own microphone via
  `SHManagedSession(catalog:)` and matches locally on the watch (8s timeout).
- **Match** -> a success haptic plays and the watch sends the absolute English
  timecode to the phone (`WatchCommand.cinemaMatch(sessionID:stamp:enTime:)`). The phone treats
  it exactly like a phone-button match: it adds the Sync delay, DTW-maps
  EN -> RU (identity without a mapping), and seeks the dub track. The command
  carries the catalog stamp the watch matched against; the phone requires both
  stamps to be present and equal, so a match made against a catalog the session
  no longer announces (replaced, cleared, or never stamped) is rejected and the
  reply is an empty snapshot - the wrist feels failure instead of a false
  success.
- **No match / timeout / unreachable phone** -> a failure haptic plays and the
  button briefly shows an error state.
- **Tap again while listening** -> cancels, nothing is sent.

Why the watch listens instead of the phone: with AirPods in and the phone in a
pocket, a phone-side listen would switch the AirPods to the HFP (phone-call)
profile for the mic, degrading dub playback during every sync. The watch mic
sits on the wrist in open air and never touches the phone's audio route — the
dub keeps playing untouched.

**Catalog transfer**: when a session with a catalog is opened (and on watch
session activation), the phone queues the catalog file via
`WCSession.transferFile` with `kind: "catalog"` metadata plus a content `stamp`
(filename + SHA-256 of the contents). The watch stores it at
`Documents/catalogs/<sessionID>.shazamcatalog` and prunes catalogs of other
sessions. Session metadata broadcasts carry the same `catalogStamp`; when it
changes (catalog replaced, even under the same filename) or disappears (catalog
cleared), the watch deletes its stored copy and the sync button hides until a
fresh transfer lands. A stored catalog only enables the button while its
non-empty stamp matches the current metadata. A transfer whose stamp does not
match the current metadata (queued before a clear, or a replacement racing
ahead of its announcing context) is staged as a pending file keyed by its
stamp - delivery order is not guaranteed, so a late obsolete transfer cannot
displace a staged replacement - instead of replacing or re-enabling anything;
it is promoted to active once metadata announcing its stamp arrives, since the
phone will not resend a transfer it considers delivered unprompted; a failed
promotion keeps the pending file and is retried on watch activation and
reachability recovery. Pendings staged for stamps that are never announced
(out-of-order replacements) are pruned whenever metadata for the session
arrives, so they cannot accumulate on the watch. If the
watch holds neither an active nor a staged copy of an announced catalog
(persisting it failed after delivery), it sends
`WatchCommand.requestCatalog(sessionID:stamp:)`; the phone clears its transfer
dedup key - unless that transfer is still in flight - and resends. The 1.5MB
DTW map never leaves the phone — the watch only sends the English time.

The same **Sync delay** setting (below) applies to watch-triggered syncs — it is
added on the phone, so one slider covers both entry points. The extra WCSession
hop (~0.1-0.3s) is absorbed by the same value; raise it slightly if
watch-triggered syncs land behind phone-triggered ones.

The first tap prompts for microphone access on the watch
(`NSMicrophoneUsageDescription` in `AllspeakWatch/Info.plist`); if denied, the
sync fails until re-granted via the watch Settings.

## Sync delay (latency compensation)

The match offset is anchored to the moment the mic captured the audio, but the
seek only becomes audible a fraction of a second later (ShazamKit processing,
the seek, and `AVAudioPlayer` start). The film keeps playing in between, so an
uncompensated seek lands slightly in the past and the dub trails the screen.

Settings (gear icon on the Sessions screen) has a **Sync delay** slider that
shifts the seek forward by a fixed amount (default `0.9s`, range `0...3s`). It is
a global setting (the right value depends on the audio route — Bluetooth adds
more delay than the built-in speaker — not on the film). Raise it if the dub
lands behind the film after a sync; lower it if it jumps ahead. The value is read
at each sync tap, so changes take effect on the next sync without restarting.

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

## Session diagnostics

During a screening the app appends a JSONL event log — one file per screening —
recording every sync attempt, manual nudge, and transport action. It is a
debugging aid for measuring real drift and tuning the Sync delay, not a user
feature: there is no in-app viewer. Pull the file off the phone afterward and
analyze it on a Mac (`jq`, pandas).

**Gating**: a file is only ever created for a session that carries a cinema
catalog. Ordinary home listening (no `.shazamcatalog`) writes nothing — the log
stays silent unless the session is a cinema session.

**Location**: `Documents/diagnostics/<film-slug>-<yyyyMMdd-HHmm>.jsonl`, created
lazily on the first event of a screening, append-only, flushed (`synchronize`)
after every line — a crash mid-screening leaves the file parseable up to the
last complete line. `<film-slug>` is the session title lowercased with
non-alphanumeric runs collapsed to `-` (e.g. `After the Light` ->
`after-the-light`, empty -> `session`); the stamp is the UTC time of the
`begin` call that opened the player.

**Pulling the file**: the app's `Documents` folder is exposed to the Files app
(`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`). Open Files ->
`On My iPhone` -> `Allspeak` -> `diagnostics`, then AirDrop or copy the `.jsonl`
to the Mac. There is no retention policy — prune old files here by hand.

**Live view**: every line is also mirrored to `Logger` (subsystem
`dev.karpovich.allspeak`, category `diagnostics`). During a home test, open
Console.app, select the device, and filter on that subsystem/category to watch
events stream in real time without pulling the file.

### Schema

One JSON object per line. Every line has `ts` (wall-clock ISO8601 UTC with
milliseconds) and `event` (the discriminator). The remaining fields depend on
the event type, and optional fields are omitted when nil (whole-number values
are written without a decimal point):

```json
{"ts":"2026-06-12T19:43:02.115Z","event":"play"}
{"ts":"2026-06-12T19:45:10.402Z","event":"pause"}
{"ts":"2026-06-12T19:46:01.880Z","event":"skip","seconds":-1,"source":"phone"}
{"ts":"2026-06-12T19:47:22.310Z","event":"seek","time":1820,"source":"phone"}
{"ts":"2026-06-12T19:50:03.927Z","event":"sync","source":"phone","result":"matched","enTime":2105.4,"ruTime":2112.8,"playerBefore":2098.1,"delta":14.7,"latencyComp":0.9,"absStart":1800,"listenSeconds":4.2}
{"ts":"2026-06-12T19:52:40.118Z","event":"sync","source":"phone","result":"noMatch","latencyComp":0.9,"listenSeconds":6}
{"ts":"2026-06-12T19:55:14.350Z","event":"watch_attempt","result":"matched","listenSeconds":3.8}
{"ts":"2026-06-12T19:55:14.610Z","event":"sync","source":"watch","result":"matched","enTime":2480.2,"ruTime":2488,"playerBefore":2475.5,"delta":12.5,"latencyComp":0.9}
```

- **`sync`** — a cinema-sync result, from the phone button or the watch.
  `source` (`phone`|`watch`), `result` (`matched`|`noMatch`|`timeout`|`error`).
  A match adds `enTime` (compensated English seconds), `ruTime` (dub seconds
  after DTW), `playerBefore` (dub position read just before the seek), `delta`
  (`ruTime - playerBefore` — the jump the sync applied, i.e. accumulated drift
  plus latency), and `latencyComp` (the Sync delay slider value at sync time).
  Phone matches additionally carry `absStart` (the matched catalog chunk marker)
  and `listenSeconds` (mic listen duration); watch matches omit both — the watch
  folds `abs_start` into `enTime` and reports its listen duration in the paired
  `watch_attempt`. Failures (`noMatch`/`timeout`/`error`) carry `latencyComp`,
  `listenSeconds` (when a listen started), and `error` (message, `error` result
  only); the offset fields are omitted.
- **`watch_attempt`** — sent by the watch over `transferUserInfo` after every
  watch listen (queued delivery, so it arrives even if the phone was briefly
  unreachable). `result`, `listenSeconds` (both always present; the failure kind
  is in `result`, so no separate error message is sent). A successful watch
  sync therefore appears twice: this `watch_attempt` (has `listenSeconds`) and a
  paired `sync` with `source:"watch"` (has `playerBefore`/`delta`) — join them
  by their adjacent `ts`.
- **`skip`** — a manual nudge. `seconds` (signed), `source`. The phone player
  buttons step +/-0.5s each; the watch sends coalesced fine (1s) / coarse (3s)
  taps, so a watch `seconds` can be an accumulated multiple. Between two syncs
  these are Pavel's "I heard ~Ns of desync" signals.
- **`seek`** — a jump to an absolute position (subtitle / cue tap, or dragging
  the transport scrubber). `time`, `source`.
- **`pause`** / **`play`** — envelope only.

**Analysis**: the measured drift rate is `delta / (ts - previous-sync-ts)`,
excluding intervals that contain a `seek` or `pause`; compare it against the
DTW prediction from `drift_diagnostic.py` for that film. The small `skip` events
between syncs map the perceived micro-drift the syncs are too coarse to show.
