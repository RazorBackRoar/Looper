# Architecture — Looper

Developer map for the native macOS gapless video player (AppKit + AVFoundation).

Looper runs as an **accessory app** (`LSUIElement`) — no Dock icon. Each open
file gets its own resizable window.

## Module layout

| File | Role |
|------|------|
| `Looper/main.swift` | Entry; sets accessory activation policy |
| `Looper/AppDelegate.swift` | Multi-window open (Finder, argv), cascade placement |
| `Looper/VideoPlayer.swift` | Player view, scrub overlay, keyboard shortcuts |
| `Looper/AssetCache.swift` | Warm `AVURLAsset` / poster / fps cache (~1 GB budget) |
| `Looper/WindowFrameStore.swift` | Per-file window frame in `UserDefaults` |
| `Looper/Info.plist` | Document types, `LSUIElement` |

## Playback model

- **Engine:** `AVQueuePlayer` + `AVPlayerLooper` for seamless loop.
- **Display:** Video fills the window (no letterboxing). Scrub controls overlay
  the picture QuickTime-style.
- **Input:** Scroll wheel up = seek forward, down = rewind. Space toggles play.
- **Performance target:** Instant playable start; UI/scrub at 120 Hz feel; video
  plays at native frame rate (30/60 fps).

## Supported formats

Registered document types: **mp4**, **mov**, **mkv** (`Info.plist`). Open via
Finder double-click, Open With, or dragging onto the app.

## Multi-window behavior

`AppDelegate` tracks open `VideoPlayer` windows. Re-opening the same file
focuses the existing window. `AssetCache` keeps recently opened assets warm for
fast repeat opens (~6 concurrent windows is a common workload).

`WindowFrameStore` restores each file's last window size/position.

## Build pipeline

```bash
./scripts/build-mac.sh
```

The script:

1. Runs `scripts/generate-icon.py` (Pillow) from `IconSource.png` → `.icns`
2. `xcodebuild` Release
3. Installs `/Applications/Looper.app`
4. Packages `build/Release/Looper.dmg` via sibling `.razorcore` scripts

Optional env vars: `LOOPER_SIGN_IDENTITY`, `LOOPER_ICON_PYTHON`.

## Verification

CI runs `xcodebuild` only. There is **no automated UI test suite** — validate
playback, scrub, and multi-window behavior manually on macOS.

## Related docs

- [BUILD_AND_RELEASE.md](../BUILD_AND_RELEASE.md)
- [CONTRIBUTING.md](../CONTRIBUTING.md)
- [AGENTS.md](../AGENTS.md)
