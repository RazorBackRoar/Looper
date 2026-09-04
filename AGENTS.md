# Looper AGENTS

Guidance for agents in this repository. Use with `../AGENTS.md`.

## Learned User Preferences

- Regular document app (not a menu bar extra, not `LSUIElement`). Dock tile while a video is open is expected so Finder Get Info → Open With → Change All can set Looper as the default player. Never minimize player windows to the Dock; close means that window is gone.
- Push scrub, load, and double-click open as hard as possible on the M5 Pro / 64GB machine — instant playable start is the bar. Do not use a window pop/zoom-open animation; Finder’s thumbnail zoom can clip through the player on first open.
- Play content and playhead at the clip’s native fps (usually 30 or 60) — do not fake 120 fps video or drive the playhead from display Hz. Base two-finger scrub on clip duration, not refresh rate; no inertial scrub, and keep playing while scrubbing.
- Spacebar pauses/unpauses; clicking the video must never pause. Return closes only the focused player window, not every open video.
- Keyboard shortcuts apply only while a Looper video window is focused: `M` mute/unmute, `1` toggle half-speed, `L` rotate. They must do nothing when no Looper video is playing.
- App icon is orange and white (high-resolution `.icns` / 1024×1024 source).
- Icon must sit at the same visual weight as the sibling apps: an 824×824 squircle centred in a 1024 canvas, plus a soft black drop shadow (blur 5, offset +10, peak alpha 80) — identical to MetaBurn / Libra. Keep `IconSource.png`'s own colours; do not re-grade the chrome or orange.
- Video should fill the window (no letterbox black bars); scrub controls should overlay the video QuickTime-style (not a separate pane under the video).
- Scroll wheel: up = seek forward; down = rewind.
- Window must stay resizable — player/poster views must not lock window size.
- After every Looper code change, run `./scripts/build-mac.sh`. Output: `build/Release/Looper.dmg` only — never leave a `Looper.app` in the repo folder. Open that DMG yourself to install; drag into `/Applications` manually.

## Learned Workspace Facts

- Product is Looper at `Apps/Looper` (Swift / AppKit native video player with gapless looping) — not XQT; the early XQT scaffold was renamed/relocated here.
- Common Looper test videos live under `~/Desktop/QXT`.
- Regular AppKit document player: Finder double-click / Open With / Get Info → Change All. No status item.
- Release builds via `scripts/build-mac.sh`. Output: `build/Release/Looper.dmg` only.
- Packaging uses shared `Apps/.razorcore` (`patch-app-branding.sh`, `package-dmg.sh`); same DMG contract as Libra/MetaBurn.
- `razorbuild Looper` from `Apps/` discovers `scripts/build-mac.sh`; autosync gates Xcode projects with `xcodebuild`.
- Quit when the last player window closes so Finder can replace `Looper.app`. Do not leave a hidden process running. No launchd agent.
- Gatekeeper/quarantine can block Open With on ad-hoc builds or quarantined downloads — clear app quarantine on install; user may need Open Anyway for quarantined videos.
- Often plays multiple videos at once (~6 windows) — keep multi-window performance in mind.


## Jules Repository Contract

Jules reads this repository-root `AGENTS.md` when it clones the repository. Parent workspace policy files are not available in that clone.

- Jules runs tasks in an Ubuntu VM; AppKit, AVFoundation, macOS frameworks, packaged-app behavior, and Apple Silicon runtime behavior are not proven there.
- The repository's GitHub macOS `quality` workflow is authoritative for merge readiness.
- Daily audits must inspect existing open and recently closed PRs before proposing work, avoid duplicates, and open at most one focused PR per task.
- `sentinel-*` security, `bolt-*` performance, and `palette-*` design branches always require human review.
- Jules PRs are merged by the owner. There is no auto-merge workflow.
- PR descriptions must list changed files, risk, verification commands and results, benchmark evidence when relevant, and unverified paths.
- Never auto-merge runtime, dependency, lockfile, workflow, packaging, release, privacy, file-operation, or user-data changes.

## Automated Agent & Jules Integration Guidelines
- **Jules PR Review**: all Jules PRs require the owner to merge; there is no auto-merge workflow.
- **No Duplicate Issue/PR Reopening**: Jules subagents must verify existing closed and open PRs before proposing repetitive fixes or contact info updates.
- **Branch Cleanup**: Head branches are deleted automatically upon squash-merge.


### Jules Autonomous Execution Rules
- **Auto-Approve Plans**: Automatically approve execution plans for background suggestions (testing, code health, performance). Do not pause or wait for human plan approval on routine refactoring.
- **Batching**: Group related unit tests or code health fixes into a single PR rather than creating endless single-function PRs.
