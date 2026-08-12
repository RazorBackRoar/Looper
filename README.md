# Looper

[![Download](https://img.shields.io/github/v/release/RazorBackRoar/Looper?style=for-the-badge&label=Download%20DMG&color=FF8C00)](https://github.com/RazorBackRoar/Looper/releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/RazorBackRoar/Looper/ci.yml?branch=main&style=for-the-badge&label=CI)](https://github.com/RazorBackRoar/Looper/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blueviolet?style=for-the-badge)](LICENSE)
[![Swift](https://img.shields.io/badge/Swift-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org/)
[![macOS](https://img.shields.io/badge/mac%20os-Apple%20Silicon-FF8C00?style=for-the-badge&logo=apple&logoColor=white)](https://support.apple.com/en-us/HT211814)

**Minimal native macOS video player — gapless loop, instant open, QuickTime-style scrub.**

Double-click or **Open With** from Finder. No Dock icon. Multiple videos at once. Plays locally with AppKit + AVFoundation only.

<p align="center">
  <a href="https://github.com/RazorBackRoar/Looper/releases/latest/download/Looper.dmg"><strong>↓ Download Looper.dmg</strong></a>
  ·
  <a href="https://github.com/RazorBackRoar/Looper/releases">All releases</a>
</p>

## Features

- **Gapless looping** — `AVQueuePlayer` + `AVPlayerLooper`
- **Instant open** — parallel size + playable probe; native resolution window
- **Accessory utility** — `LSUIElement`, no Dock tile; stays warm between opens
- **Multi-window** — cascade placement + per-file frame memory
- **QuickTime-style scrub** — transparent overlay that auto-hides; scroll to seek without pausing
- **Drop onto a window** — replaces the current clip; extra files open in new windows
- **Apple Silicon native** — arm64 only · zero external dependencies · HDR/EDR only when the file is HDR
- **Formats** — `mp4`, `mov`, `m4v` via AVFoundation. `mkv` is registered for Open With but often cannot play (no FFmpeg)

## Install

1. Download [`Looper.dmg`](https://github.com/RazorBackRoar/Looper/releases/latest/download/Looper.dmg)
2. Open the DMG and drag **Looper.app** to `/Applications`
3. First launch — right-click → **Open** if Gatekeeper prompts (ad-hoc signed build)

Requires macOS 14+ on Apple Silicon.

## Keyboard shortcuts

Focus the video window first.

| Key | Action |
|-----|--------|
| **Space** | Pause / resume |
| **M** | Mute / unmute |
| **1** | Toggle 50% ↔ 100% speed (rate flashes on screen) |
| **L** | Rotate counter-clockwise 90° (display only) |
| **Return** | Close this window |
| **[** / **]** | Slower / faster (0.25× steps; rate flashes on screen) |
| **0** | Reset speed to 100% |
| **←** / **→** | Rewind / forward 1s |
| **Shift + ← / →** | Rewind / forward 5s |

Scroll on the video: up/right = forward · down/left = rewind.

Drop a video onto a playing window to replace it. Extra files in the same drop open in new windows.

## Development

```zsh
xcodebuild -project Looper.xcodeproj -scheme Looper -configuration Release \
  -derivedDataPath build/DerivedData -arch arm64 build
./scripts/install-to-applications.sh
```

Release DMG (shared `.razorcore` branding + locked DMG layout):

```zsh
./scripts/build-mac.sh
# or from Apps/:  uv run --project .razorcore razorbuild Looper
```

Output: `build/Release/Looper.dmg` (no loose `.app` in the repo).

See [BUILD_AND_RELEASE.md](BUILD_AND_RELEASE.md).

## Set as default player

1. Right-click a video → **Get Info**
2. **Open With** → Looper → **Change All…**

## Docs

- [BUILD_AND_RELEASE.md](BUILD_AND_RELEASE.md)
- [CONTRIBUTING.md](CONTRIBUTING.md)
- [SECURITY.md](SECURITY.md)
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)

## License

MIT — see [LICENSE](LICENSE).
Copyright © 2026 RazorBackRoar

If you need me, give me a holler.
