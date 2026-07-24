import AppKit

/// WindowFrameStore manages saving and restoring window position and size
/// keyed by individual video file paths in UserDefaults.
final class WindowFrameStore {
    private static let userDefaultsPrefix = "Looper_WindowFrame_"

    /// Generates a unique storage key for a video file URL.
    private static func storageKey(for url: URL) -> String {
        return userDefaultsPrefix + url.path
    }

    /// Saves the specified window frame for a video file URL.
    static func saveFrame(_ frame: NSRect, for url: URL) {
        let frameString = NSStringFromRect(frame)
        UserDefaults.standard.set(frameString, forKey: storageKey(for: url))
    }

    /// Retrieves a previously stored window frame for a video file URL if it exists.
    static func loadFrame(for url: URL) -> NSRect? {
        guard let frameString = UserDefaults.standard.string(forKey: storageKey(for: url)) else {
            return nil
        }
        let frame = NSRectFromString(frameString)
        return frame.isEmpty ? nil : frame
    }
}
