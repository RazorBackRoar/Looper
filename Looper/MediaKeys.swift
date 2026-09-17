import AppKit
import MediaPlayer

protocol MediaKeyHandling: AnyObject {
    var mediaTitle: String { get }
    var mediaElapsed: Double { get }
    var mediaDuration: Double { get }
    var mediaRate: Float { get }
    var mediaIsPlaying: Bool { get }

    func mediaTogglePlayPause()
    func mediaBeginScrub(forward: Bool)
    func mediaEndScrub()
    func mediaAdjustVolume(by delta: Float)
    func mediaToggleMute()
}

/// F7 / F8 / F9 and volume keys arrive as media-key events, not `keyDown`.
/// Holding Rewind/Fast starts as Previous/Next, then flips HID codes — we must
/// not treat that first key-up as “let go”.
final class MediaKeys {
    static let shared = MediaKeys()

    var target: (() -> MediaKeyHandling?)?

    private var started = false
    private var systemMonitor: Any?
    private var lastPlayToggleAt: CFAbsoluteTime = 0
    private var lastVolumeAt: CFAbsoluteTime = 0
    private var rewindKeysDown = Set<Int32>()
    private var forwardKeysDown = Set<Int32>()
    private var stopHoldWork: DispatchWorkItem?
    private var holdBeganAt: CFAbsoluteTime = 0

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        installRemoteCommands()
        installSystemDefinedMonitor()
    }

    func stop() {
        guard started else { return }
        started = false
        stopHoldWork?.cancel()
        stopHoldWork = nil
        rewindKeysDown.removeAll()
        forwardKeysDown.removeAll()
        if let systemMonitor {
            NSEvent.removeMonitor(systemMonitor)
            self.systemMonitor = nil
        }
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.removeTarget(nil)
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func refreshNowPlaying() {
        guard let player = target?() else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: player.mediaTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.mediaElapsed,
            MPMediaItemPropertyPlaybackDuration: player.mediaDuration,
            MPNowPlayingInfoPropertyPlaybackRate: player.mediaRate,
        ]
        MPNowPlayingInfoCenter.default().playbackState = player.mediaIsPlaying ? .playing : .paused
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false

        center.togglePlayPauseCommand.isEnabled = true
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlay()
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            self?.setPlaying(true)
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.setPlaying(false)
            return .success
        }
    }

    private func installSystemDefinedMonitor() {
        systemMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let self else { return event }
            return self.handleSystemDefined(event) ? nil : event
        }
    }

    /// HID system-defined keys (`IOKit/hidsystem/ev_keymap.h`).
    private enum NXKeyType: Int32 {
        case soundUp = 0
        case soundDown = 1
        case mute = 2
        case play = 16
        case next = 17
        case previous = 18
        case fast = 19
        case rewind = 20
    }

    private func handleSystemDefined(_ event: NSEvent) -> Bool {
        guard event.subtype.rawValue == 8 else { return false }

        let keyCode = Int32((event.data1 & 0xFFFF0000) >> 16)
        let keyFlags = Int32(event.data1 & 0x0000FFFF)
        let keyState = (keyFlags & 0xFF00) >> 8
        let isKeyDown = keyState == 0xA
        let isKeyUp = keyState == 0xB
        guard let type = NXKeyType(rawValue: keyCode) else { return false }
        guard target?() != nil else { return false }

        switch type {
        case .play:
            if isKeyDown { togglePlay() }
            return true
        case .rewind, .previous:
            updateHold(key: type.rawValue, down: isKeyDown, up: isKeyUp, forward: false)
            return true
        case .fast, .next:
            updateHold(key: type.rawValue, down: isKeyDown, up: isKeyUp, forward: true)
            return true
        case .soundUp:
            if isKeyDown { nudgeVolume(1) }
            return true
        case .soundDown:
            if isKeyDown { nudgeVolume(-1) }
            return true
        case .mute:
            if isKeyDown {
                onMain { self.target?()?.mediaToggleMute() }
            }
            return true
        }
    }

    private func updateHold(key: Int32, down: Bool, up: Bool, forward: Bool) {
        if down {
            stopHoldWork?.cancel()
            stopHoldWork = nil
            let wasIdle = rewindKeysDown.isEmpty && forwardKeysDown.isEmpty
            if forward {
                forwardKeysDown.insert(key)
                rewindKeysDown.removeAll()
            } else {
                rewindKeysDown.insert(key)
                forwardKeysDown.removeAll()
            }
            if wasIdle {
                holdBeganAt = CFAbsoluteTimeGetCurrent()
            }
            beginScrub(forward: forward)
            return
        }
        guard up else { return }
        if forward {
            forwardKeysDown.remove(key)
        } else {
            rewindKeysDown.remove(key)
        }
        let stillHolding = forward ? !forwardKeysDown.isEmpty : !rewindKeysDown.isEmpty
        if stillHolding { return }

        let isScanKey = key == NXKeyType.rewind.rawValue || key == NXKeyType.fast.rawValue
        if isScanKey {
            endScrub()
            return
        }

        // Tap of Previous/Next: stop now so one click stays a nudge.
        // Hold flips Previous→Rewind after a beat — wait for that down, don't die on the flip.
        let held = CFAbsoluteTimeGetCurrent() - holdBeganAt
        if held < 0.28 {
            endScrub()
            return
        }

        stopHoldWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let holding = forward ? !self.forwardKeysDown.isEmpty : !self.rewindKeysDown.isEmpty
            if !holding {
                self.endScrub()
            }
        }
        stopHoldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func togglePlay() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPlayToggleAt > 0.12 else { return }
        lastPlayToggleAt = now
        onMain { [weak self] in
            self?.target?()?.mediaTogglePlayPause()
            self?.refreshNowPlaying()
        }
    }

    private func setPlaying(_ playing: Bool) {
        onMain { [weak self] in
            guard let player = self?.target?() else { return }
            if player.mediaIsPlaying != playing {
                player.mediaTogglePlayPause()
            }
            self?.refreshNowPlaying()
        }
    }

    private func beginScrub(forward: Bool) {
        onMain { [weak self] in
            self?.target?()?.mediaBeginScrub(forward: forward)
        }
    }

    private func endScrub() {
        onMain { [weak self] in
            guard let self else { return }
            self.rewindKeysDown.removeAll()
            self.forwardKeysDown.removeAll()
            self.target?()?.mediaEndScrub()
            self.refreshNowPlaying()
        }
    }

    private func nudgeVolume(_ direction: Float) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastVolumeAt > 0.04 else { return }
        lastVolumeAt = now
        onMain { [weak self] in
            self?.target?()?.mediaAdjustVolume(by: 0.05 * direction)
        }
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }
}
