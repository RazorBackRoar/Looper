# Architecture — Looper

Developer map for the native macOS gapless video player (AppKit + AVFoundation).

Looper is an **accessory document app** (hidden from the Dock via `LSUIElement`;
Finder Open With / Get Info → Change All). Each open file gets its own resizable
window. Closing the last window quits. A menu-bar extra lists open windows,
recent files, and Quit (`⌘Q`) while any loop is open.

## Module layout

| File | Role |
| ------ | ------ |
| `Looper/main.swift` | Entry; sets `.accessory` activation policy |
| `Looper/AppDelegate.swift` | `LocalVideoURL` filter; multi-window open/dedupe/cascade; menus, status item, recents; ⌘Q monitor; quit rules |
| `Looper/VideoPlayer.swift` | Everything per-window: `PlayerWindowLayout` + `PlayerTimelineMath` (pure math), `PlayerLayerView`, `VideoScrubBar`, `CircleControl` controls, `VideoScrollView`, `FileDropView`, `VideoPlayerWindowController` |
| `Looper/AssetCache.swift` | Warm `AVURLAsset` / poster / native-size / fps / HDR cache (~1 GB budget) + per-URL load-task registry |
| `Looper/MediaKeys.swift` | `MediaKeyHandling` protocol; remote commands + F7/F8/F9 + volume keys via system-defined events; Now Playing |
| `Looper/PlaybackFormatting.swift` | Time/rate strings; `PlaybackScrubMath` (mouse/trackpad/hold step math) |
| `Looper/VideoMetadata.swift` | ISO 6709 parser, `VideoMetadataReader` (Sendable snapshot), lazy `VideoMetadataSession` |
| `Looper/VideoInfoView.swift` | Right-hand inspector: fixed-schema sections + More Details disclosure |
| `Looper/WindowFrameStore.swift` | Per-file window frame + recents order in `UserDefaults` (capped, legacy-key migration) |
| `Looper/Info.plist` | `LSUIElement`; document types (mp4/mov/m4v/mkv) |
| `LooperTests/LooperSmokeTests.swift` | 7 test classes — pure math, parsers, session races, real `NSEvent` scrub-bar tests |
| `scripts/build-mac.sh` | Release pipeline → `build/Release/Looper.dmg` |
| `scripts/generate-icon.py` | `IconSource.png` → `Looper.icns` + asset catalog (uv + Pillow) |
| `scripts/install-to-applications.sh` | Optional manual install; not wired into the build |

## Open paths

All opens funnel to `AppDelegate.openVideos(at:)`: Finder `openFile`/`openFiles`,
`open urls`, argv fallback (skipped when an Apple Event already arrived), drops
onto `FileDropView`, and Open Recent items. `LocalVideoURL.isPlayableFile` gates
everything — file URLs with `mp4`/`mov`/`m4v`/`mkv` only; network URLs never
reach `AVURLAsset`. Re-opening a file dedupes by `standardizedFileURL.path` and
focuses the existing window. New windows cascade (+30,−30 from 200,600, reset
near screen edges).

Bare launch (no files) self-terminates; `applicationShouldOpenUntitledFile` and
`applicationShouldHandleReopen` both return false — no blank windows ever.

## Instant open

`bootPlayerFast` fires five parallel `AssetCache` loads per window. Reveal gates
on three — `loadPlayable` (asset), `loadNativeSize` (window fit),
`loadFrameRate` (frame timing) — with a 350 ms failsafe so a slow probe can't
wedge the window. `loadDuration`/`loadContainsHDR` update UI after reveal.

`slamOpaqueFront()` runs at init, on attach, and on failure: opaque black,
`animationBehavior = .none`, ordered front + key — covering Finder's thumbnail
zoom with no pop animation. `attachPlayer` builds `AVPlayerItem`
(`preferredForwardBufferDuration = 30`), `AVQueuePlayer`
(`automaticallyWaitsToMinimizeStalling = false`, `actionAtItemEnd = .advance` —
required for `AVPlayerLooper`), `AVPlayerLooper` for the gapless full-clip loop,
then `playImmediately(atRate:)`.

## Playhead & seeks

- The playhead rides a `window.displayLink` at the monitor's refresh (24…Hz
  range; recreated on `windowDidChangeScreen`). Clip stays at native fps — the
  display link only drives the UI.
- `playerTimeFired` ignores updates while scrubbing, honors
  `pendingPlayheadSeconds` (holds the knob until the player catches up: 2-frame
  slop, loop wrap, or 0.22 s timeout), and rejects backward jitter unless it is
  a real wrap per `PlayerTimelineMath.isLoopWrap` against `loopBounds`.
- Seeks are serialized single-flight (`seekInFlight` + coalesced queue, precise
  flag OR-accumulates) with a **30 seeks/s cap** at every call site —
  `AVPlayer` can't absorb 120 Hz seeks. Coarse seeks use
  `max(2·frameDuration, 50 ms)` tolerance; gesture-end seeks are zero-tolerance.
  After a finished seek, rate-0 players resume at `currentRate` unless a
  pause-hold state is active.

## Custom loop ranges

One state machine (`handleLoopPointInput`) for both surfaces — double-click on
the video (at the playhead) or on the scrub bar (at the click): **pending point
→ complete pair (min span 0.1 s) → third double-click clears**. Dragging the
playhead outside an active range also clears it. The scrub bar snapshots
pair-existence on the first click of a sequence so a scrub-outside first click
can't erase the intent a double-click needs.

`applyCustomLoop` serial-guards, disables the old looper, precise-seeks to the
in-point, creates `AVPlayerLooper(timeRange:)`, and caps the in-flight item via
`forwardPlaybackEndTime`. Green range + markers draw under the thumb.

## Input

- **Scrub bar drag** — coarse seeks ≤30 Hz while dragging, precise seek +
  resume on release.
- **Scroll wheel** — up/right = forward, down/left = rewind; momentum phase
  ignored. Mouse (incl. Magic Mouse pixel accumulation): fixed 0.25 s/notch,
  never duration-scaled; pauses during the gesture, 180 ms debounce, precise
  seek + resume. Trackpad: duration-scaled step (4 % of clip per 150 px, ≤0.6 s
  per event), keeps playing.
- **Keyboard** — only while a Looper window is key; non-player responders
  (circles, inspector, text fields) get their keys first. Space = play/pause,
  `1` = ½↔1 speed, `0` = reset speed, `l` = rotate CCW, `m` = volume-based
  mute, Return/Enter = close this window, `←`/`→` = hold to scrub,
  `↑`/`↓` = volume, ⌘Q = quit.
- **Hold scrub** (F7/F9, `←`/`→`, media rewind/fast) — display-link ticks
  ≤30 Hz; tap = small nudge, after ~0.16 s it ramps to a duration-scaled scan
  (`PlaybackScrubMath.holdStep`). Pause during, precise seek + resume on release.
- **Media keys** — `MPRemoteCommandCenter` (toggle/play/pause; next/prev/skip
  disabled) plus a `.systemDefined` subtype-8 monitor decoding HID codes
  (soundUp/Down/Mute/Play/Next/Prev/Fast/Rewind). Held Previous/Next flip to
  Rewind/Fast — tracked via key-down sets, a 0.28 s hold heuristic, and a 0.5 s
  delayed end. Volume nudges throttle at 40 ms, play toggles at 120 ms.
  Now Playing refreshes on key-window change; target is the key window's
  player, else the last.

## Window geometry & chrome

`PlayerWindowLayout` (pure, tested): video region aspect-locked; footer 52 pt
holding a 40 pt capsule (8 pt side insets) with two 28 pt circles — speed
(`1`/`½`, silent indicator) and Info. Inspector = 300 pt + 1 pt separator.
`windowWillResize` → `aspectCorrectedContentSize`: the dominant drag axis
drives, clamped to screen and the 320×180 video min. `applyNativeWindowSize`
fits native pixels to the screen (20 pt inset), prefers the saved origin
(top-edge anchored), else cascade.

The window is titled/closable/resizable, never minimized, tabbing disallowed,
`isReleasedWhenClosed = false`, `isRestorable = false`, `animationBehavior =
.none`, and sits at `.floating` **only while key** (defeats Finder clip-through)
then drops to `.normal`.

The capsule is `NSGlassEffectView` (`.clear`, interactive on macOS 27+) on
macOS 26+, else a dark `NSVisualEffectView` (`.hudWindow`). Time labels are
monospaced digits: elapsed `m:ss`, remaining `-m:ss`. `l` rotates the display
90° CCW (file unchanged) and refits the window.

## Info inspector

The `i` circle opens a 301 pt right column (`VideoInfoView`, `.sidebar`
material + hairline separator). Opening widens the window — shifts left, or
shrinks the video to fit; closing restores the pre-open width unless the user
resized/rotated meanwhile.

`VideoMetadataSession` is lazy: no extraction while hidden; a generation
counter + URL + visibility guard kills stale publishes; a completed snapshot is
reused on reopen. `VideoMetadataReader` runs detached and returns a Sendable
snapshot: File (always), Recorded, Camera, Location (ISO 6709 → **GPS: Yes/No
only**, plus Place/Body/Note), Video (duration/resolution/fps/bit rate/codec/
encoded/color), Audio (codec/sample rate/channels/language/bit rate), and a
bounded "More Details" remainder (≤256 fields, ≤2048 chars). `VideoInfoView`
renders a fixed schema — every expected row always shows, `N/A` when absent;
loading / unavailable / ready / partial states; chevron disclosure for details.

## Caches & persistence

`AssetCache`: `NSCache` for `AVURLAsset` (count 128, ~1 GB cost @8 MB/entry) and
posters (64); unbounded `sizeCache`/`fpsCache`/`hdrCache`; native sizes also
persist to `UserDefaults` (`Looper.nativeSizes`, 400→300 trim) for instant
sizing on reopen. A `loadTasks[key][id]` registry powers
`cancelLoads(for:)`/`cancelAllLoads` (the latter from
`applicationShouldTerminate`); every load checks `Task.isCancelled` between
awaits. Assets are created with `AVURLAssetPreferPreciseDurationAndTimingKey`.

`WindowFrameStore`: `Looper.windowFrames` dict + `Looper.windowFrameOrder` LRU
array (400→300). `noteOpened` feeds Open Recent before any move/resize;
`recentFileURLs` returns newest-first existing files, max 12. Legacy
`Looper_WindowFrame_*` keys migrate once. Both stores expose a swappable
`defaults` for tests.

## HDR/EDR

`loadContainsHDR` checks `.containsHDRVideo` then format-description transfer
functions (PQ / HLG). `applyPlayerEDR` sets `preferredDynamicRange` (macOS 26+;
`wantsExtendedDynamicRangeContent` earlier) on the `AVPlayerLayer` **only when
the clip is HDR** — SDR never gets EDR. `videoGravity = .resizeAspectFill` plus
the aspect-locked window fills the window with no letterbox bars.

## Drag & drop / replace

`FileDropView` (root content view) accepts `.fileURL` drags filtered to
playable extensions. First dropped file calls `replaceVideo` — saves the frame,
tears down playback (key monitor kept), resets all per-clip state (rate,
rotation, HDR, loop markers, duration), retitles, reboots. Extra files open as
new windows.

## Supported formats & failures

Registered document types: **mp4**, **mov**, **m4v**, **mkv** (`Info.plist`,
Viewer/Alternate). MKV usually can't decode in AVFoundation — the window title
surfaces `Can't play MKV — name`; other failures read `Failed — name`. Only
local file URLs are playable (remote URLs are rejected before asset creation).
~6 concurrent windows is the design workload — keep multi-window performance in
mind.

## Multi-window behavior

`AppDelegate` tracks open `VideoPlayerWindowController`s; re-opening a file
focuses its window. `WindowFrameStore` restores each file's last frame and feeds
Open Recent. `MediaKeys.target` resolves to the key window's player (else last
opened), so media keys drive the focused loop.

## Build pipeline

```bash
./scripts/build-mac.sh
```

The script:

1. Runs `scripts/generate-icon.py` (uv + Pillow; `LOOPER_ICON_PYTHON` override;
   falls back to committed `Looper.icns`) — extracts the squircle from
   `IconSource.png`, scales to the 824 grid, adds the shared drop shadow,
   writes asset-catalog PNGs + `Looper.icns`
2. `xcodebuild` Release (arm64, own `build/DerivedData`)
3. Stages the `.app`, overlays the icns, `patch-app-branding.sh`, codesign
   (ad-hoc; `LOOPER_SIGN_IDENTITY` → Developer ID), `package-dmg.sh` →
   `build/Release/Looper.dmg`
4. Copies `~/Desktop/Looper.dmg` (local builds only; CI skips the Desktop copy)

It deletes the staging `.app` + DerivedData and does **not** install
`/Applications/Looper.app` (`scripts/install-to-applications.sh` is the manual
opt-in). Drag the app from the DMG yourself.

## Testing & verification

CI (`quality` job, macos-26) runs `xcodebuild` Release build + test.

```bash
xcodebuild -project Looper.xcodeproj -scheme Looper \
  -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=- test
```

Do not override DerivedData — the default settings keep app + XCTest indexing
intact. Tests live in one file, 7 classes: URL filter, time/rate formatting,
frame store caps/recents, cache store/cancel, scrub math, ISO 6709 parsing, an
end-to-end `AVAssetWriter` MOV through `VideoMetadataReader`, session
generation races, window-layout math, loop-wrap math, and real-`NSEvent`
scrub-bar click sequences.

Not covered by tests: playback/seek/loop runtime, media keys, on-screen
geometry, drag & drop — validate manually on macOS.

## Product invariants

Rules the code enforces — do not violate when changing Looper:

1. Accessory app: never in the Dock, never minimized; last window close quits;
   no persistence agents.
2. Click on the video never pauses; Space toggles; Return closes only the key
   window; ⌘Q quits.
3. The timeline lives in the footer capsule — never overlays the picture.
4. No on-screen volume slider; speed changes are silent (the circle's glyph is
   the indicator).
5. Shortcuts act only while a Looper video window is key; non-player responders
   keep their keys.
6. Video fills the window at clip aspect; resize aspect-locks the video region
   (footer/inspector are separate chrome).
7. Clip plays at native fps; playhead rides the display link; ≤30 seeks/s;
   coarse during a gesture, precise at its end; trackpad scrub scales with
   duration, mouse never does; momentum ignored; playback resumes after scrub.
8. Reveal only after size + fps + playable resolve (350 ms failsafe); opaque
   black covers Finder's zoom; `.floating` only while key.
9. Local file URLs only — nothing remote reaches `AVURLAsset`.
10. GPS surfaces only as `GPS: Yes` / `GPS: No` — no map, no coordinates.
11. Per-file frame memory + recents, capped; per-clip state fully resets on
    `replaceVideo`.

## Related docs

- [BUILD_AND_RELEASE.md](../BUILD_AND_RELEASE.md)
- [CONTRIBUTING.md](../CONTRIBUTING.md)
- [AGENTS.md](../AGENTS.md)
