import AppKit

enum LocalVideoURL {
    static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv"]

    /// Looper only plays files on disk. Network and custom-scheme URLs must not
    /// reach AVURLAsset (CWE-918).
    static func isPlayableFile(_ url: URL) -> Bool {
        url.isFileURL && supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func onlyPlayableFiles(_ urls: [URL]) -> [URL] {
        urls.filter(isPlayableFile)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [NSWindowController] = []
    private var cascadePoint = NSPoint(x: 200, y: 600)
    private var didReceiveOpenFiles = false
    private var statusItem: NSStatusItem?
    private var recentsMenuItem: NSMenuItem?
    private var quitKeyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        MediaKeys.shared.target = { [weak self] in self?.keyPlayer }
        MediaKeys.shared.start()
        quitKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.contains(.command),
                  !mods.contains(.shift),
                  !mods.contains(.option),
                  !mods.contains(.control),
                  event.charactersIgnoringModifiers?.lowercased() == "q"
            else { return event }
            NSApp.terminate(nil)
            return nil
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Terminal / argv launches may not deliver Apple Events — pick those up here.
        if !didReceiveOpenFiles {
            let urls = CommandLine.arguments.dropFirst()
                .filter { !$0.hasPrefix("-") }
                .map { URL(fileURLWithPath: $0) }
            if !urls.isEmpty {
                openVideos(at: Array(urls))
            }
        }
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
        if !isTesting {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.windowControllers.isEmpty {
                    NSApp.terminate(nil)
                }
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
        openVideos(at: LocalVideoURL.onlyPlayableFiles(urls))
    }

    /// Spawns an independent video player window for each URL provided.
    @MainActor func openVideos(at urls: [URL]) {
        for url in LocalVideoURL.onlyPlayableFiles(urls) {
            let standardPath = url.standardizedFileURL.path
            if let existing = windowControllers.compactMap({ $0 as? VideoPlayerWindowController }).first(where: {
                $0.videoURL.standardizedFileURL.path == standardPath
            }) {
                existing.window?.makeKeyAndOrderFront(nil)
                existing.window?.orderFrontRegardless()
                continue
            }

            AssetCache.preload(url)
            WindowFrameStore.noteOpened(url)
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
        updateStatusItem()
        rebuildRecentsMenu()
    }

    /// Cleanly removes window controller references when closed.
    @MainActor func windowWillClose(_ controller: NSWindowController) {
        windowControllers.removeAll { $0 === controller }
        updateStatusItem()
        rebuildRecentsMenu()
        MediaKeys.shared.refreshNowPlaying()
        // Quit with the last window so Finder can replace Looper.app and so
        // Get Info → Change All is not blocked by a leftover process.
        if windowControllers.isEmpty {
            NSApp.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Never invent a blank window / Dock re-open behavior.
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AssetCache.cancelAllLoads()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let quitKeyMonitor {
            NSEvent.removeMonitor(quitKeyMonitor)
            self.quitKeyMonitor = nil
        }
        MediaKeys.shared.stop()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @MainActor private var keyPlayer: VideoPlayerWindowController? {
        let players = windowControllers.compactMap { $0 as? VideoPlayerWindowController }
        return players.first { $0.window?.isKeyWindow == true } ?? players.last
    }

    // MARK: - Menu bar (accessory app: status item is the visible menu)

    @MainActor private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Looper")
        appMenu.addItem(withTitle: "About Looper", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Looper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let recents = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recents.submenu = NSMenu(title: "Open Recent")
        recentsMenuItem = recents
        fileMenu.addItem(recents)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        rebuildRecentsMenu()
    }

    @MainActor private func updateStatusItem() {
        if windowControllers.isEmpty {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
            return
        }

        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if #available(macOS 26.0, *) {
                // Status items already use Liquid Glass; keep a template glyph on it.
                item.button?.image = NSImage(systemSymbolName: "repeat", accessibilityDescription: "Looper")
            } else {
                item.button?.image = NSImage(systemSymbolName: "repeat", accessibilityDescription: "Looper")
            }
            item.button?.image?.isTemplate = true
            item.button?.toolTip = "Looper"
            statusItem = item
        }
        rebuildStatusMenu()
    }

    @MainActor private func rebuildStatusMenu() {
        let menu = NSMenu()

        let windowsHeader = NSMenuItem(title: "Windows", action: nil, keyEquivalent: "")
        windowsHeader.isEnabled = false
        menu.addItem(windowsHeader)

        let players = windowControllers.compactMap { $0 as? VideoPlayerWindowController }
        if players.isEmpty {
            let empty = NSMenuItem(title: "None Open", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for player in players {
                let title = player.window?.title ?? player.videoURL.lastPathComponent
                let item = NSMenuItem(title: title, action: #selector(focusPlayerWindow(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = player
                item.state = player.window?.isKeyWindow == true ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let recentsHeader = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentsHeader.isEnabled = false
        menu.addItem(recentsHeader)
        appendRecentItems(to: menu)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Looper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    @MainActor private func rebuildRecentsMenu() {
        let submenu = NSMenu(title: "Open Recent")
        appendRecentItems(to: submenu)
        if submenu.items.isEmpty {
            let empty = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        recentsMenuItem?.submenu = submenu
        if statusItem != nil {
            rebuildStatusMenu()
        }
    }

    @MainActor private func appendRecentItems(to menu: NSMenu) {
        let recents = WindowFrameStore.recentFileURLs()
        for url in recents {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecentFile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
    }

    @MainActor @objc private func focusPlayerWindow(_ sender: NSMenuItem) {
        guard let player = sender.representedObject as? VideoPlayerWindowController else { return }
        player.window?.makeKeyAndOrderFront(nil)
        player.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        rebuildStatusMenu()
    }

    @MainActor @objc private func openRecentFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openVideos(at: [url])
    }
}
