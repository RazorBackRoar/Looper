# Looper

Double-click a video. It opens at its own size and loops without a gap. No Dock icon, no library, no account.

<p align="center">

[![Download](https://img.shields.io/github/v/release/RazorBackRoar/Looper?style=for-the-badge&label=Download%20DMG)](https://github.com/RazorBackRoar/Looper/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-2ea44f?style=for-the-badge&logo=apple&logoColor=white)](https://support.apple.com/en-us/HT211814)
[![Swift](https://img.shields.io/badge/Swift-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org/)

</p>

## Run it

1. Download [Looper.dmg](https://github.com/RazorBackRoar/Looper/releases/latest/download/Looper.dmg)
2. Drag **Looper.app** into Applications
3. First launch: right-click the app and choose **Open**
4. I set Looper as the default player instead of QuickTime: select a video, **Get Info**, Open with **Looper**, **Change All**

macOS 14 or later on Apple Silicon. It plays `mp4`, `mov`, and `m4v`. `mkv` can be chosen in Open With and usually will not play.

Drop another file on the window to replace it. Extra files in the same drop open their own windows. Yellow or ⌘M hides the window into the menu bar. ⌘Q quits.

| Key | Action |
| --- | --- |
| Space or F8 | Pause / resume |
| ← / → | Scrub, including across the loop |
| 1 / 0 | Half speed / full speed |
| M | Mute |
| Return | Close this window |

## Build it yourself

```bash
git clone https://github.com/RazorBackRoar/Looper.git
cd Looper
./scripts/build-mac.sh
```

The DMG lands at `build/Release/Looper.dmg`.

## License

MIT. See [LICENSE](LICENSE).

If you need me, give me a holler.

<!-- razorcore:runtime:start -->
## Runtime Requirements

For users:
- Download the macOS `.dmg` or `.app` release. Xcode/Swift do not need to be installed.

For developers:
- Toolchain: Xcode on Apple Silicon.
- Package: `./scripts/build-mac.sh`
<!-- razorcore:runtime:end -->
