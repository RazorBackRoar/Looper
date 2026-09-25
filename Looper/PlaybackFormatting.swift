import Foundation

enum PlaybackFormatting {
    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded(.down)))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

}

/// Mouse-wheel and hold-to-scan math. Clip length must never scale a mouse notch
/// (that is what made two-hour files jump tens of seconds per tick).
enum PlaybackScrubMath {
    static let mouseNotchSeconds: Double = 0.25
    static let mousePixelsPerNotch: Double = 8
    static let mouseEventCapSeconds: Double = 0.45
    static let holdTick: TimeInterval = 1.0 / 20.0
    static let trackpadEventCapSeconds: Double = 0.6
    static let trackpadFullGestureDelta: Double = 150
    static let trackpadTimelineFraction: Double = 0.04

    /// Classic wheel notch — fixed 1/4s of media, never a percent of the file.
    static func mouseNotchStep() -> Double {
        mouseNotchSeconds
    }

    /// Magic Mouse / high-res wheel: accumulate pixels, emit tiny steps, cap per event.
    static func consumeMousePixels(_ delta: Double, remainder: inout Double) -> Double {
        remainder += delta
        let notch = mousePixelsPerNotch
        guard abs(remainder) >= notch else { return 0 }
        let sign: Double = remainder >= 0 ? 1 : -1
        let notches = floor(abs(remainder) / notch)
        remainder = sign * (abs(remainder) - notches * notch)
        return sign * min(notches * mouseNotchSeconds, mouseEventCapSeconds)
    }

    static func trackpadStep(delta: Double, duration: Double) -> Double {
        let span = max(duration, 0.001)
        let secondsPerUnit = span * trackpadTimelineFraction / trackpadFullGestureDelta
        return min(abs(delta) * secondsPerUnit, trackpadEventCapSeconds)
    }

    /// Hold F7/F9 / media rewind-fast: a tap nudges; after ~0.16s the scan races the clip.
    static func holdStep(duration: Double, held: TimeInterval, tick: TimeInterval) -> Double {
        let dt = max(tick, 1.0 / 60.0)
        if held < 0.16 {
            return min(0.35, max(0.12, dt * 6))
        }
        let ramp = min(1, (held - 0.16) / 0.35)
        let perSecond = max(duration, 0.001) * (0.22 + 0.78 * ramp)
        return perSecond * dt
    }
}
