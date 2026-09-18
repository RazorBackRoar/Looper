import AppKit

/// WindowFrameStore manages saving and restoring window position and size
/// keyed by individual video file paths in UserDefaults.
enum WindowFrameStore {
    nonisolated(unsafe) static var defaults = UserDefaults.standard

    static let framesKey = "Looper.windowFrames"
    static let orderKey = "Looper.windowFrameOrder"
    private static let migratedKey = "Looper.windowFrames.migrated"
    private static let legacyPrefix = "Looper_WindowFrame_"
    private static let maxEntries = 400
    private static let trimTo = 300
    static let maxRecents = 12

    /// Saves the specified window frame for a video file URL.
    static func saveFrame(_ frame: NSRect, for url: URL) {
        migrateLegacyIfNeeded()
        let path = url.standardizedFileURL.path
        var dict = loadDict()
        var order = loadOrder()
        dict[path] = NSStringFromRect(frame)
        order.removeAll { $0 == path }
        order.append(path)
        trimIfNeeded(dict: &dict, order: &order)
        defaults.set(dict, forKey: framesKey)
        defaults.set(order, forKey: orderKey)
    }

    /// Records an opened file so it appears in Open Recent even before a move/resize.
    static func noteOpened(_ url: URL) {
        migrateLegacyIfNeeded()
        let path = url.standardizedFileURL.path
        var order = loadOrder()
        order.removeAll { $0 == path }
        order.append(path)
        var dict = loadDict()
        trimIfNeeded(dict: &dict, order: &order)
        defaults.set(dict, forKey: framesKey)
        defaults.set(order, forKey: orderKey)
    }

    /// Retrieves a previously stored window frame for a video file URL if it exists.
    static func loadFrame(for url: URL) -> NSRect? {
        migrateLegacyIfNeeded()
        let path = url.standardizedFileURL.path
        if let frameString = loadDict()[path] {
            let frame = NSRectFromString(frameString)
            return frame.isEmpty ? nil : frame
        }
        return nil
    }

    /// Most recently opened files, newest first, that still exist on disk.
    static func recentFileURLs() -> [URL] {
        migrateLegacyIfNeeded()
        var seen = Set<String>()
        var urls: [URL] = []
        for path in loadOrder().reversed() {
            if seen.contains(path) { continue }
            seen.insert(path)
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            urls.append(url)
            if urls.count >= maxRecents { break }
        }
        return urls
    }

    static func storedFrameCount() -> Int {
        migrateLegacyIfNeeded()
        return loadDict().count
    }

    private static func loadDict() -> [String: String] {
        (defaults.dictionary(forKey: framesKey) as? [String: String]) ?? [:]
    }

    private static func loadOrder() -> [String] {
        defaults.stringArray(forKey: orderKey) ?? []
    }

    private static func trimIfNeeded(dict: inout [String: String], order: inout [String]) {
        guard dict.count > maxEntries else { return }
        let keep = Array(order.suffix(trimTo))
        let keepSet = Set(keep)
        dict = dict.filter { keepSet.contains($0.key) }
        order = keep
    }

    private static func migrateLegacyIfNeeded() {
        guard !defaults.bool(forKey: migratedKey) else { return }
        var dict = loadDict()
        var order = loadOrder()
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key.hasPrefix(legacyPrefix), let frameString = value as? String else { continue }
            let path = String(key.dropFirst(legacyPrefix.count))
            if dict[path] == nil {
                dict[path] = frameString
                order.append(path)
            }
            defaults.removeObject(forKey: key)
        }
        trimIfNeeded(dict: &dict, order: &order)
        defaults.set(dict, forKey: framesKey)
        defaults.set(order, forKey: orderKey)
        defaults.set(true, forKey: migratedKey)
    }
}
