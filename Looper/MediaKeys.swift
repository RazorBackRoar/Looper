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
/// macOS `MPRemoteCommandCenter` covers play/pause (Now Playing). Hold-to-scrub
/// and Looper volume use system-defined `NSEvent`s (`NX_KEYTYPE_*`).
final class MediaKeys {
    static let shared = MediaKeys()

    var target: (() -> MediaKeyHandling?)?

    private var started = false
    private var systemMonitor: Any?
    private var lastPlayToggleAt: CFAbsoluteTime = 0
    private var lastVolumeAt: CFAbsoluteTime = 0
    private var holdForward: Bool?

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
        holdForward = nil
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
            if isKeyDown { beginScrub(forward: false) }
            if isKeyUp { endScrub() }
            return true
        case .fast, .next:
            if isKeyDown { beginScrub(forward: true) }
            if isKeyUp { endScrub() }
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
            guard let self else { return }
            if self.holdForward == forward { return }
            self.holdForward = forward
            self.target?()?.mediaBeginScrub(forward: forward)
        }
    }

    private func endScrub() {
        onMain { [weak self] in
            guard let self else { return }
            self.holdForward = nil
            self.target?()?.mediaEndScrub()
            self.refreshNowPlaying()
        }
    }

    private func nudgeVolume(_ direction: Float) {
        let now = CFAbsoluteTimeGetCurrent()
        // Repeats from the key are fine; cap the flood a little.
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
