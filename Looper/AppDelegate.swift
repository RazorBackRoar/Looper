import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [NSWindowController] = []
    private var cascadePoint = NSPoint(x: 200, y: 600)
    private var didReceiveOpenFiles = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Background utility mode (LSUIElement = true).
        // Terminal / argv launches may not deliver Apple Events — pick those up here.
        if !didReceiveOpenFiles {
            let urls = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
            if !urls.isEmpty {
                openVideos(at: Array(urls))
            }
        }
    }

    /// Prevents AppKit from opening a blank default window on startup.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Required for non-NSDocument apps with CFBundleDocumentTypes (returns true = we handled it).
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        didReceiveOpenFiles = true
        openVideos(at: [URL(fileURLWithPath: filename)])
        return true
    }

    /// Handles Finder double-click or 'Open With' file array delegates.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        didReceiveOpenFiles = true
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        openVideos(at: urls)
        sender.reply(toOpenOrPrint: .success)
    }

    /// Handles incoming file URL open requests.
    func application(_ application: NSApplication, open urls: [URL]) {
        didReceiveOpenFiles = true
        openVideos(at: urls)
    }

    /// Spawns an independent video player window for each URL provided.
    func openVideos(at urls: [URL]) {
        for url in urls {
            AssetCache.preload(url)
            let windowController = VideoPlayerWindowController(videoURL: url, initialCascadePoint: cascadePoint)

            // Advance cascade point for subsequent window placement
            cascadePoint.x += 30
            cascadePoint.y -= 30

            // Reset cascade point if drifting near screen edges
            if let screen = NSScreen.main {
                if cascadePoint.x > screen.visibleFrame.width - 400 || cascadePoint.y < 100 {
                    cascadePoint = NSPoint(x: 200, y: screen.visibleFrame.height - 200)
                }
            }

            windowControllers.append(windowController)
            // Window reveals itself only after native size + first frame are ready
            // (avoids the first-open size/thumbnail flash).
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Cleanly removes window controller references when closed.
    func windowWillClose(_ controller: NSWindowController) {
        windowControllers.removeAll { $0 === controller }
        // Stay alive as an agent (no Dock) so the next double-click hits warm AssetCache.
        // With zero windows there is still nothing in the Dock.
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Never invent a blank window / Dock re-open behavior.
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep process warm for instant next open. No Dock icon either way (LSUIElement).
        return false
    }
}
