# Looper

<p align="center">

[![Download](https://img.shields.io/github/v/release/RazorBackRoar/Looper?style=for-the-badge&label=Download%20DMG&color=d32f2f)](https://github.com/RazorBackRoar/Looper/releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/RazorBackRoar/Looper/ci.yml?branch=main&style=for-the-badge&label=CI)](https://github.com/RazorBackRoar/Looper/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blueviolet?style=for-the-badge)](LICENSE)
[![Swift](https://img.shields.io/badge/Swift-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org/)
[![AppKit](https://img.shields.io/badge/AppKit-5E5CE6?style=for-the-badge)](https://developer.apple.com/documentation/appkit)
[![macOS](https://img.shields.io/badge/mac%20os-Apple%20Silicon-d32f2f?style=for-the-badge&logo=apple&logoColor=white)](https://support.apple.com/en-us/HT211814)

</p>

**Native macOS video player with gapless looping.**

Double-click a file or use Finder **Open With**. Several videos can be open at once. Playback is local AppKit and AVFoundation. There is no Dock icon.

<p align="center">
  <a href="https://github.com/RazorBackRoar/Looper/releases/latest/download/Looper.dmg"><strong>Download Looper.dmg</strong></a>
  ·
  <a href="https://github.com/RazorBackRoar/Looper/releases">All releases</a>
</p>

## Features

- Gapless loop with `AVQueuePlayer` and `AVPlayerLooper`
- Opens at the video's native resolution after a parallel size and playable probe
- Hidden from the Dock (`LSUIElement`). Yellow or ⌘M hides the focused window into the menu-bar list. Closing the last window quits
- The menu-bar extra lists open windows, recent files, and **Quit Looper** (⌘Q)
- Multiple windows, cascaded, with per-file frame memory
- Transparent title bar so the picture sits behind the window controls
- Scrub capsule under the video, not on top of it. Scroll to seek
- Dropping a file on a window replaces that clip. Extra files in the same drop open new windows
- Apple Silicon only. HDR/EDR only when the file is HDR
- Plays `mp4`, `mov`, and `m4v`. `mkv` can be registered for Open With, and often will not play, because there is no FFmpeg

## Install

macOS 14 or later on Apple Silicon.

1. Download [`Looper.dmg`](https://github.com/RazorBackRoar/Looper/releases/latest/download/Looper.dmg)
2. Open the DMG and drag `Looper.app` to `/Applications`
3. First launch: right-click the app and choose **Open** (ad-hoc signed build)
4. Optional default player: select a video, **Get Info**, Open with **Looper**, **Change All**. Repeat per type (`mp4`, `mov`, `m4v`)

## Keyboard shortcuts

Click the video window first.

| Key | Action |
| --- | --- |
| ⌘Q | Quit Looper |
| ⌘M | Hide the focused video in the menu bar. Select it there to restore |
| Space or F8 | Pause / resume |
| F7 / F9 | Hold to scrub backward / forward. Release to stop |
| Volume keys | Looper volume, not system volume |
| M | Mute / unmute |
| 1 | Toggle 50% and 100% speed |
| 0 | Reset speed to 100% |
| L | Rotate the picture 90° counter-clockwise (display only) |
| Return | Close this window |
| ← / → | Scrub. Hold to keep moving, including across the loop point |
| ↑ / ↓ | Volume up / down |

Scroll on the video: up or right seeks forward. Down or left seeks backward.

## Development

```bash
git clone https://github.com/RazorBackRoar/Looper.git
cd Looper
./scripts/build-mac.sh
```

The package lands at `build/Release/Looper.dmg`. Looper is an Xcode project. `./scripts/build-mac.sh` is the release path.

## Docs

- [Architecture](docs/ARCHITECTURE.md)
- [Build and release](BUILD_AND_RELEASE.md)
- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)
- [Code of conduct](CODE_OF_CONDUCT.md)

## License

MIT License. See [LICENSE](LICENSE).

Copyright © 2026 RazorBackRoar

If you need me, give me a holler.

<!-- razorcore:runtime:start -->
## Runtime Requirements

For users:
- Download the macOS `.dmg` or `.app` release. Xcode/Swift do not need to be installed.

For developers:
- Toolchain: Xcode on Apple Silicon.
- Package: `./scripts/build-mac.sh`
<!-- razorcore:runtime:end -->
