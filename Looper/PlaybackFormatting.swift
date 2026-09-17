import Foundation

enum PlaybackFormatting {
    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded(.down)))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    static func formatRate(_ rate: Float) -> String {
        String(format: "%g×", rate)
    }
}
