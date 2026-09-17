# Architecture — Looper

Developer map for the native macOS gapless video player (AppKit + AVFoundation).

Looper is an **accessory document app** (hidden from the Dock via `LSUIElement`; Finder Open With / Get Info → Change All).
Each open file gets its own resizable window. Closing the last window quits. A menu-bar extra lists open windows, recent files, and Quit (`⌘Q`) while any loop is open.

## Module layout

| File | Role |
| ------ | ------ |
| `Looper/main.swift` | Entry; sets accessory activation policy |
| `Looper/AppDelegate.swift` | Multi-window open (Finder, argv), cascade placement, menus, status item |
| `Looper/VideoPlayer.swift` | Player view, scrub overlay, keyboard shortcuts |
| `Looper/AssetCache.swift` | Warm `AVURLAsset` / poster / fps cache (~1 GB budget) |
| `Looper/WindowFrameStore.swift` | Per-file window frame in `UserDefaults` (capped) |
| `Looper/MediaKeys.swift` | F7/F8/F9 + volume keys via Now Playing / system-defined events |
| `Looper/PlaybackFormatting.swift` | Time and rate strings |
| `Looper/Info.plist` | Document types (mp4/mov/m4v/mkv) |

## Playback model

- **Engine:** `AVQueuePlayer` + `AVPlayerLooper` for seamless loop.
- **Display:** Video fills the window (no letterboxing). Scrub controls overlay
  the picture QuickTime-style (Liquid Glass bar on macOS 26+).
- **Input:** Scroll wheel up = seek forward, down = rewind. Space toggles play.
  Hold F7 / F9 to scrub; F8 play/pause; volume keys adjust Looper’s volume.
- **Performance target:** Instant playable start; playhead and scrub follow the
  monitor’s refresh (60 or 120 Hz). Video stays at native fps (30 on 60Hz is 2:1).

## Supported formats

Registered document types: **mp4**, **mov**, **m4v**, **mkv** (`Info.plist`). Open via
Finder double-click, Open With, or dragging onto the app.

## Multi-window behavior

`AppDelegate` tracks open `VideoPlayer` windows. Re-opening the same file
focuses the existing window. `AssetCache` keeps recently opened assets warm for
fast repeat opens (~6 concurrent windows is a common workload).

`WindowFrameStore` restores each file's last window size/position and feeds Open Recent.

## Build pipeline

```bash
./scripts/build-mac.sh
```

The script:

1. Runs `scripts/generate-icon.py` (Pillow) from `IconSource.png` → `.icns`
2. `xcodebuild` Release
3. Packages `build/Release/Looper.dmg` via sibling `.razorcore` scripts
4. Copies `~/Desktop/Looper.dmg` (local builds only; CI skips the Desktop copy)

It does **not** install `/Applications/Looper.app`. Drag the app from the DMG yourself.

Optional env vars: `LOOPER_SIGN_IDENTITY`, `LOOPER_ICON_PYTHON`.

## Verification

CI runs `xcodebuild` build + test. Unit tests cover URL filtering, cache/frame persistence,
and time/rate formatting. Validate playback, scrub, media keys, and multi-window behavior
manually on macOS.

## Related docs

- [BUILD_AND_RELEASE.md](../BUILD_AND_RELEASE.md)
- [CONTRIBUTING.md](../CONTRIBUTING.md)
- [AGENTS.md](../AGENTS.md)
