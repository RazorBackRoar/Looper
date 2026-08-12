import AppKit
import AVFoundation
import QuartzCore

/// HDR on the video layer only when the clip is HDR. SDR stays standard (no EDR).
private func applyPlayerEDR(_ layer: CALayer, hdr: Bool) {
    if #available(macOS 26.0, *) {
        layer.preferredDynamicRange = hdr ? .high : .standard
    } else {
        layer.wantsExtendedDynamicRangeContent = hdr
    }
}

// MARK: - Video surface (fills window; aspect ratio locked on resize)

private final class PlayerLayerView: NSView {
    private let playerLayer = AVPlayerLayer()
    /// 0–3 quarter-turns counter-clockwise (display only; file unchanged).
    var rotationQuarterTurns = 0
    private var hdrEnabled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.black.cgColor
        applyPlayerEDR(playerLayer, hdr: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = NSColor.black.cgColor
        if playerLayer.superlayer !== layer {
            layer.addSublayer(playerLayer)
        }
        applyPlayerEDR(playerLayer, hdr: hdrEnabled)
        layoutPlayerLayerForRotation()
    }

    func setHDR(_ hdr: Bool) {
        hdrEnabled = hdr
        applyPlayerEDR(playerLayer, hdr: hdr)
    }

    private func layoutPlayerLayerForRotation() {
        guard let layer else { return }
        let bounds = layer.bounds
        let q = ((rotationQuarterTurns % 4) + 4) % 4

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        switch q {
        case 0:
            playerLayer.bounds = CGRect(origin: .zero, size: bounds.size)
            playerLayer.transform = CATransform3DIdentity
        case 1: // 90° CCW
            playerLayer.bounds = CGRect(origin: .zero, size: CGSize(width: bounds.height, height: bounds.width))
            playerLayer.transform = CATransform3DMakeRotation(.pi / 2, 0, 0, 1)
        case 2: // 180°
            playerLayer.bounds = CGRect(origin: .zero, size: bounds.size)
            playerLayer.transform = CATransform3DMakeRotation(.pi, 0, 0, 1)
        case 3: // 270° CCW
            playerLayer.bounds = CGRect(origin: .zero, size: CGSize(width: bounds.height, height: bounds.width))
            playerLayer.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
        default:
            break
        }
        CATransaction.commit()
    }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override func layout() {
        super.layout()
        layoutPlayerLayerForRotation()
    }
}

// MARK: - Minimal transparent scrub (no NSSlider black chrome)

private final class VideoScrubBar: NSView {
    var value: Double = 0
    var maxValue: Double = 1
    var onScrubStart: (() -> Void)?
    var onScrubEnd: (() -> Void)?
    var onValueChanged: ((Double) -> Void)?
    var onScroll: ((NSEvent) -> Void)?

    private var dragging = false

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 12
        let trackW = max(bounds.width - inset * 2, 1)
        let trackY = bounds.midY
        let trackH: CGFloat = 3
        let fraction = maxValue > 0 ? min(1, max(0, value / maxValue)) : 0

        let track = NSRect(x: inset, y: trackY - trackH / 2, width: trackW, height: trackH)
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()

        let progress = NSRect(x: inset, y: trackY - trackH / 2, width: trackW * fraction, height: trackH)
        NSColor(calibratedRed: 0.2, green: 0.55, blue: 1.0, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: progress, xRadius: 1.5, yRadius: 1.5).fill()

        let knobX = round(inset + trackW * fraction)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: knobX - 5, y: trackY - 5, width: 10, height: 10)).fill()
    }

    /// Pixel X of the knob center — used to skip redundant redraws during playback.
    var knobPixelX: CGFloat {
        let inset: CGFloat = 12
        let trackW = max(bounds.width - inset * 2, 1)
        let fraction = maxValue > 0 ? min(1, max(0, value / maxValue)) : 0
        return round(inset + trackW * fraction)
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        onScrubStart?()
        scrubTo(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        scrubTo(event)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        onScrubEnd?()
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }

    private func scrubTo(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let inset: CGFloat = 12
        let trackW = max(bounds.width - inset * 2, 1)
        let fraction = min(1, max(0, (x - inset) / trackW))
        value = fraction * maxValue
        onValueChanged?(value)
        needsDisplay = true
    }
}

// MARK: - Minimal transparent volume slider

private final class VolumeSlider: NSView {
    var value: Double = 1.0 {
        didSet { needsDisplay = true }
    }
    var onValueChanged: ((Double) -> Void)?

    private var dragging = false

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 6
        let iconW: CGFloat = 12
        let iconGap: CGFloat = 6
        let trackInsetLeft = inset + iconW + iconGap
        let trackW = max(bounds.width - trackInsetLeft - inset, 1)
        let trackY = bounds.midY
        let trackH: CGFloat = 3
        let fraction = min(1, max(0, value))

        drawSpeaker(in: NSRect(x: inset, y: trackY - iconW / 2, width: iconW, height: iconW))

        let track = NSRect(x: trackInsetLeft, y: trackY - trackH / 2, width: trackW, height: trackH)
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()

        let progress = NSRect(x: trackInsetLeft, y: trackY - trackH / 2, width: trackW * fraction, height: trackH)
        NSColor(calibratedRed: 0.2, green: 0.55, blue: 1.0, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: progress, xRadius: 1.5, yRadius: 1.5).fill()

        let knobX = round(trackInsetLeft + trackW * fraction)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: knobX - 4, y: trackY - 4, width: 8, height: 8)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        setVolume(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        setVolume(for: event)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
    }

    private func setVolume(for event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let inset: CGFloat = 6
        let iconW: CGFloat = 12
        let iconGap: CGFloat = 6
        let trackInsetLeft = inset + iconW + iconGap
        let trackW = max(bounds.width - trackInsetLeft - inset, 1)
        let fraction = min(1, max(0, (x - trackInsetLeft) / trackW))
        value = fraction
        onValueChanged?(value)
    }

    private func drawSpeaker(in rect: NSRect) {
        let bodyW: CGFloat = 5
        let bodyH: CGFloat = 6
        let bodyRect = NSRect(
            x: rect.minX,
            y: rect.midY - bodyH / 2,
            width: bodyW,
            height: bodyH
        )
        NSColor.white.setFill()
        NSBezierPath(roundedRect: bodyRect, xRadius: 1, yRadius: 1).fill()

        let cone = NSBezierPath()
        cone.move(to: NSPoint(x: bodyRect.maxX, y: bodyRect.minY))
        cone.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        cone.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        cone.line(to: NSPoint(x: bodyRect.maxX, y: bodyRect.maxY))
        cone.close()
        NSColor.white.setFill()
        cone.fill()
    }
}

// MARK: - Transparent QT-style overlay (subtle gradient, video shows through)

private final class OverlayBarView: NSView {
    var onScroll: ((NSEvent) -> Void)?

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let colors = [
            NSColor.black.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(0.45).cgColor,
        ] as CFArray
        let space = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: bounds.midX, y: bounds.maxY),
                end: CGPoint(x: bounds.midX, y: bounds.minY),
                options: []
            )
        }
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self { return nil }
        return hit
    }
}

// MARK: - Scroll catcher over the full picture (focus only — no click-to-pause)

private final class VideoScrollView: NSView {
    var onScroll: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Root content view: file drops bubble here; tracking area sees mouse over subviews.
private final class FileDropView: NSView {
    var onDropURLs: (([URL]) -> Void)?
    var onMouseMoved: ((NSEvent) -> Void)?
    var onMouseExited: (() -> Void)?

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv"]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(event)
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseMoved?(event)
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.videoURLs(from: sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !Self.videoURLs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.videoURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDropURLs?(urls)
        return true
    }

    static func videoURLs(from sender: NSDraggingInfo) -> [URL] {
        let pb = sender.draggingPasteboard
        var urls: [URL] = []
        if let read = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            urls.append(contentsOf: read)
        }
        if urls.isEmpty, let items = pb.pasteboardItems {
            for item in items {
                if let str = item.string(forType: .fileURL), let url = URL(string: str) {
                    urls.append(url)
                }
            }
        }
        return urls.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
    }
}

private final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Player window

/// Maxed local player: instant open, aggressive scrub, gapless loop. Never minimizes to Dock.
final class VideoPlayerWindowController: NSWindowController, NSWindowDelegate {
    private var videoURL: URL
    private let cascadeOrigin: NSPoint
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var playerSurface: PlayerLayerView!
    private var clickView: VideoScrollView!
    private var scrubBar: VideoScrubBar!
    private var elapsedLabel: NSTextField!
    private var remainingLabel: NSTextField!
    private var volumeSlider: VolumeSlider!
    private var controlsBar: OverlayBarView!
    private var rateHUD: PassthroughLabel!
    private var currentRate: Float = 1.0
    private var durationSeconds: Double = 0
    private var isScrubbing = false
    private var timeObserver: Any?
    private var keyMonitor: Any?
    private var statusObservation: NSKeyValueObservation?
    private var lastCoarseSeekAt: CFAbsoluteTime = 0
    private var seekSerial = 0
    private var didReveal = false
    private var scrollScrubActive = false
    private var scrollEndWork: DispatchWorkItem?
    private var scrollSeekWork: DispatchWorkItem?
    private var scrollSeekPending: Double?
    private var lastScrollSeekAt: CFAbsoluteTime = 0
    private var lastKnobPixelX: CGFloat = -1
    private var videoPixelSize: CGSize?
    private var videoFrameRate: Float = 30
    private var displayQuarterTurns = 0
    private var didResolveFrameRate = false
    private var preMuteVolume: Float = 1.0
    private var hideControlsWork: DispatchWorkItem?
    private var rateHUDHideWork: DispatchWorkItem?
    /// ~one deliberate two-finger swipe on a trackpad (cumulative |delta|).
    private static let scrollFullGestureDelta: Double = 150
    private static let controlsBarHeight: CGFloat = 36
    private static let controlsHideDelay: TimeInterval = 2.4
    /// Fraction of the clip traversed by that full swipe (4% — same finger travel, any length).
    private static let scrollTimelineFraction: Double = 0.04
    /// Cap coarse seeks during scroll scrub (10/s) so 3.5K doesn't choke AVPlayer.
    private static let scrollSeekInterval: Double = 0.10
    /// Mouse-drag scrub coarse seek cap (also clip-aware, not display Hz).
    private static let dragSeekInterval: Double = 1.0 / 15.0

    init(videoURL: URL, initialCascadePoint: NSPoint) {
        self.videoURL = videoURL
        self.cascadeOrigin = initialCascadePoint
        AssetCache.preload(videoURL)

        // Temporary content rect — replaced with native size before the window is shown.
        let initialRect = NSRect(x: initialCascadePoint.x, y: initialCascadePoint.y, width: 640, height: 360)

        let window = NSWindow(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = videoURL.lastPathComponent
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 320, height: 200)
        window.styleMask.insert(.resizable)
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = true
        window.animationBehavior = .none
        window.isRestorable = false
        window.alphaValue = 1
        // Normal when inactive so other apps can stack above; .floating only while key (Finder clip-through).
        window.level = .normal

        super.init(window: window)
        window.delegate = self

        setupUI()
        // Cover Finder's thumbnail zoom immediately with opaque black — no wait, no pop.
        if let cached = AssetCache.cachedNativeSize(for: videoURL) {
            applyNativeWindowSize(cached)
            didApplyNativeSize = true
        }
        slamOpaqueFront()
        bootPlayerFast()
        installKeyMonitor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        tearDownPlayback()
    }

    // MARK: - UI

    private func setupUI() {
        guard let window else { return }
        let dropView = FileDropView(frame: window.contentView?.bounds ?? .zero)
        dropView.autoresizingMask = [.width, .height]
        dropView.onDropURLs = { [weak self] urls in self?.handleDroppedURLs(urls) }
        dropView.onMouseMoved = { [weak self] event in self?.handleMouseMoved(event) }
        dropView.onMouseExited = { [weak self] in self?.scheduleHideControls(delay: 0.45) }
        window.contentView = dropView
        let content = dropView
        let barHeight = Self.controlsBarHeight

        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor

        playerSurface = PlayerLayerView(frame: .zero)
        playerSurface.translatesAutoresizingMaskIntoConstraints = false
        playerSurface.setContentHuggingPriority(.defaultLow, for: .horizontal)
        playerSurface.setContentHuggingPriority(.defaultLow, for: .vertical)
        playerSurface.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        playerSurface.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        content.addSubview(playerSurface)

        // Full-bleed click + scroll over the picture (controls sit above).
        clickView = VideoScrollView(frame: .zero)
        clickView.translatesAutoresizingMaskIntoConstraints = false
        clickView.onScroll = { [weak self] event in self?.handleScrollWheel(event) }
        content.addSubview(clickView)

        controlsBar = OverlayBarView(frame: .zero)
        controlsBar.translatesAutoresizingMaskIntoConstraints = false
        controlsBar.onScroll = { [weak self] event in self?.handleScrollWheel(event) }
        content.addSubview(controlsBar)

        elapsedLabel = makeTimeLabel("0:00")
        remainingLabel = makeTimeLabel("-0:00")

        scrubBar = VideoScrubBar(frame: .zero)
        scrubBar.translatesAutoresizingMaskIntoConstraints = false
        scrubBar.onScrubStart = { [weak self] in self?.scrubStarted() }
        scrubBar.onScrubEnd = { [weak self] in self?.scrubEnded() }
        scrubBar.onValueChanged = { [weak self] seconds in
            self?.scrubValueChanged(seconds)
        }
        scrubBar.onScroll = { [weak self] event in self?.handleScrollWheel(event) }

        volumeSlider = VolumeSlider(frame: .zero)
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.value = 1.0
        volumeSlider.onValueChanged = { [weak self] volume in
            self?.applyVolume(Float(volume))
        }

        controlsBar.addSubview(elapsedLabel)
        controlsBar.addSubview(scrubBar)
        controlsBar.addSubview(remainingLabel)
        controlsBar.addSubview(volumeSlider)

        rateHUD = makeRateHUD()
        content.addSubview(rateHUD)

        NSLayoutConstraint.activate([
            playerSurface.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerSurface.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerSurface.topAnchor.constraint(equalTo: content.topAnchor),
            playerSurface.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            clickView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            clickView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            clickView.topAnchor.constraint(equalTo: content.topAnchor),
            clickView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            controlsBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            controlsBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            controlsBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            controlsBar.heightAnchor.constraint(equalToConstant: barHeight),

            elapsedLabel.leadingAnchor.constraint(equalTo: controlsBar.leadingAnchor, constant: 12),
            elapsedLabel.centerYAnchor.constraint(equalTo: controlsBar.centerYAnchor),
            elapsedLabel.widthAnchor.constraint(equalToConstant: 52),

            volumeSlider.trailingAnchor.constraint(equalTo: controlsBar.trailingAnchor, constant: -12),
            volumeSlider.centerYAnchor.constraint(equalTo: controlsBar.centerYAnchor),
            volumeSlider.widthAnchor.constraint(equalToConstant: 70),
            volumeSlider.heightAnchor.constraint(equalToConstant: 20),

            remainingLabel.trailingAnchor.constraint(equalTo: volumeSlider.leadingAnchor, constant: -10),
            remainingLabel.centerYAnchor.constraint(equalTo: controlsBar.centerYAnchor),
            remainingLabel.widthAnchor.constraint(equalToConstant: 58),

            scrubBar.leadingAnchor.constraint(equalTo: elapsedLabel.trailingAnchor, constant: 10),
            scrubBar.trailingAnchor.constraint(equalTo: remainingLabel.leadingAnchor, constant: -10),
            scrubBar.centerYAnchor.constraint(equalTo: controlsBar.centerYAnchor),
            scrubBar.heightAnchor.constraint(equalToConstant: 20),

            rateHUD.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            rateHUD.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    private func makeTimeLabel(_ string: String) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.isBezeled = false
        label.drawsBackground = false
        label.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.85)
            s.shadowBlurRadius = 3
            s.shadowOffset = NSSize(width: 0, height: -1)
            return s
        }()
        return label
    }

    private func makeRateHUD() -> PassthroughLabel {
        let label = PassthroughLabel(labelWithString: "1×")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 42, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.isBezeled = false
        label.drawsBackground = false
        label.alphaValue = 0
        label.isHidden = true
        label.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.85)
            s.shadowBlurRadius = 8
            s.shadowOffset = NSSize(width: 0, height: -1)
            return s
        }()
        return label
    }

    // MARK: - Instant boot (parallel size + playable; reveal as soon as both ready)

    private var pendingAsset: AVURLAsset?
    private var didApplyNativeSize = false
    private var didAttachPlayer = false

    /// Playhead tick rate = clip fps (24 / 29.97 / 30 / 60 …), not display Hz.
    private var playheadHz: Double {
        let fps = Double(videoFrameRate)
        guard fps > 1 else { return 30 }
        return min(120, max(12, fps))
    }

    private func bootPlayerFast() {
        AssetCache.loadFrameRate(videoURL) { [weak self] fps in
            guard let self else { return }
            if let fps, fps > 0 { self.videoFrameRate = fps }
            self.didResolveFrameRate = true
            self.tryAttachAndReveal()
        }

        AssetCache.loadNativeSize(videoURL) { [weak self] size in
            guard let self else { return }
            if let size {
                self.applyNativeWindowSize(size)
                self.didApplyNativeSize = true
            } else if !self.didApplyNativeSize {
                self.didApplyNativeSize = true
            }
            self.tryAttachAndReveal()
        }

        AssetCache.loadPlayable(videoURL) { [weak self] asset, error in
            guard let self else { return }
            if error != nil {
                self.markLoadFailed()
                self.slamOpaqueFront()
                return
            }
            self.pendingAsset = asset
            self.tryAttachAndReveal()
        }

        AssetCache.loadDuration(videoURL) { [weak self] seconds in
            self?.applyDuration(seconds)
        }

        AssetCache.loadContainsHDR(videoURL) { [weak self] hdr in
            self?.playerSurface.setHDR(hdr)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.didAttachPlayer else { return }
            self.didApplyNativeSize = true
            self.didResolveFrameRate = true
            self.tryAttachAndReveal()
        }
    }

    private func tryAttachAndReveal() {
        guard !didAttachPlayer, let asset = pendingAsset, didApplyNativeSize, didResolveFrameRate else { return }
        attachPlayer(with: asset)
    }

    private func markLoadFailed() {
        let name = videoURL.lastPathComponent
        if videoURL.pathExtension.lowercased() == "mkv" {
            window?.title = "Can't play MKV — \(name)"
        } else {
            window?.title = "Failed — \(name)"
        }
    }

    private func applyDuration(_ seconds: Double) {
        durationSeconds = seconds
        scrubBar.maxValue = max(seconds, 0.001)
        updateTimeLabels(current: scrubBar.value)
    }

    /// Size the window to the clip’s native resolution (scaled down only to fit the screen).
    private func applyNativeWindowSize(_ videoSize: CGSize) {
        guard let window else { return }
        videoPixelSize = videoSize
        let screen = window.screen ?? NSScreen.main
        guard let screen else { return }

        let visible = screen.visibleFrame.insetBy(dx: 20, dy: 20)
        let titleBarSlop: CGFloat = 28
        var contentW = videoSize.width
        var contentH = videoSize.height
        let maxW = visible.width
        let maxH = max(200, visible.height - titleBarSlop)
        let scale = min(1.0, min(maxW / contentW, maxH / contentH))
        contentW = max(320, floor(contentW * scale))
        contentH = max(180, floor(contentH * scale))

        // Lock resize to clip aspect — no stretchy-gum distortion or letterbox bars.
        window.contentAspectRatio = NSSize(width: contentW, height: contentH)
        let minContentH = max(180, floor(320 * contentH / contentW))
        let minFrame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 320, height: minContentH))
        window.minSize = minFrame.size

        let contentRect = NSRect(x: 0, y: 0, width: contentW, height: contentH)
        var frame = window.frameRect(forContentRect: contentRect)

        // Prefer saved origin if we have one; otherwise cascade.
        if let saved = WindowFrameStore.loadFrame(for: videoURL) {
            frame.origin.x = saved.origin.x
            frame.origin.y = saved.maxY - frame.height
        } else {
            frame.origin.x = cascadeOrigin.x
            frame.origin.y = cascadeOrigin.y
        }

        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
        if frame.minX < visible.minX { frame.origin.x = visible.minX }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }

        window.animationBehavior = .none
        window.setFrame(frame, display: true, animate: false)
    }

    private func attachPlayer(with asset: AVURLAsset) {
        if queuePlayer != nil || didAttachPlayer { return }
        didAttachPlayer = true

        let templateItem = AVPlayerItem(asset: asset)
        templateItem.preferredForwardBufferDuration = 30
        templateItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        templateItem.seekingWaitsForVideoCompositionRendering = false
        templateItem.automaticallyPreservesTimeOffsetFromLive = false

        let player = AVQueuePlayer()
        player.automaticallyWaitsToMinimizeStalling = false
        // .advance is required for AVPlayerLooper — .none pauses at each loop (gap + thumbnail flash).
        player.actionAtItemEnd = .advance
        player.allowsExternalPlayback = false
        queuePlayer = player
        playerSurface.player = player
        applyVolume(Float(volumeSlider.value))

        playerLooper = AVPlayerLooper(player: player, templateItem: templateItem)

        let interval = CMTime(seconds: 1.0 / playheadHz, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.playerTimeFired(time)
        }

        statusObservation = templateItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            if item.status == .failed {
                DispatchQueue.main.async {
                    self.markLoadFailed()
                }
            }
        }

        player.playImmediately(atRate: currentRate)
        didReveal = true
        slamOpaqueFront()
        scheduleHideControls()
    }

    /// Opaque black window — raise above Finder handoff while this window is key.
    private func slamOpaqueFront() {
        guard let window else { return }
        window.animationBehavior = .none
        window.isOpaque = true
        window.alphaValue = 1
        raiseIfKey()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    private func raiseIfKey() {
        guard let window else { return }
        window.level = window.isKeyWindow ? .floating : .normal
    }

    private func lowerWhenInactive() {
        guard let window else { return }
        window.level = .normal
    }

    // MARK: - Overlay, drop, rate HUD

    private func handleMouseMoved(_ event: NSEvent) {
        showControls()
        guard let content = window?.contentView else { return }
        let p = content.convert(event.locationInWindow, from: nil)
        if p.y <= Self.controlsBarHeight + 8 {
            hideControlsWork?.cancel()
            return
        }
        scheduleHideControls()
    }

    private func showControls() {
        hideControlsWork?.cancel()
        guard let bar = controlsBar else { return }
        bar.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            bar.animator().alphaValue = 1
        }
    }

    private func scheduleHideControls(delay: TimeInterval? = nil) {
        if isScrubbing || scrollScrubActive { return }
        hideControlsWork?.cancel()
        let wait = delay ?? Self.controlsHideDelay
        let work = DispatchWorkItem { [weak self] in
            self?.hideControls()
        }
        hideControlsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func hideControls() {
        if isScrubbing || scrollScrubActive { return }
        guard let bar = controlsBar else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            bar.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isScrubbing, !self.scrollScrubActive else { return }
            if self.controlsBar.alphaValue < 0.05 {
                self.controlsBar.isHidden = true
            }
        })
    }

    private func handleDroppedURLs(_ urls: [URL]) {
        guard let first = urls.first else { return }
        replaceVideo(with: first)
        let rest = Array(urls.dropFirst())
        if !rest.isEmpty {
            (NSApp.delegate as? AppDelegate)?.openVideos(at: rest)
        }
    }

    private func replaceVideo(with url: URL) {
        let newPath = url.standardizedFileURL.path
        guard newPath != videoURL.standardizedFileURL.path else { return }
        saveWindowFrame()
        tearDownPlayback(removeKeyMonitor: false)
        videoURL = url
        window?.title = url.lastPathComponent
        pendingAsset = nil
        didAttachPlayer = false
        didApplyNativeSize = false
        didResolveFrameRate = false
        didReveal = false
        durationSeconds = 0
        displayQuarterTurns = 0
        playerSurface.rotationQuarterTurns = 0
        playerSurface.setHDR(false)
        playerSurface.needsLayout = true
        videoPixelSize = nil
        videoFrameRate = 30
        currentRate = 1.0
        scrubBar.value = 0
        lastKnobPixelX = -1
        updateTimeLabels(current: 0)
        AssetCache.preload(url)
        if let cached = AssetCache.cachedNativeSize(for: url) {
            applyNativeWindowSize(cached)
            didApplyNativeSize = true
        }
        bootPlayerFast()
        slamOpaqueFront()
        showControls()
    }

    private func flashRate() {
        guard rateHUD != nil else { return }
        rateHUD.stringValue = Self.formatRate(currentRate)
        rateHUD.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            rateHUD.animator().alphaValue = 1
        }
        rateHUDHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.28
                self.rateHUD.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.rateHUD.isHidden = true
            })
        }
        rateHUDHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: work)
    }

    private static func formatRate(_ rate: Float) -> String {
        String(format: "%g×", rate)
    }

    // MARK: - Scrub

    /// Scroll/swipe anywhere: up or right = forward, down or left = rewind.
    /// No inertia — finger contact only; play resumes after the seek lands (no playhead bounce).
    private func handleScrollWheel(_ event: NSEvent) {
        // Ignore trackpad momentum / inertia entirely.
        if event.momentumPhase != [] { return }

        let usingX = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
        var delta = usingX ? event.scrollingDeltaX : -event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice {
            delta = -delta
        }
        // Line-based mouse wheels report ±1 per notch; map that onto the trackpad pixel scale.
        if !event.hasPreciseScrollingDeltas {
            delta *= 30
        } else if abs(delta) < 0.4 {
            // Logitech high-res wheels send tiny reverse ticks that bounce the knob.
            delta = 0
        }

        if event.phase == .began || (!scrollScrubActive && delta != 0) {
            if !scrollScrubActive {
                scrollScrubActive = true
                showControls()
                scrubStarted()
            }
        }

        if delta != 0 {
            let duration = max(durationSeconds, scrubBar.maxValue, 0.001)
            let secondsPerUnit = duration * Self.scrollTimelineFraction / Self.scrollFullGestureDelta
            let next = min(duration, max(0, scrubBar.value + delta * secondsPerUnit))
            setScrubBarTime(next, forceRedraw: true)
            scheduleScrollSeek(to: next)
        }

        if event.phase == .ended || event.phase == .cancelled {
            finishScrollScrub()
        } else if scrollScrubActive, event.phase == [] {
            // Clicky / Logitech wheel — no phase events. Wait for the burst to stop.
            scrollEndWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.finishScrollScrub()
            }
            scrollEndWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
        }
    }

    private func scheduleScrollSeek(to seconds: Double) {
        scrollSeekPending = seconds
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastScrollSeekAt
        if elapsed >= Self.scrollSeekInterval {
            flushScrollSeek()
            return
        }
        scrollSeekWork?.cancel()
        let delay = Self.scrollSeekInterval - elapsed
        let work = DispatchWorkItem { [weak self] in
            self?.flushScrollSeek()
        }
        scrollSeekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func flushScrollSeek() {
        guard scrollScrubActive, let target = scrollSeekPending else { return }
        scrollSeekPending = nil
        lastScrollSeekAt = CFAbsoluteTimeGetCurrent()
        seek(to: target, precise: false)
    }

    private func finishScrollScrub() {
        scrollEndWork?.cancel()
        scrollEndWork = nil
        scrollSeekWork?.cancel()
        scrollSeekWork = nil
        guard scrollScrubActive else { return }
        scrollScrubActive = false

        let target = scrollSeekPending ?? scrubBar.value
        scrollSeekPending = nil
        setScrubBarTime(target, forceRedraw: true)

        // Stay in scrub until the seek lands — playing from the old time is what bounced the knob.
        seek(to: target, precise: true) { [weak self] in
            guard let self else { return }
            self.isScrubbing = false
            self.queuePlayer?.playImmediately(atRate: self.currentRate)
            self.scheduleHideControls()
        }
    }

    private func scrubStarted() {
        isScrubbing = true
        lastCoarseSeekAt = 0
        showControls()
    }

    private func scrubValueChanged(_ seconds: Double) {
        guard isScrubbing, !scrollScrubActive else { return }
        updateTimeLabels(current: seconds)

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastCoarseSeekAt >= Self.dragSeekInterval else { return }
        lastCoarseSeekAt = now
        seek(to: seconds, precise: false)
    }

    private func scrubEnded() {
        let seconds = scrubBar.value
        seek(to: seconds, precise: true) { [weak self] in
            guard let self else { return }
            self.isScrubbing = false
            let actual = self.queuePlayer?.currentTime().seconds ?? seconds
            if actual.isFinite {
                self.setScrubBarTime(actual)
            }
        }
        updateTimeLabels(current: seconds)
        scheduleHideControls()
    }

    private func setScrubBarTime(_ seconds: Double, forceRedraw: Bool = false) {
        let clamped = min(max(seconds, 0), scrubBar.maxValue)
        scrubBar.value = clamped
        let newKnobX = scrubBar.knobPixelX
        if forceRedraw || abs(newKnobX - lastKnobPixelX) >= 1 {
            lastKnobPixelX = newKnobX
            scrubBar.needsDisplay = true
        }
        updateTimeLabels(current: clamped)
    }

    private func seek(to seconds: Double, precise: Bool, completion: (() -> Void)? = nil) {
        guard let player = queuePlayer else {
            completion?()
            return
        }
        let wasPlaying = player.rate != 0
        seekSerial += 1
        let serial = seekSerial
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)

        if precise {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard let self else {
                    completion?()
                    return
                }
                if finished, self.seekSerial == serial, wasPlaying, player.rate == 0 {
                    player.rate = self.currentRate
                }
                completion?()
            }
        } else {
            player.seek(
                to: time,
                toleranceBefore: .positiveInfinity,
                toleranceAfter: .positiveInfinity
            )
            // Only kick rate back if the seek stalled playback — don't re-hit rate every coarse seek.
            if wasPlaying, player.rate == 0 {
                player.rate = currentRate
            }
            completion?()
        }
    }

    private func playerTimeFired(_ time: CMTime) {
        guard !isScrubbing, !scrollScrubActive else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        // Looper resets item time at wrap.
        if durationSeconds > 0, seconds + 0.25 < scrubBar.value {
            setScrubBarTime(seconds)
        } else {
            setScrubBarTime(min(seconds, scrubBar.maxValue))
        }
    }

    private func updateTimeLabels(current: Double) {
        elapsedLabel.stringValue = Self.formatTime(current)
        let remaining = max(durationSeconds - current, 0)
        remainingLabel.stringValue = durationSeconds > 0 ? "-\(Self.formatTime(remaining))" : "--:--"
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Keyboard

    /// Looper playback shortcuts — inactive until a player is attached (no effect when Looper has no video playing).
    private func isLooperPlaybackShortcut(_ event: NSEvent) -> Bool {
        switch event.charactersIgnoringModifiers {
        case "1", "l", "m", " ":
            return true
        default:
            break
        }
        return event.keyCode == 36 || event.keyCode == 76
    }

    private var hasActivePlayback: Bool {
        queuePlayer != nil
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if isLooperPlaybackShortcut(event), !hasActivePlayback {
            return false
        }

        switch event.charactersIgnoringModifiers {
        case "]":
            adjustSpeed(by: 0.25)
            return true
        case "[":
            adjustSpeed(by: -0.25)
            return true
        case "0":
            resetSpeed()
            return true
        case "1":
            toggleHalfSpeed()
            return true
        case "l":
            rotateCounterClockwise()
            return true
        case " ":
            togglePlayPause()
            return true
        case "m":
            toggleMute()
            return true
        default:
            break
        }

        let step: Double = event.modifierFlags.contains(.shift) ? 5 : 1
        switch event.keyCode {
        case 36, 76: // Return / keypad Enter — close this window only (must be key)
            window?.close()
            return true
        case 123:
            nudge(by: -step)
            return true
        case 124:
            nudge(by: step)
            return true
        default:
            return false
        }
    }

    private func togglePlayPause() {
        guard let player = queuePlayer else { return }
        if player.rate == 0 {
            player.rate = currentRate
        } else {
            player.rate = 0
        }
    }

    private func applyVolume(_ volume: Float) {
        guard let player = queuePlayer else { return }
        if volume > 0.0001 {
            preMuteVolume = volume
        }
        player.volume = volume
    }

    private func toggleMute() {
        guard let player = queuePlayer else { return }
        // Volume-only mute — never touches rate; avoids isMuted audio-pipeline hitches.
        if player.volume < 0.0001 {
            let restored = preMuteVolume > 0.0001 ? preMuteVolume : 1.0
            applyVolume(restored)
        } else {
            preMuteVolume = max(player.volume, 0.0001)
            applyVolume(0)
        }
        volumeSlider.value = Double(player.volume)
        volumeSlider.needsDisplay = true
    }

    private func nudge(by delta: Double) {
        guard let player = queuePlayer else { return }
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let upper = durationSeconds > 0 ? durationSeconds : current + abs(delta)
        let target = min(max(current + delta, 0), upper)
        isScrubbing = true
        showControls()
        seek(to: target, precise: true) { [weak self] in
            guard let self else { return }
            self.isScrubbing = false
            self.scrubBar.value = target
            self.scrubBar.needsDisplay = true
            self.updateTimeLabels(current: target)
            self.scheduleHideControls()
        }
    }

    private func adjustSpeed(by delta: Float) {
        // M5 can decode high rates cleanly — allow up to 8×.
        let newRate = max(0.25, min(8.0, currentRate + delta))
        currentRate = newRate
        if let player = queuePlayer, player.rate != 0 {
            player.rate = currentRate
        }
        flashRate()
    }

    private func resetSpeed() {
        currentRate = 1.0
        if let player = queuePlayer, player.rate != 0 {
            player.rate = currentRate
        }
        flashRate()
    }

    /// 1 — toggle 50% / 100% speed.
    private func toggleHalfSpeed() {
        if abs(currentRate - 0.5) < 0.001 {
            currentRate = 1.0
        } else {
            currentRate = 0.5
        }
        if let player = queuePlayer, player.rate != 0 {
            player.rate = currentRate
        }
        flashRate()
    }

    /// L — rotate counter-clockwise (display only, file unchanged).
    private func rotateCounterClockwise() {
        displayQuarterTurns = (displayQuarterTurns + 1) % 4
        applyDisplayRotation()
    }

    private func applyDisplayRotation() {
        playerSurface.rotationQuarterTurns = displayQuarterTurns
        playerSurface.needsLayout = true
        playerSurface.layoutSubtreeIfNeeded()
        updateWindowAspectForRotation()
    }

    private func updateWindowAspectForRotation() {
        guard let window, let pixelSize = videoPixelSize else { return }
        let swapped = displayQuarterTurns % 2 == 1
        let natW = swapped ? pixelSize.height : pixelSize.width
        let natH = swapped ? pixelSize.width : pixelSize.height

        let screen = window.screen ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame.insetBy(dx: 20, dy: 20)
        let titleBarSlop: CGFloat = 28
        var contentW = natW
        var contentH = natH
        let maxW = visible.width
        let maxH = max(200, visible.height - titleBarSlop)
        let scale = min(1.0, min(maxW / contentW, maxH / contentH))
        contentW = max(320, floor(contentW * scale))
        contentH = max(180, floor(contentH * scale))

        window.contentAspectRatio = NSSize(width: contentW, height: contentH)
        let minContentH = max(180, floor(320 * contentH / contentW))
        let minFrame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 320, height: minContentH))
        window.minSize = minFrame.size

        let contentRect = NSRect(x: 0, y: 0, width: contentW, height: contentH)
        var frame = window.frameRect(forContentRect: contentRect)
        let old = window.frame
        frame.origin.x = old.midX - frame.width / 2
        frame.origin.y = old.midY - frame.height / 2
        window.animationBehavior = .none
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: - NSWindowDelegate (never Dock)

    func windowDidBecomeKey(_ notification: Notification) {
        raiseIfKey()
        window?.orderFrontRegardless()
        showControls()
        scheduleHideControls()
    }

    func windowDidResignKey(_ notification: Notification) {
        lowerWhenInactive()
    }

    func windowShouldMiniaturize(_ sender: NSWindow) -> Bool {
        false
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowWillClose(_ notification: Notification) {
        saveWindowFrame()
        tearDownPlayback()
        window?.orderOut(nil)

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.windowWillClose(self)
        }
    }

    private func tearDownPlayback(removeKeyMonitor: Bool = true) {
        statusObservation?.invalidate()
        statusObservation = nil
        if let timeObserver, let queuePlayer {
            queuePlayer.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        scrollSeekWork?.cancel()
        scrollSeekWork = nil
        scrollSeekPending = nil
        hideControlsWork?.cancel()
        hideControlsWork = nil
        rateHUDHideWork?.cancel()
        rateHUDHideWork = nil
        if removeKeyMonitor, let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        playerLooper?.disableLooping()
        playerLooper = nil
        queuePlayer?.pause()
        queuePlayer?.replaceCurrentItem(with: nil)
        playerSurface.player = nil
        queuePlayer = nil
    }

    private func saveWindowFrame() {
        guard let window = window else { return }
        WindowFrameStore.saveFrame(window.frame, for: videoURL)
    }
}
