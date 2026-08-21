# Looper AGENTS

Guidance for agents in this repository. Use with `../AGENTS.md`.

## Learned User Preferences

- Never show Looper in the Dock (`LSUIElement`); never minimize to Dock; close means the window/player is fully gone.
- Push scrub, load, and double-click open as hard as possible on the M5 Pro / 64GB machine — instant playable start is the bar.
- Target 120 Hz for scrub/UI/playhead feel; play content at native 30/60 fps — do not fake 120 fps video.
- App icon is orange and white (high-resolution `.icns` / 1024×1024 source).
- Icon must sit at the same visual weight as the sibling apps: an 824×824 squircle centred in a 1024 canvas, plus a soft black drop shadow (blur 5, offset +10, peak alpha 80) — identical to MetaBurn / L!bra. Keep `IconSource.png`'s own colours; do not re-grade the chrome or orange.
- Video should fill the window (no letterbox black bars); scrub controls should overlay the video QuickTime-style (not a separate pane under the video).
- Scroll wheel: up = seek forward; down = rewind.
- Window must stay resizable — player/poster views must not lock window size.
- After every Looper code change, run `./scripts/build-mac.sh` (repo keeps only `build/Release/Looper.dmg`, **never** `Looper.app` in the project folder). The script replaces `~/Desktop/Looper.dmg`, mounts it on the Desktop, and backs up the current `/Applications/Looper.app` to `~/Desktop/Looper backup.zip`. The user drags the new `.app` from the mounted volume into `/Applications` and runs the short UAT pass; the agent does not install.

## Learned Workspace Facts

- Product is Looper at `Apps/Looper` (Swift / AppKit native video player with gapless looping) — not XQT; the early XQT scaffold was renamed/relocated here.
- Common Looper test videos live under `~/Desktop/QXT`.
- Runs as an accessory/`LSUIElement` utility: no Dock icon, document-based open via Finder / Open With.
- Release builds via `scripts/build-mac.sh` (replaces `~/Desktop/Looper.dmg`, mounts, and backs up the installed app, **never** installs to `/Applications`).
- Packaging uses shared `Apps/.razorcore` (`patch-app-branding.sh`, `package-dmg.sh`); same DMG contract as Libra/MetaBurn.
- `razorbuild Looper` from `Apps/` discovers `scripts/build-mac.sh`; autosync gates Xcode projects with `xcodebuild`.
- Keeping the process warm between opens is fine without a launchd agent.
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
