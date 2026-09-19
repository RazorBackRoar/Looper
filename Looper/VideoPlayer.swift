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

@available(macOS 26.0, *)
private final class PassthroughGlassView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private func drawHighContrastTrack(in track: NSRect, fraction: CGFloat) {
    let groove = NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2)
    NSColor.black.withAlphaComponent(0.78).setFill()
    groove.fill()
    NSColor.white.setStroke()
    groove.lineWidth = 1.25
    groove.stroke()

    let clamped = min(1, max(0, fraction))
    if clamped > 0 {
        var progress = track
        progress.size.width = max(track.height, track.width * CGFloat(clamped))
        NSColor.white.setFill()
        NSBezierPath(roundedRect: progress, xRadius: 2, yRadius: 2).fill()
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
    var loopInValue: Double?
    var loopOutValue: Double?
    var onScrubStart: (() -> Void)?
    var onScrubEnd: (() -> Void)?
    var onValueChanged: ((Double) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var onDoubleClick: ((Double) -> Void)?

    private var dragging = false

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: dragging ? .closedHand : .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 12
        let trackW = max(bounds.width - inset * 2, 1)
        let trackY = bounds.midY
        let fraction = maxValue > 0 ? min(1, max(0, value / maxValue)) : 0
        let knobX = round(inset + trackW * fraction)

        let trackH: CGFloat = 4
        drawHighContrastTrack(
            in: NSRect(x: inset, y: trackY - trackH / 2, width: trackW, height: trackH),
            fraction: CGFloat(fraction)
        )

        let diameter: CGFloat = 10
        let knobRect = NSRect(x: knobX - diameter / 2, y: trackY - diameter / 2, width: diameter, height: diameter)
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(ovalIn: knobRect.insetBy(dx: -0.5, dy: -0.5)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()

        if maxValue > 0, loopInValue != nil {
            let inX = inset + trackW * CGFloat(min(1, max(0, loopInValue! / maxValue)))
            if let outValue = loopOutValue {
                let outX = inset + trackW * CGFloat(min(1, max(0, outValue / maxValue)))
                let rangeRect = NSRect(x: inX, y: trackY - trackH, width: outX - inX, height: trackH * 2)
                NSColor.systemGreen.withAlphaComponent(0.35).setFill()
                NSBezierPath(roundedRect: rangeRect, xRadius: 4, yRadius: 4).fill()
                drawLoopMarker(at: outX, trackY: trackY)
            }
            drawLoopMarker(at: inX, trackY: trackY)
        }
    }

    private func drawLoopMarker(at x: CGFloat, trackY: CGFloat) {
        let marker = NSRect(x: x - 2, y: trackY - 5, width: 4, height: 10)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: marker.insetBy(dx: -0.5, dy: -0.5), xRadius: 2, yRadius: 2).fill()
        NSColor.systemGreen.setFill()
        NSBezierPath(roundedRect: marker, xRadius: 2, yRadius: 2).fill()
    }

    /// Pixel X of the knob center — used to skip redundant redraws during playback.
    var knobPixelX: CGFloat {
        let inset: CGFloat = 12
        let trackW = max(bounds.width - inset * 2, 1)
        let fraction = maxValue > 0 ? min(1, max(0, value / maxValue)) : 0
        return round(inset + trackW * fraction)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let x = convert(event.locationInWindow, from: nil).x
            let inset: CGFloat = 12
            let trackW = max(bounds.width - inset * 2, 1)
            let fraction = min(1, max(0, (x - inset) / trackW))
            onDoubleClick?(Double(fraction) * maxValue)
            return
        }
        dragging = true
        window?.invalidateCursorRects(for: self)
        onScrubStart?()
        scrubTo(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        scrubTo(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        window?.invalidateCursorRects(for: self)
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 6
        let iconW: CGFloat = 12
        let iconGap: CGFloat = 6
        let trackInsetLeft = inset + iconW + iconGap
        let trackW = max(bounds.width - trackInsetLeft - inset, 1)
        let trackY = bounds.midY
        let trackH: CGFloat = 4
        let fraction = min(1, max(0, value))

        drawSpeaker(in: NSRect(x: inset, y: trackY - iconW / 2, width: iconW, height: iconW))

        drawHighContrastTrack(
            in: NSRect(x: trackInsetLeft, y: trackY - trackH / 2, width: trackW, height: trackH),
            fraction: CGFloat(fraction)
        )

        let knobX = round(trackInsetLeft + trackW * fraction)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: NSRect(x: knobX - 5, y: trackY - 5, width: 10, height: 10)).fill()
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

// MARK: - Slo-Mo pill button

/// Tap = toggle half speed. Glass on macOS 26+, drawn pill before that.
private final class SlomoButton: NSView {
    var onActivate: (() -> Void)?

    private var usesGlass = false
    private let titleLabel = PassthroughLabel(labelWithString: "Slo-Mo")

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        if #available(macOS 26.0, *) {
            let glass = PassthroughGlassView()
            glass.style = .regular
            glass.cornerRadius = 11
            glass.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glass, positioned: .below, relativeTo: nil)
            usesGlass = true
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !usesGlass else { return }
        let pill = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
        NSColor.black.withAlphaComponent(0.45).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - Scroll catcher over the full picture (focus only — no click-to-pause)

private final class VideoScrollView: NSView {
    var onScroll: ((NSEvent) -> Void)?
    var onDoubleClick: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Root content view: file drops bubble here.
private final class FileDropView: NSView {
    var onDropURLs: (([URL]) -> Void)?

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
        return urls.filter {
            LocalVideoURL.isPlayableFile($0) && videoExtensions.contains($0.pathExtension.lowercased())
        }
    }
}

private final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Player window

/// Maxed local player: instant open, aggressive scrub, gapless loop. Never minimizes to Dock.
final class VideoPlayerWindowController: NSWindowController, NSWindowDelegate, MediaKeyHandling {
    private(set) var videoURL: URL
    private let cascadeOrigin: NSPoint
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var templateItem: AVPlayerItem?
    private var playerSurface: PlayerLayerView!
    private var clickView: VideoScrollView!
    private var scrubBar: VideoScrubBar!
    private var elapsedLabel: NSTextField!
    private var remainingLabel: NSTextField!
    private var volumeSlider: VolumeSlider!
    private var slomoButton: SlomoButton!
    private var controlsBar: NSView!
    private var rateHUD: PassthroughLabel!
    private var currentRate: Float = 1.0
    private var durationSeconds: Double = 0
    private var isScrubbing = false
    private var keyMonitor: Any?
    private var statusObservation: NSKeyValueObservation?
    private var lastCoarseSeekAt: CFAbsoluteTime = 0
    private var seekSerial = 0
    private var loopApplySerial = 0
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
    private var rateHUDHideWork: DispatchWorkItem?
    private static let controlsBarHeight: CGFloat = 34
    /// AVPlayer cannot usefully absorb >30 seeks/s — 120Hz seeks are what made the picture jump.
    private static let maxSeekHz: Double = 30
    private var playheadLink: CADisplayLink?
    private var pendingPlayheadSeconds: Double?
    private var pendingPlayheadSince: CFAbsoluteTime = 0
    private var mediaHoldScrubActive = false
    private var mediaHoldScrubForward = false
    private var holdScrubStartedAt: CFAbsoluteTime = 0
    private var lastHoldTickAt: CFAbsoluteTime = 0
    private var seekInFlight = false
    private var queuedSeekSeconds: Double?
    private var queuedSeekPrecise = false
    private var queuedSeekCompletion: (@MainActor @Sendable () -> Void)?
    private var pausedForWheelScrub = false
    private var lastScrollDeltaSign: Double = 0
    private var mouseScrollRemainder: Double = 0
    private var arrowHoldKeys = Set<UInt16>()

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
        window.isExcludedFromWindowsMenu = false
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

    isolated deinit {
        tearDownPlayback()
    }

    // MARK: - UI

    private func setupUI() {
        guard let window else { return }
        let dropView = FileDropView(frame: window.contentView?.bounds ?? .zero)
        dropView.autoresizingMask = [.width, .height]
        dropView.onDropURLs = { [weak self] urls in self?.handleDroppedURLs(urls) }
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
        clickView.onDoubleClick = { [weak self] in self?.loopPointAtCurrentTime() }
        content.addSubview(clickView)

        // Permanent dark-gray strip under the video — no overlay, no auto-hide.
        controlsBar = NSView(frame: .zero)
        controlsBar.wantsLayer = true
        controlsBar.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        controlsBar.translatesAutoresizingMaskIntoConstraints = false
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
        scrubBar.onDoubleClick = { [weak self] seconds in self?.handleLoopPointInput(at: seconds) }

        volumeSlider = VolumeSlider(frame: .zero)
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.value = 1.0
        volumeSlider.onValueChanged = { [weak self] volume in
            self?.applyVolume(Float(volume))
        }

        slomoButton = SlomoButton(frame: .zero)
        slomoButton.translatesAutoresizingMaskIntoConstraints = false
        slomoButton.onActivate = { [weak self] in self?.toggleSlomo() }

        controlsBar.addSubview(elapsedLabel)
        controlsBar.addSubview(scrubBar)
        controlsBar.addSubview(remainingLabel)
        controlsBar.addSubview(volumeSlider)
        controlsBar.addSubview(slomoButton)

        rateHUD = makeRateHUD()
        content.addSubview(rateHUD)

        NSLayoutConstraint.activate([
            playerSurface.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerSurface.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerSurface.topAnchor.constraint(equalTo: content.topAnchor),
            playerSurface.bottomAnchor.constraint(equalTo: controlsBar.topAnchor),

            clickView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            clickView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            clickView.topAnchor.constraint(equalTo: content.topAnchor),
            clickView.bottomAnchor.constraint(equalTo: controlsBar.topAnchor),

            controlsBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            controlsBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            controlsBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            controlsBar.heightAnchor.constraint(equalToConstant: barHeight),

            scrubBar.leadingAnchor.constraint(equalTo: elapsedLabel.trailingAnchor, constant: 10),
            scrubBar.trailingAnchor.constraint(equalTo: remainingLabel.leadingAnchor, constant: -10),
            scrubBar.centerYAnchor.constraint(equalTo: controlsBar.centerYAnchor),
            scrubBar.heightAnchor.constraint(equalToConstant: 16),

            elapsedLabel.leadingAnchor.constraint(equalTo: controlsBar.leadingAnchor, constant: 12),
            elapsedLabel.centerYAnchor.constraint(equalTo: scrubBar.centerYAnchor),
            elapsedLabel.widthAnchor.constraint(equalToConstant: 52),

            volumeSlider.trailingAnchor.constraint(equalTo: slomoButton.leadingAnchor, constant: -10),
            volumeSlider.centerYAnchor.constraint(equalTo: scrubBar.centerYAnchor),
            volumeSlider.widthAnchor.constraint(equalToConstant: 70),
            volumeSlider.heightAnchor.constraint(equalToConstant: 20),

            slomoButton.trailingAnchor.constraint(equalTo: controlsBar.trailingAnchor, constant: -12),
            slomoButton.centerYAnchor.constraint(equalTo: scrubBar.centerYAnchor),
            slomoButton.widthAnchor.constraint(equalToConstant: 68),
            slomoButton.heightAnchor.constraint(equalToConstant: 22),

            remainingLabel.trailingAnchor.constraint(equalTo: volumeSlider.leadingAnchor, constant: -10),
            remainingLabel.centerYAnchor.constraint(equalTo: scrubBar.centerYAnchor),
            remainingLabel.widthAnchor.constraint(equalToConstant: 58),

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

    /// Monitor refresh (ProMotion 120, external 60, …). Video stays at native fps; frames are held to match Hz.
    private var displayRefreshHz: Double {
        let hz = window?.screen?.maximumFramesPerSecond
            ?? NSScreen.main?.maximumFramesPerSecond
            ?? 60
        return max(30, Double(hz))
    }

    private var frameDuration: Double {
        let fps = Double(videoFrameRate)
        return fps > 1 ? 1.0 / fps : 1.0 / 30.0
    }

    /// Live scrub seeks at most 30/s so AVPlayer doesn't queue jumps.
    private var liveSeekInterval: Double {
        1.0 / Self.maxSeekHz
    }

    private func bootPlayerFast() {
        let targetURL = videoURL
        AssetCache.loadFrameRate(videoURL) { [weak self] fps in
            guard let self, self.videoURL == targetURL else { return }
            if let fps, fps > 0 {
                self.videoFrameRate = fps
                self.applyFrameTiming()
            }
            self.didResolveFrameRate = true
            self.tryAttachAndReveal()
        }

        AssetCache.loadNativeSize(videoURL) { [weak self] size in
            guard let self, self.videoURL == targetURL else { return }
            if let size {
                self.applyNativeWindowSize(size)
                self.didApplyNativeSize = true
            } else if !self.didApplyNativeSize {
                self.didApplyNativeSize = true
            }
            self.tryAttachAndReveal()
        }

        AssetCache.loadPlayable(videoURL) { [weak self] asset, error in
            guard let self, self.videoURL == targetURL else { return }
            if error != nil {
                self.markLoadFailed()
                self.slamOpaqueFront()
                return
            }
            self.pendingAsset = asset
            self.tryAttachAndReveal()
        }

        AssetCache.loadDuration(videoURL) { [weak self] seconds in
            guard let self, self.videoURL == targetURL else { return }
            self.applyDuration(seconds)
        }

        AssetCache.loadContainsHDR(videoURL) { [weak self] hdr in
            guard let self, self.videoURL == targetURL else { return }
            self.playerSurface.setHDR(hdr)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.videoURL == targetURL, !self.didAttachPlayer else { return }
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

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 30
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        item.seekingWaitsForVideoCompositionRendering = false
        item.automaticallyPreservesTimeOffsetFromLive = false
        templateItem = item

        let player = AVQueuePlayer()
        player.automaticallyWaitsToMinimizeStalling = false
        // .advance is required for AVPlayerLooper — .none pauses at each loop (gap + thumbnail flash).
        player.actionAtItemEnd = .advance
        player.allowsExternalPlayback = false
        queuePlayer = player
        playerSurface.player = player
        applyVolume(Float(volumeSlider.value))

        playerLooper = AVPlayerLooper(player: player, templateItem: item)
        // A fresh looper means full-clip looping — drop any stale markers set before attach.
        scrubBar.loopInValue = nil
        scrubBar.loopOutValue = nil

        applyFrameTiming()
        startPlayheadLink()

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
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
        MediaKeys.shared.refreshNowPlaying()
    }

    // MARK: - Custom loop range (double-click)

    private func applyCustomLoop(inSeconds: Double, outSeconds: Double) {
        loopApplySerial += 1
        let serial = loopApplySerial
        playerLooper?.disableLooping()
        playerLooper = nil
        let wasPlaying = queuePlayer?.rate != 0
        seek(to: inSeconds, precise: true) { [weak self] in
            guard let self, self.loopApplySerial == serial,
                  let player = self.queuePlayer, let templateItem = self.templateItem
            else { return }
            let range = CMTimeRange(
                start: CMTime(seconds: inSeconds, preferredTimescale: 600),
                end: CMTime(seconds: outSeconds, preferredTimescale: 600))
            self.playerLooper = AVPlayerLooper(player: player, templateItem: templateItem, timeRange: range)
            // The in-flight item predates the new looper — cap its end so the out-point applies now.
            player.currentItem?.forwardPlaybackEndTime = range.end
            if wasPlaying, player.rate == 0 { player.rate = self.currentRate }
        }
    }

    private func clearCustomLoop() {
        loopApplySerial += 1
        playerLooper?.disableLooping()
        playerLooper = nil
        guard let player = queuePlayer, let templateItem else { return }
        // Release any range cap on the in-flight item so it plays to the clip end.
        player.currentItem?.forwardPlaybackEndTime = .invalid
        playerLooper = AVPlayerLooper(player: player, templateItem: templateItem)
    }

    /// Dragging the playhead outside an active loop range breaks the loop.
    private func clearCustomLoopIfOutside(_ seconds: Double) {
        guard let lo = scrubBar.loopInValue, let hi = scrubBar.loopOutValue,
              seconds < lo || seconds > hi else { return }
        scrubBar.loopInValue = nil
        scrubBar.loopOutValue = nil
        scrubBar.needsDisplay = true
        clearCustomLoop()
    }

    /// Double-click on the video marks a loop point at the current playhead position.
    private func loopPointAtCurrentTime() {
        let seconds = queuePlayer?.currentTime().seconds ?? scrubBar.value
        guard seconds.isFinite else { return }
        handleLoopPointInput(at: seconds)
    }

    /// One state machine for both surfaces: pending point → complete pair → clear.
    private func handleLoopPointInput(at seconds: Double) {
        if scrubBar.loopInValue != nil, scrubBar.loopOutValue != nil {
            // Complete pair — clear it; the next double-click starts a fresh loop.
            scrubBar.loopInValue = nil
            scrubBar.loopOutValue = nil
            scrubBar.needsDisplay = true
            clearCustomLoop()
            return
        }
        if let inValue = scrubBar.loopInValue {
            let lo = min(inValue, seconds)
            let hi = max(inValue, seconds)
            // Below this span the looper would churn items faster than a frame.
            guard hi - lo >= 0.1 else { return }
            scrubBar.loopInValue = lo
            scrubBar.loopOutValue = hi
            scrubBar.needsDisplay = true
            applyCustomLoop(inSeconds: lo, outSeconds: hi)
            return
        }
        scrubBar.loopInValue = seconds
        scrubBar.needsDisplay = true
    }

    private func applyFrameTiming() {
        let hz = Float(displayRefreshHz)
        playheadLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: hz, preferred: hz)
    }

    private func startPlayheadLink() {
        stopPlayheadLink()
        guard let window else { return }
        let link = window.displayLink(target: self, selector: #selector(playheadTick(_:)))
        let hz = Float(displayRefreshHz)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: hz, preferred: hz)
        link.add(to: .main, forMode: .common)
        playheadLink = link
        applyFrameTiming()
    }

    private func stopPlayheadLink() {
        playheadLink?.invalidate()
        playheadLink = nil
    }

    @objc private func playheadTick(_ link: CADisplayLink) {
        if mediaHoldScrubActive {
            holdScrubTick()
            return
        }
        guard let player = queuePlayer else { return }
        playerTimeFired(player.currentTime())
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
        NSApp.activate(ignoringOtherApps: true)
    }

    private func raiseIfKey() {
        guard let window else { return }
        window.level = window.isKeyWindow ? .floating : .normal
    }

    private func lowerWhenInactive() {
        guard let window else { return }
        window.level = .normal
    }

    // MARK: - Drop, rate HUD

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
        scrubBar.loopInValue = nil
        scrubBar.loopOutValue = nil
        scrubBar.needsDisplay = true
        updateSlomoLabel()
        lastKnobPixelX = -1
        updateTimeLabels(current: 0)
        AssetCache.preload(url)
        if let cached = AssetCache.cachedNativeSize(for: url) {
            applyNativeWindowSize(cached)
            didApplyNativeSize = true
        }
        bootPlayerFast()
        slamOpaqueFront()
    }

    private func flashRate() {
        guard rateHUD != nil else { return }
        rateHUD.stringValue = PlaybackFormatting.formatRate(currentRate)
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
                MainActor.assumeIsolated {
                    self?.rateHUD.isHidden = true
                }
            })
        }
        rateHUDHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: work)
        updateSlomoLabel()
    }

    // MARK: - Scrub

    /// Scroll/swipe anywhere: up or right = forward, down or left = rewind.
    /// Mouse (including Magic Mouse) never scales by clip length.
    private func handleScrollWheel(_ event: NSEvent) {
        if event.momentumPhase != [] { return }
        if mediaHoldScrubActive { return }

        let usingX = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
        var delta = usingX ? event.scrollingDeltaX : -event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice {
            delta = -delta
        }

        // Empty phase = mouse. Trackpad always has began/changed/ended.
        let isMouse = event.phase == []
        var mediaDelta = 0.0

        if isMouse {
            if lastScrollDeltaSign != 0, delta * lastScrollDeltaSign < 0, abs(delta) < 3 {
                delta = 0
            }
            if event.hasPreciseScrollingDeltas {
                mediaDelta = PlaybackScrubMath.consumeMousePixels(delta, remainder: &mouseScrollRemainder)
            } else if delta != 0 {
                mouseScrollRemainder = 0
                mediaDelta = (delta > 0 ? 1 : -1) * PlaybackScrubMath.mouseNotchStep()
            }
        } else {
            mouseScrollRemainder = 0
            if event.hasPreciseScrollingDeltas, abs(delta) < 0.4 {
                delta = 0
            }
            if delta != 0 {
                let duration = max(durationSeconds, scrubBar.maxValue, 0.001)
                let sign: Double = delta > 0 ? 1 : -1
                mediaDelta = sign * PlaybackScrubMath.trackpadStep(delta: abs(delta), duration: duration)
            }
        }

        if event.phase == .began || (!scrollScrubActive && mediaDelta != 0) {
            if !scrollScrubActive {
                scrollScrubActive = true
                scrubStarted()
                if isMouse {
                    pauseForWheelScrubIfNeeded()
                }
            }
        }

        if mediaDelta != 0 {
            lastScrollDeltaSign = mediaDelta > 0 ? 1 : -1
            let duration = max(durationSeconds, scrubBar.maxValue, 0.001)
            let next = min(duration, max(0, scrubBar.value + mediaDelta))
            setScrubBarTime(next, forceRedraw: true)
            scheduleScrollSeek(to: next)
        }

        if event.phase == .ended || event.phase == .cancelled {
            mouseScrollRemainder = 0
            finishScrollScrub()
        } else if scrollScrubActive, isMouse {
            scrollEndWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.mouseScrollRemainder = 0
                self?.finishScrollScrub()
            }
            scrollEndWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
    }

    private func pauseForWheelScrubIfNeeded() {
        guard let player = queuePlayer, player.rate != 0 else { return }
        pausedForWheelScrub = true
        player.rate = 0
    }

    private func scheduleScrollSeek(to seconds: Double) {
        scrollSeekPending = seconds
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastScrollSeekAt
        if elapsed >= liveSeekInterval {
            flushScrollSeek()
            return
        }
        scrollSeekWork?.cancel()
        let delay = liveSeekInterval - elapsed
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
        lastScrollDeltaSign = 0
        mouseScrollRemainder = 0
        guard scrollScrubActive else { return }
        scrollScrubActive = false
        if mediaHoldScrubActive { return }

        let target = scrollSeekPending ?? scrubBar.value
        scrollSeekPending = nil
        setScrubBarTime(target, forceRedraw: true)

        seek(to: target, precise: true) { [weak self] in
            guard let self else { return }
            if self.mediaHoldScrubActive { return }
            self.isScrubbing = false
            if self.pausedForWheelScrub {
                self.pausedForWheelScrub = false
                self.queuePlayer?.playImmediately(atRate: self.currentRate)
            }
        }
    }

    private func scrubStarted() {
        isScrubbing = true
        lastCoarseSeekAt = 0
    }

    private func scrubValueChanged(_ seconds: Double) {
        guard isScrubbing, !scrollScrubActive else { return }
        clearCustomLoopIfOutside(seconds)
        updateTimeLabels(current: seconds)

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastCoarseSeekAt >= liveSeekInterval else { return }
        lastCoarseSeekAt = now
        seek(to: seconds, precise: false)
    }

    private func scrubEnded() {
        let seconds = scrubBar.value
        clearCustomLoopIfOutside(seconds)
        seek(to: seconds, precise: true) { [weak self] in
            guard let self else { return }
            self.isScrubbing = false
            if let player = self.queuePlayer, player.rate == 0 {
                player.playImmediately(atRate: self.currentRate)
            }
        }
        updateTimeLabels(current: seconds)
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

    private func seek(to seconds: Double, precise: Bool, completion: (@MainActor @Sendable () -> Void)? = nil) {
        let clamped = max(0, seconds)
        pendingPlayheadSeconds = clamped
        pendingPlayheadSince = CFAbsoluteTimeGetCurrent()

        if seekInFlight {
            queuedSeekSeconds = clamped
            queuedSeekPrecise = queuedSeekPrecise || precise
            if let completion {
                let previous = queuedSeekCompletion
                queuedSeekCompletion = {
                    previous?()
                    completion()
                }
            }
            return
        }
        performSeek(clamped, precise: precise, completion: completion)
    }

    private func performSeek(_ seconds: Double, precise: Bool, completion: (@MainActor @Sendable () -> Void)?) {
        guard let player = queuePlayer else {
            completion?()
            return
        }
        seekInFlight = true
        seekSerial += 1
        let serial = seekSerial
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        // Live scrub uses a small window so we don't stack keyframe hops; end-of-gesture is exact.
        let slop = precise ? CMTime.zero : CMTime(seconds: max(frameDuration * 2, 0.05), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: slop, toleranceAfter: slop) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion?()
                    return
                }
                self.seekInFlight = false
                if let queued = self.queuedSeekSeconds {
                    self.queuedSeekSeconds = nil
                    let qPrecise = self.queuedSeekPrecise
                    let qCompletion = self.queuedSeekCompletion
                    self.queuedSeekPrecise = false
                    self.queuedSeekCompletion = nil
                    self.performSeek(queued, precise: qPrecise) {
                        completion?()
                        qCompletion?()
                    }
                    return
                }
                if finished, self.seekSerial == serial,
                   let queuePlayer = self.queuePlayer, queuePlayer.rate == 0,
                   !self.pausedForWheelScrub,
                   !self.scrollScrubActive,
                   !self.mediaHoldScrubActive {
                    queuePlayer.rate = self.currentRate
                }
                completion?()
            }
        }
    }

    private func playerTimeFired(_ time: CMTime) {
        guard !isScrubbing, !scrollScrubActive, !mediaHoldScrubActive else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }

        let slop = frameDuration * 2
        if let pending = pendingPlayheadSeconds {
            let waited = CFAbsoluteTimeGetCurrent() - pendingPlayheadSince
            let caughtUp = abs(seconds - pending) <= slop
            let looped = durationSeconds > 1 && seconds < slop && pending > durationSeconds - 0.5
            if caughtUp || looped || waited > 0.22 {
                pendingPlayheadSeconds = nil
            } else {
                return
            }
        }

        let playing = (queuePlayer?.rate ?? 0) != 0
        if playing, seconds + slop < scrubBar.value {
            let wrapped = durationSeconds > 1 && seconds < 0.5 && scrubBar.value > durationSeconds * 0.7
            if wrapped {
                setScrubBarTime(seconds)
            }
            return
        }
        setScrubBarTime(min(seconds, scrubBar.maxValue))
    }

    private func updateTimeLabels(current: Double) {
        elapsedLabel.stringValue = PlaybackFormatting.formatTime(current)
        let remaining = max(durationSeconds - current, 0)
        remainingLabel.stringValue = durationSeconds > 0 ? "-\(PlaybackFormatting.formatTime(remaining))" : "--:--"
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let commandHeld = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        if event.type == .keyDown, commandHeld, event.charactersIgnoringModifiers?.lowercased() == "q" {
            NSApp.terminate(nil)
            return true
        }

        // F7 / F9 as standard function keys (not HID media keys) — hold to scrub.
        switch event.keyCode {
        case 98: // F7 rewind
            if event.type == .keyDown { startHoldScrub(forward: false) }
            else { stopHoldScrub() }
            return true
        case 101: // F9 fast-forward
            if event.type == .keyDown { startHoldScrub(forward: true) }
            else { stopHoldScrub() }
            return true
        case 100: // F8 play/pause
            if event.type == .keyDown, !event.isARepeat { togglePlayPause() }
            return true
        default:
            break
        }

        if event.type == .keyUp {
            if event.keyCode == 123 || event.keyCode == 124 {
                arrowHoldKeys.remove(event.keyCode)
                if arrowHoldKeys.isEmpty { stopHoldScrub() }
                return true
            }
            return false
        }

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

        switch event.keyCode {
        case 36, 76: // Return / keypad Enter — close this window only (must be key)
            window?.close()
            return true
        case 123:
            arrowHoldKeys.insert(123)
            startHoldScrub(forward: false)
            return true
        case 124:
            arrowHoldKeys.insert(124)
            startHoldScrub(forward: true)
            return true
        case 125:
            adjustVolume(by: -0.05)
            return true
        case 126:
            adjustVolume(by: 0.05)
            return true
        default:
            return false
        }
    }

    var mediaTitle: String { videoURL.lastPathComponent }
    var mediaElapsed: Double { scrubBar?.value ?? 0 }
    var mediaDuration: Double { durationSeconds }
    var mediaRate: Float { queuePlayer?.rate ?? 0 }
    var mediaIsPlaying: Bool { (queuePlayer?.rate ?? 0) != 0 }

    func mediaTogglePlayPause() {
        togglePlayPause()
        MediaKeys.shared.refreshNowPlaying()
    }

    func mediaAdjustVolume(by delta: Float) {
        adjustVolume(by: delta)
    }

    func mediaToggleMute() {
        toggleMute()
    }

    func mediaBeginScrub(forward: Bool) {
        startHoldScrub(forward: forward)
    }

    func mediaEndScrub() {
        stopHoldScrub()
    }

    /// Hold F7/F9 / arrows / media rewind-fast: display-link shuttle, no extra clicks.
    private func startHoldScrub(forward: Bool) {
        guard hasActivePlayback else { return }
        scrollEndWork?.cancel()
        scrollEndWork = nil
        mediaHoldScrubForward = forward
        if mediaHoldScrubActive { return }

        isScrubbing = true
        if let player = queuePlayer, player.rate != 0 {
            pausedForWheelScrub = true
            player.rate = 0
        }
        mediaHoldScrubActive = true
        holdScrubStartedAt = CFAbsoluteTimeGetCurrent()
        lastHoldTickAt = 0
        holdScrubTick()
    }

    private func holdScrubTick() {
        guard mediaHoldScrubActive else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if lastHoldTickAt != 0, now - lastHoldTickAt < liveSeekInterval { return }
        let tick = lastHoldTickAt == 0 ? PlaybackScrubMath.holdTick : min(now - lastHoldTickAt, 0.12)
        lastHoldTickAt = now
        let duration = max(durationSeconds, scrubBar.maxValue, 0.001)
        let held = now - holdScrubStartedAt
        let step = PlaybackScrubMath.holdStep(duration: duration, held: held, tick: tick)
        let delta = mediaHoldScrubForward ? step : -step
        let next = min(duration, max(0, scrubBar.value + delta))
        setScrubBarTime(next, forceRedraw: true)
        seek(to: next, precise: false)
    }

    private func stopHoldScrub() {
        guard mediaHoldScrubActive else { return }
        mediaHoldScrubActive = false
        lastHoldTickAt = 0
        let target = scrubBar.value
        setScrubBarTime(target, forceRedraw: true)
        seek(to: target, precise: true) { [weak self] in
            guard let self else { return }
            self.isScrubbing = false
            if self.pausedForWheelScrub {
                self.pausedForWheelScrub = false
                self.queuePlayer?.playImmediately(atRate: self.currentRate)
            }
        }
    }

    private func togglePlayPause() {
        guard let player = queuePlayer else { return }
        if player.rate == 0 {
            player.rate = currentRate
        } else {
            player.rate = 0
        }
        MediaKeys.shared.refreshNowPlaying()
    }

    private func applyVolume(_ volume: Float) {
        guard let player = queuePlayer else { return }
        if volume > 0.0001 {
            preMuteVolume = volume
        }
        player.volume = volume
    }

    private func adjustVolume(by delta: Float) {
        guard let player = queuePlayer else { return }
        let newVol = min(1.0, max(0.0, player.volume + delta))
        applyVolume(newVol)
        volumeSlider.value = Double(newVol)
        volumeSlider.needsDisplay = true
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

    /// 1 — toggle 50% / 100% speed. The Slo-Mo button passes flashHUD: false to stay silent.
    private func toggleHalfSpeed(flashHUD: Bool = true) {
        if abs(currentRate - 0.5) < 0.001 {
            currentRate = 1.0
        } else {
            currentRate = 0.5
        }
        if let player = queuePlayer, player.rate != 0 {
            player.rate = currentRate
        }
        if flashHUD {
            flashRate()
        } else {
            updateSlomoLabel()
        }
    }

    /// Slo-Mo button — same half-speed toggle as the "1" key, but no HUD flash.
    private func toggleSlomo() {
        toggleHalfSpeed(flashHUD: false)
    }

    private func updateSlomoLabel() {
        slomoButton?.setTitle(abs(currentRate - 0.5) < 0.001 ? "Normal" : "Slo-Mo")
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
        MediaKeys.shared.refreshNowPlaying()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        startPlayheadLink()
    }

    func windowDidResignKey(_ notification: Notification) {
        lowerWhenInactive()
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
        stopPlayheadLink()
        pendingPlayheadSeconds = nil
        scrollSeekWork?.cancel()
        scrollSeekWork = nil
        scrollSeekPending = nil
        scrollEndWork?.cancel()
        scrollEndWork = nil
        mediaHoldScrubActive = false
        lastHoldTickAt = 0
        mouseScrollRemainder = 0
        pausedForWheelScrub = false
        seekInFlight = false
        queuedSeekSeconds = nil
        queuedSeekCompletion = nil
        arrowHoldKeys.removeAll()
        rateHUDHideWork?.cancel()
        rateHUDHideWork = nil
        AssetCache.cancelLoads(for: videoURL)
        if removeKeyMonitor, let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        playerLooper?.disableLooping()
        playerLooper = nil
        templateItem = nil
        loopApplySerial += 1
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
