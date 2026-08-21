# Build & Release — Looper

Organization-standard build and release guide for
[RazorBackRoar/Looper](https://github.com/RazorBackRoar/Looper).

## Overview

Looper is a native macOS app built with **Swift** / **AppKit** (Xcode project,
macOS 14+), packaged with an ad-hoc or Developer ID–signed `.dmg` via shared
`Apps/.razorcore` helpers (`patch-app-branding.sh`, `package-dmg.sh`).

Built artifact is a single `Looper.dmg` under `build/Release/`; the `.app`
bundle is consumed during packaging and not left in the repo. The build also
replaces `~/Desktop/Looper.dmg`, mounts it on the Desktop, and backs up the
current `/Applications/Looper.app` to `~/Desktop/Looper backup.zip`. The user
drags the new `.app` into `/Applications`; the build does not install it.

## Platform Requirements

| Requirement | Value |
|-------------|-------|
| OS | macOS 14+ |
| Arch | Apple Silicon (`arm64`) |
| Toolchain | Xcode 15+ (`xcodebuild`) |

## Prerequisites

```zsh
xcode-select -p
cd /path/to/Looper
xcodebuild -project Looper.xcodeproj -scheme Looper -configuration Release -arch arm64 build
```

## Development Build

```zsh
xcodebuild -project Looper.xcodeproj -scheme Looper -configuration Release \
  -derivedDataPath build/DerivedData -arch arm64 build
./scripts/install-to-applications.sh
```

## Packaging (release)

```zsh
./scripts/build-mac.sh
```

Or from `Apps/`:

```zsh
uv run --project .razorcore razorbuild Looper
```

Output:

```text
build/Release/Looper.dmg
```

Side effect: `/Applications/Looper.app` is replaced (install script stops any
running Looper process automatically).

## DMG contract (shared `.razorcore`)

1. `patch-app-branding.sh` — copyright stamp before codesign
2. `codesign` the `.app`
3. `package-dmg.sh` — locked 500×420 layout + verify
4. Remove staging `.app`; repo keeps **only** the `.dmg`

## Release Process

1. Ensure `main` is green (CI `xcodebuild`).
2. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `Looper.xcodeproj`.
3. Run `./scripts/build-mac.sh`.
4. Smoke-test from `/Applications/Looper.app` or by mounting `build/Release/Looper.dmg`.
5. Publish a GitHub Release with title `Looper vX.Y.Z` and attach `build/Release/Looper.dmg`.
6. Tag `vX.Y.Z` to match `MARKETING_VERSION`.

## Versioning

- Marketing version: `Looper/Info.plist` + Xcode `MARKETING_VERSION`
- Build number: `CURRENT_PROJECT_VERSION` in `Looper.xcodeproj`

## Troubleshooting

| Symptom | What to try |
|---------|-------------|
| Gatekeeper blocks Open With | Clear quarantine on install; **Open Anyway** once |
| Stale build in use | Re-run `./scripts/build-mac.sh` (replaces `/Applications/Looper.app`) |
| Finder clip-through on open | Focused window uses floating level; click away to send Looper behind other apps |

## Related Docs

- [README.md](README.md)
- [CONTRIBUTING.md](CONTRIBUTING.md)
- [SECURITY.md](SECURITY.md)
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
