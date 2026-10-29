---
name: simulator
description: Build, run, drive, and screenshot the Allspeak iOS app and its Apple Watch remote on the simulator - including the WatchConnectivity pairing procedure that makes the watch show a live session. Use when asked to run the app in the simulator, take app/watch screenshots, reproduce a UI bug, or "show how the watch looks". Covers XcodeGen build, catalog config baking, AXe UI driving, SwiftUI slider scrubbing, and the exact watch pairing/handshake order.
---

# Allspeak simulator driving

Everything here runs on the Mac (this is a native iOS/watchOS app - Xcode 26,
iOS 26 / watchOS 26 deploy targets). Screenshots for the public README, bug
repro, and the Apple Watch remote all go through here.

## THE watch lesson (read first): why the watch showed "No active session"

The Apple Watch app is a **dependent companion** - its transport UI (play,
skip +-1s/+-3s, volume, position) only populates from a live phone session over
WatchConnectivity. First attempt failed for THREE reasons, none of them the app:

1. **The pair was `active, disconnected`.** Pairing two ALREADY-BOOTED sims
   leaves the pair disconnected, and `updateApplicationContext`/`sendMessage` to
   a disconnected pair silently do nothing.
2. **Wrong order.** The phone broadcast the session before the watch app was
   running and listening.
3. **Chased the wrong thing.** Spent time on the app's companion config
   (`WKCompanionAppBundleIdentifier`, WCSession activation) - all correct. The
   fault was the sim link, exactly as Pavel said.

### Working procedure (verified 2026-07-20)

```sh
W=<watch-udid>   # Apple Watch Series 11 (46mm), watchOS 26.x
P=<phone-udid>   # iPhone 17 Pro, iOS 26.x

xcrun simctl pair "$W" "$P"                 # 1. create the pair
xcrun simctl shutdown "$W" "$P"             # 2. REBOOT both as a pair -
xcrun simctl boot "$P"; xcrun simctl boot "$W"   #    only then does it connect
xcrun simctl list pairs | grep -A2 <pairUUID>    # must say (active, connected)

# 3. install BOTH apps (simctl does NOT auto-propagate the companion watch app)
xcrun simctl install "$P" build/dd/Build/Products/Debug-iphonesimulator/Allspeak.app
xcrun simctl install "$W" build/dd/Build/Products/Debug-watchsimulator/AllspeakWatch.app

# 4. phone: launch, open a session in the player
# 5. LAUNCH THE WATCH APP FIRST so its WCSession activates and listens
xcrun simctl launch "$W" dev.karpovich.allspeak.watchkitapp
# 6. THEN change playback state on the phone (tap Play, or seek).
#    That fires broadcastCurrentSession (updateApplicationContext = session
#    metadata, drives "No active session" vs populated) and sendMessage (the
#    live snapshot). On a CONNECTED pair with the watch listening, the watch's
#    didReceiveApplicationContext / didReceiveMessage fire live.
```

Order is the crux: **connected pair -> watch listening -> phone state change.**

Confirm it worked from the watch log:
```sh
xcrun simctl spawn "$W" log stream --level debug --style compact \
  --predicate 'senderImagePath CONTAINS "AllspeakWatch" OR eventMessage CONTAINS[c] "WCSession"'
# success looks like:
#   handleApplicationContextWithPairingID: <phone-udid>
#   companionAppBundleID: dev.karpovich.allspeak
```

App wiring (for reference, all correct - do not "fix"): phone activates
`WCSession` at `AllspeakApp` init via `WatchSessionHost.shared.activate()`;
session metadata goes out with `updateApplicationContext`, the live playback
snapshot with `sendMessage` (needs `isReachable`); the watch reads
`session.receivedApplicationContext` on activation.

## Toolchain

- **Xcode 26.6**, XcodeGen (`project.yml`). After editing `project.yml` or a
  plist: `xcodegen generate`.
- **Deploy targets are iOS 26 / watchOS 26.** You MUST target an iOS 26 / watchOS
  26 sim (iPhone 17 Pro, Apple Watch Series 11/Ultra 3). A booted "iPhone 16 Pro"
  was iOS 18.2 -> `install failed: Requires a Newer Version of iOS`. List real
  OS with `xcrun simctl list devices "iOS 26.5"` / `"watchOS 26.5"`.
- **AXe** at `/opt/homebrew/bin/axe` - drives the UI (tap/swipe/type/describe-ui).
- **xcui** (axiom plugin) - assertions/waits on the a11y tree; it does NOT tap
  (that's AXe). `xcui doctor` warns if several sims are booted - shut down extras.

## Build

The app reads the catalog URL + read token from `Allspeak/CatalogConfig.xcconfig`
(gitignored), pulled in via `#include? "CatalogConfig.xcconfig"` in the LOCAL
`Allspeak/Signing.xcconfig`. Without it the Catalog tab is EMPTY. Set it up once:

```sh
# CatalogConfig.xcconfig (gitignored) - note the /$()/ trick so xcconfig's //
# comment stripping doesn't eat https://; token from ~/.config/allspeak/catalog.env
printf '%s\n' 'ALLSPEAK_CATALOG_URL = https:/$()/allspeak.pkarpovich.dev' \
  "ALLSPEAK_CATALOG_READ_TOKEN = $AUTH_READ_TOKEN" > Allspeak/CatalogConfig.xcconfig
# ensure Signing.xcconfig's first line is:  #include? "CatalogConfig.xcconfig"
```

```sh
xcodebuild -project Allspeak.xcodeproj -scheme Allspeak -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
```

- Product lands at `build/dd/Build/Products/Debug-iphonesimulator/Allspeak.app`
  (embedded watch app: `.../Allspeak.app/Watch/AllspeakWatch.app`; standalone
  watch build: `build/dd/Build/Products/Debug-watchsimulator/AllspeakWatch.app`).
  **Ignore the stale project-relative `build/Debug-iphonesimulator/Allspeak.app`.**
- Verify config baked in: `plutil -extract AllspeakCatalogURL raw <App>/Info.plist`
  should print `https://allspeak.pkarpovich.dev`; token length 64.
- To find the product dir when unsure: `-showBuildSettings ... | grep BUILT_PRODUCTS_DIR`
  (use an iOS 26 destination or it errors and prints nothing).

## Driving the UI (AXe)

```sh
axe describe-ui --udid "$P"          # a11y tree as JSON; points, iPhone 17 Pro = 402x874
axe tap -x <pt> -y <pt> --udid "$P"
axe swipe --start-x A --start-y B --end-x C --end-y D --delta 6 --duration 1.2 --udid "$P"
```

- `describe-ui` root may be a **list**, not a dict - handle both when walking.
- **SwiftUI Slider (player scrubber): a TAP does not seek.** You must DRAG and the
  drag must GRAB the thumb - start at the thumb's CURRENT x. A drag that starts on
  the track misses and does nothing; small nudges that miss the thumb also do
  nothing. Use `--delta` for stepped moves. Screenshot to find the thumb's x, then
  drag from there. (The player scrubber maps ~29 s/pt over its width.)
- Subtitle "tap a line to jump" exists in-app but was unreliable to drive
  headlessly; scrubbing the slider was the workable path.

## Screenshots

```sh
# clean status bar (phone only - watch override is NOT supported: "Operation not supported")
xcrun simctl status_bar "$P" override --time "9:41" --batteryState charged \
  --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcrun simctl io "$P" screenshot out.png     # ALWAYS open and look at it
```

- Shut down extra sims first (`xcui doctor` / AXe get confused by multiple booted).
- Save curated shots to `~/Downloads/allspeak-screenshots/`; do NOT commit to the
  repo without Pavel's OK.

## App navigation map (for screenshots)

Opens on **Sessions** (dark), segmented **Mine / Catalog**.
- Catalog tab -> live catalog list (needs CatalogConfig). Tap a row (left of the
  gold **Import**) -> **detail "What's inside"** (tracks + subtitle). Import ->
  downloads into Mine.
- Mine -> tap a session card -> **PlayerView** (subtitle river + transport;
  scrub to mid-film for a fuller subtitle line - the opening lines are one-word
  fragments). Moon icon = cinema mode.
- Watch app = 3 paged views: **TransportView** (skips +-1/+-3s, play, position,
  volume), SubtitleListView, TrackListView - placeholders until a live session
  arrives (see the watch lesson above).

## Catalog admin (staging shots)

Creds in `~/.config/allspeak/catalog.env` (`CATALOG_API`, `AUTH_ADMIN_TOKEN`,
`AUTH_READ_TOKEN`; never print values). To remove a test row before a screenshot:
`curl -X DELETE -H "Authorization: Bearer $AUTH_ADMIN_TOKEN" "$CATALOG_API/sessions/<id>"`
(-> 204). Full publish/flow is in the `cinema-prep` skill and the
`allspeak-catalog` repo README.

## Gotchas that cost time (don't repeat)

- `showinfo`/`volumedetect`/`silencedetect`-style tools and slider drags: verify
  by screenshot, not by assuming the action landed.
- Multiple booted sims -> ambiguous AXe/xcui target; keep exactly one phone (+one
  watch when needed) booted.
- Watch status bar time cannot be overridden in the sim - the real clock shows.
