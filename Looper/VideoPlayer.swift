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

// MARK: - Window geometry (pure — testable without a playing window)

/// The window is a video column (picture + footer) plus an optional right-hand
/// info column. The video region always keeps the clip's aspect; UI chrome is
/// accounted for separately instead of constraining the whole content area.
enum PlayerWindowLayout {
    static let footerHeight: CGFloat = 52
    static let capsuleHeight: CGFloat = 40
    static let capsuleHorizontalInset: CGFloat = 8
    static let circleDiameter: CGFloat = 28
    static let inspectorWidth: CGFloat = 300
    static let separatorWidth: CGFloat = 1
    static let minVideoWidth: CGFloat = 320
    static let minVideoHeight: CGFloat = 180

    static var inspectorAllocation: CGFloat { inspectorWidth + separatorWidth }

    /// Largest video size (clamped to minimums, preserving source aspect) that
    /// fits inside the given budget.
    static func fitVideoSize(source: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard source.width > 0, source.height > 0, maxWidth > 0, maxHeight > 0 else {
            return CGSize(width: minVideoWidth, height: minVideoHeight)
        }
        let scale = min(1.0, min(maxWidth / source.width, maxHeight / source.height))
        var w = floor(source.width * scale)
        var h = floor(source.height * scale)
        if w < minVideoWidth { let s = minVideoWidth / w; w = minVideoWidth; h = floor(h * s) }
        if h < minVideoHeight { let s = minVideoHeight / h; h = minVideoHeight; w = floor(w * s) }
        return CGSize(width: max(1, w), height: max(1, h))
    }

    static func contentSize(videoSize: CGSize, inspectorOpen: Bool) -> CGSize {
        CGSize(
            width: videoSize.width + (inspectorOpen ? inspectorAllocation : 0),
            height: videoSize.height + footerHeight)
    }

    /// Resize: keep the video region at `videoAspect`, whichever dimension the
    /// user dragged harder drives. Returns the corrected CONTENT size.
    static func aspectCorrectedContentSize(
        proposedContent: CGSize,
        videoAspect: CGFloat,
        lastVideoSize: CGSize,
        inspectorOpen: Bool,
        maxVideoSize: CGSize
    ) -> CGSize {
        guard videoAspect > 0, videoAspect.isFinite else { return proposedContent }
        let alloc = inspectorOpen ? inspectorAllocation : 0
        var vw = proposedContent.width - alloc
        var vh = proposedContent.height - footerHeight

        let dw = abs(vw - lastVideoSize.width) / max(lastVideoSize.width, 1)
        let dh = abs(vh - lastVideoSize.height) / max(lastVideoSize.height, 1)
        if dw >= dh {
            vh = vw / videoAspect
        } else {
            vw = vh * videoAspect
        }
        if vw > maxVideoSize.width { vw = maxVideoSize.width; vh = vw / videoAspect }
        if vh > maxVideoSize.height { vh = maxVideoSize.height; vw = vh * videoAspect }
        if vw < minVideoWidth { vw = minVideoWidth; vh = vw / videoAspect }
        if vh < minVideoHeight { vh = minVideoHeight; vw = vh * videoAspect }
        vw = max(1, floor(vw))
        vh = max(1, floor(vh))
        return CGSize(width: vw + alloc, height: vh + footerHeight)
    }
}

// MARK: - Loop wrap math (pure)

enum PlayerTimelineMath {
    /// Did the playhead wrap from the end of [start, end] back to its start?
    /// Works for full-clip loops and custom in/out ranges alike.
    static func isLoopWrap(previous: Double, current: Double, start: Double, end: Double) -> Bool {
        guard previous.isFinite, current.isFinite, start.isFinite, end.isFinite else { return false }
        let span = end - start
        guard span > 0 else { return false }
        let headRoom = min(0.5, span * 0.3)
        let nearEnd = previous >= end - span * 0.3
        let nearStart = current <= start + headRoom && current >= start - headRoom
        return nearEnd && nearStart
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
        playerLayer.videoGravity = .resizeAspect
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

// MARK: - Timeline rail inside the glass capsule

final class VideoScrubBar: NSView {
    var value: Double = 0
    var maxValue: Double = 1
    var loopInValue: Double?
    var loopOutValue: Double?
    var onScrubStart: (() -> Void)?
    var onScrubEnd: (() -> Void)?
    var onValueChanged: ((Double) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    /// (clickedSeconds, clearsExistingLoop) — the second arg is true when a
    /// complete pair already existed at the START of this click sequence.
    var onDoubleClick: ((Double, Bool) -> Void)?

    private var dragging = false
    /// Snapshot taken on the first mouseDown of a click sequence: the first
    /// click may itself clear the pair (scrub-outside), which would otherwise
    /// erase the information a third double-click needs to mean "clear".
    private var clickSequenceHadCompletePair = false

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

    // MARK: Shared rail geometry — draw, hit, and knob math MUST agree.

    private static let railInset: CGFloat = 10
    private static let railHeight: CGFloat = 6
    private static let thumbSize = NSSize(width: 14, height: 12)

    private var railRect: NSRect {
        let w = max(bounds.width - Self.railInset * 2, 1)
        return NSRect(x: Self.railInset, y: bounds.midY - Self.railHeight / 2,
                      width: w, height: Self.railHeight)
    }

    private func timeFraction(atViewX x: CGFloat) -> Double {
        let rail = railRect
        return Double(min(1, max(0, (x - rail.minX) / rail.width)))
    }

    /// Pixel X of the knob center — used to skip redundant redraws during playback.
    var knobPixelX: CGFloat {
        let rail = railRect
        let fraction = maxValue > 0 ? min(1, max(0, value / maxValue)) : 0
        return round(rail.minX + rail.width * CGFloat(fraction))
    }

    override func draw(_ dirtyRect: NSRect) {
        let rail = railRect
        let trackY = bounds.midY
        let fraction = maxValue > 0 ? min(1, max(0, value / maxValue)) : 0
        let knobX = round(rail.minX + rail.width * CGFloat(fraction))

        // Unplayed rail.
        NSColor.labelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: rail, xRadius: rail.height / 2, yRadius: rail.height / 2).fill()

        // Played progress.
        if fraction > 0 {
            var progress = rail
            progress.size.width = max(rail.height, rail.width * CGFloat(fraction))
            NSColor.labelColor.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: progress, xRadius: rail.height / 2, yRadius: rail.height / 2).fill()
        }

        // Green loop range + markers (under the thumb so it stays legible).
        if maxValue > 0, let inValue = loopInValue {
            let inX = rail.minX + rail.width * CGFloat(min(1, max(0, inValue / maxValue)))
            if let outValue = loopOutValue {
                let outX = rail.minX + rail.width * CGFloat(min(1, max(0, outValue / maxValue)))
                let rangeRect = NSRect(x: inX, y: trackY - 7, width: outX - inX, height: 14)
                NSColor.systemGreen.withAlphaComponent(0.45).setFill()
                NSBezierPath(roundedRect: rangeRect, xRadius: 5, yRadius: 5).fill()
                drawLoopMarker(at: outX, trackY: trackY)
            }
            drawLoopMarker(at: inX, trackY: trackY)
        }

        // Thumb last — QuickTime-style rounded pill.
        let thumbRect = NSRect(
            x: knobX - Self.thumbSize.width / 2,
            y: trackY - Self.thumbSize.height / 2,
            width: Self.thumbSize.width, height: Self.thumbSize.height)
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: thumbRect.offsetBy(dx: 0, dy: -0.5),
                     xRadius: thumbRect.height / 2, yRadius: thumbRect.height / 2).fill()
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: thumbRect,
                     xRadius: thumbRect.height / 2, yRadius: thumbRect.height / 2).fill()
    }

    private func drawLoopMarker(at x: CGFloat, trackY: CGFloat) {
        let marker = NSRect(x: x - 2, y: trackY - 7, width: 4, height: 14)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: marker.insetBy(dx: -0.5, dy: -0.5), xRadius: 2, yRadius: 2).fill()
        NSColor.systemGreen.setFill()
        NSBezierPath(roundedRect: marker, xRadius: 2, yRadius: 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1 {
            clickSequenceHadCompletePair = loopInValue != nil && loopOutValue != nil
        } else if event.clickCount == 2 {
            let x = convert(event.locationInWindow, from: nil).x
            let hadPair = clickSequenceHadCompletePair || (loopInValue != nil && loopOutValue != nil)
            onDoubleClick?(timeFraction(atViewX: x) * maxValue, hadPair)
            return
        } else {
            // clickCount >= 3: not a loop command — let it scrub normally.
            clickSequenceHadCompletePair = false
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
        value = timeFraction(atViewX: x) * maxValue
        onValueChanged?(value)
        needsDisplay = true
    }
}

// MARK: - Circular capsule controls (speed / info) — drawn, no NSButton.

/// Shared base for the two bottom-bar circles: hover/press feedback,
/// pointing-hand cursor, VoiceOver button semantics, space/return activation.
class CircleControl: NSView {
    var onActivate: (() -> Void)?
    var accessibilityName: String = "" {
        didSet { setAccessibilityLabel(accessibilityName) }
    }

    private(set) var hovered = false
    private(set) var pressed = false

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        needsDisplay = true
        if inside {
            onActivate?()
            window?.makeFirstResponder(nil) // keep arrow-scrub working after a click
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76 {
            onActivate?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Fill alpha for the circle backing, driven by interaction state.
    var backingAlpha: CGFloat {
        if pressed { return 0.45 }
        return hovered ? 0.30 : 0.18
    }

    func drawCircleBacking(in rect: NSRect) {
        NSColor.labelColor.withAlphaComponent(backingAlpha).setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
    }
}

/// Speed circle — displays the current rate: `1` normal, `½` half.
final class SlomoButton: CircleControl {
    private var title = "1"

    func setTitle(_ newTitle: String) {
        title = newTitle
        setAccessibilityTitle(newTitle)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        drawCircleBacking(in: rect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = title.size(withAttributes: attrs)
        let point = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        title.draw(at: point, withAttributes: attrs)
    }
}

/// Info circle — system info glyph; `isSelected` reflects the open column.
final class InfoButton: CircleControl {
    var isSelected = false {
        didSet {
            setAccessibilityValue(isSelected ? "open" : "closed")
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        if let glyph = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Info") {
            let imageView = NSImageView(image: glyph)
            imageView.contentTintColor = .labelColor
            imageView.imageScaling = .scaleProportionallyDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.setAccessibilityElement(false)
            addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
            ])
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        drawCircleBacking(in: rect)
        if isSelected {
            NSColor.labelColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
        }
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

// MARK: - Player window

/// Maxed local player: instant open, aggressive scrub, gapless loop. Never minimizes to Dock.
final class VideoPlayerWindowController: NSWindowController, NSWindowDelegate, MediaKeyHandling {
    private(set) var videoURL: URL
    private let cascadeOrigin: NSPoint
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var templateItem: AVPlayerItem?
    private var playerColumn: NSView!
    private var playerSurface: PlayerLayerView!
    private var clickView: VideoScrollView!
    private var footer: NSView!
    private var scrubBar: VideoScrubBar!
    private var elapsedLabel: NSTextField!
    private var remainingLabel: NSTextField!
    private var slomoButton: SlomoButton!
    private var infoButton: InfoButton!
    private var infoColumn: VideoInfoView!
    private var infoSeparator: NSView!
    private var metadataSession: VideoMetadataSession!
    private var currentRate: Float = 1.0
    private var currentVolume: Float = 1.0
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
    private var lastVideoSize: CGSize = .zero
    private var videoFrameRate: Float = 30
    private var displayQuarterTurns = 0
    private var didResolveFrameRate = false
    private var preMuteVolume: Float = 1.0
    private var infoOpen = false
    private var preInfoFrame: NSRect?
    private var infoGeometryDirty = false
    private var isUpdatingLayout = false
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
        window.minSize = NSSize(width: 320, height: 232)
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

        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor

        // Left column: video surface over the capsule footer.
        playerColumn = NSView(frame: .zero)
        playerColumn.translatesAutoresizingMaskIntoConstraints = false
        playerColumn.wantsLayer = true
        playerColumn.layer?.backgroundColor = NSColor.black.cgColor
        content.addSubview(playerColumn)

        playerSurface = PlayerLayerView(frame: .zero)
        playerSurface.translatesAutoresizingMaskIntoConstraints = false
        playerSurface.setContentHuggingPriority(.defaultLow, for: .horizontal)
        playerSurface.setContentHuggingPriority(.defaultLow, for: .vertical)
        playerSurface.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        playerSurface.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        playerColumn.addSubview(playerSurface)

        // Click + scroll catcher covers only the picture — never the footer/inspector.
        clickView = VideoScrollView(frame: .zero)
        clickView.translatesAutoresizingMaskIntoConstraints = false
        clickView.onScroll = { [weak self] event in self?.handleScrollWheel(event) }
        clickView.onDoubleClick = { [weak self] in self?.loopPointAtCurrentTime() }
        playerColumn.addSubview(clickView)

        // Footer strip + glass capsule.
        footer = NSView(frame: .zero)
        footer.translatesAutoresizingMaskIntoConstraints = false
        playerColumn.addSubview(footer)

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
        scrubBar.onDoubleClick = { [weak self] seconds, hadPair in
            self?.handleLoopPointInput(at: seconds, clearsExistingLoop: hadPair)
        }

        slomoButton = SlomoButton(frame: .zero)
        slomoButton.translatesAutoresizingMaskIntoConstraints = false
        slomoButton.accessibilityName = "Toggle half speed"
        slomoButton.toolTip = "Half speed"
        slomoButton.onActivate = { [weak self] in self?.toggleSlomo() }
        slomoButton.setTitle("1")

        infoButton = InfoButton(frame: .zero)
        infoButton.translatesAutoresizingMaskIntoConstraints = false
        infoButton.accessibilityName = "Video Info"
        infoButton.toolTip = "Video Info"
        infoButton.onActivate = { [weak self] in self?.toggleInfo() }

        // Row content lives inside the capsule material; its own 10pt padding
        // is internal so the glass can manage the row as its contentView.
        let row = NSView(frame: .zero)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(elapsedLabel)
        row.addSubview(scrubBar)
        row.addSubview(remainingLabel)
        row.addSubview(slomoButton)
        row.addSubview(infoButton)

        let capsule = makeCapsuleContainer(content: row)
        footer.addSubview(capsule)

        // Right-hand info column + hairline separator (hidden until requested).
        infoSeparator = NSView(frame: .zero)
        infoSeparator.wantsLayer = true
        infoSeparator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        infoSeparator.translatesAutoresizingMaskIntoConstraints = false
        infoSeparator.isHidden = true
        content.addSubview(infoSeparator)

        infoColumn = VideoInfoView(frame: .zero)
        infoColumn.translatesAutoresizingMaskIntoConstraints = false
        infoColumn.isHidden = true
        infoColumn.setFileName(videoURL.lastPathComponent)
        content.addSubview(infoColumn)

        metadataSession = VideoMetadataSession()
        metadataSession.onChange = { [weak self] state in
            self?.infoColumn.present(state)
        }

        let footerH = PlayerWindowLayout.footerHeight
        let capsuleH = PlayerWindowLayout.capsuleHeight
        let capsuleInsetX = PlayerWindowLayout.capsuleHorizontalInset
        let circle = PlayerWindowLayout.circleDiameter
        NSLayoutConstraint.activate([
            playerColumn.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerColumn.topAnchor.constraint(equalTo: content.topAnchor),
            playerColumn.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            playerColumn.trailingAnchor.constraint(equalTo: infoSeparator.leadingAnchor),

            playerSurface.leadingAnchor.constraint(equalTo: playerColumn.leadingAnchor),
            playerSurface.trailingAnchor.constraint(equalTo: playerColumn.trailingAnchor),
            playerSurface.topAnchor.constraint(equalTo: playerColumn.topAnchor),
            playerSurface.bottomAnchor.constraint(equalTo: footer.topAnchor),

            clickView.leadingAnchor.constraint(equalTo: playerColumn.leadingAnchor),
            clickView.trailingAnchor.constraint(equalTo: playerColumn.trailingAnchor),
            clickView.topAnchor.constraint(equalTo: playerColumn.topAnchor),
            clickView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: playerColumn.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: playerColumn.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: playerColumn.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: footerH),

            capsule.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: capsuleInsetX),
            capsule.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -capsuleInsetX),
            capsule.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            capsule.heightAnchor.constraint(equalToConstant: capsuleH),

            elapsedLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            elapsedLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            elapsedLabel.widthAnchor.constraint(equalToConstant: 44),

            scrubBar.leadingAnchor.constraint(equalTo: elapsedLabel.trailingAnchor, constant: 8),
            scrubBar.trailingAnchor.constraint(equalTo: remainingLabel.leadingAnchor, constant: -8),
            scrubBar.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            scrubBar.heightAnchor.constraint(equalToConstant: circle),

            remainingLabel.trailingAnchor.constraint(equalTo: slomoButton.leadingAnchor, constant: -8),
            remainingLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            remainingLabel.widthAnchor.constraint(equalToConstant: 50),

            slomoButton.trailingAnchor.constraint(equalTo: infoButton.leadingAnchor, constant: -8),
            slomoButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            slomoButton.widthAnchor.constraint(equalToConstant: circle),
            slomoButton.heightAnchor.constraint(equalToConstant: circle),

            infoButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            infoButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            infoButton.widthAnchor.constraint(equalToConstant: circle),
            infoButton.heightAnchor.constraint(equalToConstant: circle),

            infoSeparator.topAnchor.constraint(equalTo: content.topAnchor),
            infoSeparator.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            infoSeparator.trailingAnchor.constraint(equalTo: infoColumn.leadingAnchor),
            infoSeparator.widthAnchor.constraint(equalToConstant: PlayerWindowLayout.separatorWidth),

            infoColumn.topAnchor.constraint(equalTo: content.topAnchor),
            infoColumn.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            infoColumn.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            infoColumn.widthAnchor.constraint(equalToConstant: PlayerWindowLayout.inspectorWidth),
        ])
    }

    /// Rounded glass capsule on macOS 26+; dark HUD material before that.
    /// The row view becomes the effect view's content on glass.
    private func makeCapsuleContainer(content row: NSView) -> NSView {
        let radius = PlayerWindowLayout.capsuleHeight / 2
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = radius
            glass.contentView = row
            glass.translatesAutoresizingMaskIntoConstraints = false
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = true
            }
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = radius
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            row.topAnchor.constraint(equalTo: effect.topAnchor),
            row.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    private func makeTimeLabel(_ string: String) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.isBezeled = false
        label.drawsBackground = false
        label.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.35)
            s.shadowBlurRadius = 3
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

    /// Video aspect including the user's display rotation (L key).
    private var rotatedSourceSize: CGSize {
        guard let pixelSize = videoPixelSize, pixelSize.width > 0, pixelSize.height > 0 else {
            return CGSize(width: 16, height: 9)
        }
        return displayQuarterTurns % 2 == 1
            ? CGSize(width: pixelSize.height, height: pixelSize.width)
            : pixelSize
    }

    private var videoAspect: CGFloat {
        let s = rotatedSourceSize
        return s.height > 0 ? s.width / s.height : 0
    }

    /// Title bar + any real frame chrome, measured rather than hard-coded.
    private var frameChromeHeight: CGFloat {
        guard let window else { return 0 }
        return window.frameRect(forContentRect: .zero).height
    }

    private func updateMinSize() {
        guard let window else { return }
        let aspect = videoAspect
        let minVideoH = aspect > 0
            ? max(PlayerWindowLayout.minVideoHeight,
                  floor(PlayerWindowLayout.minVideoWidth / aspect))
            : PlayerWindowLayout.minVideoHeight
        let minContent = PlayerWindowLayout.contentSize(
            videoSize: CGSize(width: PlayerWindowLayout.minVideoWidth, height: minVideoH),
            inspectorOpen: infoOpen)
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: minContent)).size
    }

    /// Size the window to the clip’s native resolution (scaled down only to fit the screen).
    /// The FOOTER and open inspector are UI chrome — the video keeps its own aspect.
    private func applyNativeWindowSize(_ videoSize: CGSize) {
        guard let window else { return }
        videoPixelSize = videoSize
        let screen = window.screen ?? NSScreen.main
        guard let screen else { return }

        let visible = screen.visibleFrame.insetBy(dx: 20, dy: 20)
        let inspectorAlloc = infoOpen ? PlayerWindowLayout.inspectorAllocation : 0
        let maxVideoW = max(64, visible.width - inspectorAlloc)
        let maxVideoH = max(64, visible.height - frameChromeHeight - PlayerWindowLayout.footerHeight)
        let fitted = PlayerWindowLayout.fitVideoSize(
            source: rotatedSourceSize, maxWidth: maxVideoW, maxHeight: maxVideoH)
        lastVideoSize = fitted

        updateMinSize()

        let contentSize = PlayerWindowLayout.contentSize(videoSize: fitted, inspectorOpen: infoOpen)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))

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

        isUpdatingLayout = true
        window.animationBehavior = .none
        window.setFrame(frame, display: true, animate: false)
        isUpdatingLayout = false
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
        applyVolume(currentVolume)

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

    // MARK: - Info column (lazy metadata — playback never touches it)

    private func toggleInfo() {
        setInfoVisible(!infoOpen)
    }

    /// Open: widen the window, keeping the video size when the screen allows.
    /// Close: restore the remembered frame unless the user moved/resized while open.
    private func setInfoVisible(_ open: Bool) {
        guard open != infoOpen, let window else { return }
        infoOpen = open
        infoButton.isSelected = open

        if open {
            preInfoFrame = window.frame
            infoGeometryDirty = false
            infoSeparator.isHidden = false
            infoColumn.isHidden = false
            infoColumn.setFileName(videoURL.lastPathComponent)
            metadataSession.show()

            let add = PlayerWindowLayout.inspectorAllocation
            var frame = window.frame
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 8, dy: 8)
                ?? NSRect(x: 0, y: 0, width: 10_000, height: 10_000)
            frame.size.width += add
            if frame.maxX > visible.maxX { frame.origin.x -= frame.maxX - visible.maxX }
            if frame.minX < visible.minX {
                // Won't fit even shifted — shrink the video uniformly to make room.
                frame.origin.x = visible.minX
                let maxVideoW = max(64, visible.width - add)
                let maxVideoH = max(64, visible.height - frameChromeHeight - PlayerWindowLayout.footerHeight)
                let fitted = PlayerWindowLayout.fitVideoSize(
                    source: rotatedSourceSize, maxWidth: maxVideoW, maxHeight: maxVideoH)
                lastVideoSize = fitted
                let content = PlayerWindowLayout.contentSize(videoSize: fitted, inspectorOpen: true)
                frame.size = window.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
                frame.origin.y = window.frame.maxY - frame.height // keep top edge
            }
            updateMinSize()
            isUpdatingLayout = true
            window.animationBehavior = .none
            window.setFrame(frame, display: true, animate: false)
            isUpdatingLayout = false
        } else {
            metadataSession.hide()
            updateMinSize()
            var frame = window.frame
            if !infoGeometryDirty, let saved = preInfoFrame {
                // Restore the pre-open width at the current origin (moves preserved).
                frame.size.width = saved.width
            } else {
                frame.size.width -= PlayerWindowLayout.inspectorAllocation
            }
            infoSeparator.isHidden = true
            infoColumn.isHidden = true
            isUpdatingLayout = true
            window.animationBehavior = .none
            window.setFrame(frame, display: true, animate: false)
            isUpdatingLayout = false
        }
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
        let hadPair = scrubBar.loopInValue != nil && scrubBar.loopOutValue != nil
        handleLoopPointInput(at: seconds, clearsExistingLoop: hadPair)
    }

    /// One state machine for both surfaces: pending point → complete pair → clear.
    /// `clearsExistingLoop` comes from the scrub bar's click-sequence snapshot —
    /// the first click of a double-click may itself have cleared the pair via
    /// scrub-outside, so intent must arrive with the second click.
    private func handleLoopPointInput(at seconds: Double, clearsExistingLoop: Bool) {
        if clearsExistingLoop || (scrubBar.loopInValue != nil && scrubBar.loopOutValue != nil) {
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
        if infoOpen { infoGeometryDirty = true }
        infoColumn.setFileName(url.lastPathComponent)
        metadataSession.setSource(url)
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

    /// Effective wrap bounds: the custom pair while one is active, else the clip.
    private var loopBounds: (start: Double, end: Double) {
        if let lo = scrubBar?.loopInValue, let hi = scrubBar?.loopOutValue, hi > lo {
            return (lo, hi)
        }
        return (0, max(durationSeconds, scrubBar?.maxValue ?? 0, 0.001))
    }

    private func playerTimeFired(_ time: CMTime) {
        guard !isScrubbing, !scrollScrubActive, !mediaHoldScrubActive else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }

        let bounds = loopBounds
        let slop = frameDuration * 2
        if let pending = pendingPlayheadSeconds {
            let waited = CFAbsoluteTimeGetCurrent() - pendingPlayheadSince
            let caughtUp = abs(seconds - pending) <= slop
            let looped = PlayerTimelineMath.isLoopWrap(
                previous: pending, current: seconds, start: bounds.start, end: bounds.end)
            if caughtUp || looped || waited > 0.22 {
                pendingPlayheadSeconds = nil
            } else {
                return
            }
        }

        let playing = (queuePlayer?.rate ?? 0) != 0
        if playing, seconds + slop < scrubBar.value {
            // Backward jump: accept only a wrap to the effective range start —
            // an active custom loop wraps at its in-point, not at time zero.
            if PlayerTimelineMath.isLoopWrap(
                previous: scrubBar.value, current: seconds, start: bounds.start, end: bounds.end) {
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

    /// Player owns keys only when a player surface has focus — inspector
    /// buttons, selectable text, and the circle controls get theirs first.
    private func isNonPlayerResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder === window?.contentView || responder === clickView
            || responder === playerSurface || responder === scrubBar
            || responder === playerColumn || responder === footer {
            return false
        }
        return true
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let commandHeld = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        if event.type == .keyDown, commandHeld, event.charactersIgnoringModifiers?.lowercased() == "q" {
            NSApp.terminate(nil)
            return true
        }

        if isNonPlayerResponder(window?.firstResponder) {
            // Focus left the player mid-hold — release the scrub so it can't stick.
            if mediaHoldScrubActive || !arrowHoldKeys.isEmpty {
                arrowHoldKeys.removeAll()
                stopHoldScrub()
            }
            return false
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
        currentVolume = volume
        if volume > 0.0001 {
            preMuteVolume = volume
        }
        queuePlayer?.volume = volume
    }

    private func adjustVolume(by delta: Float) {
        guard let player = queuePlayer else { return }
        let newVol = min(1.0, max(0.0, player.volume + delta))
        applyVolume(newVol)
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
    }

    private func resetSpeed() {
        currentRate = 1.0
        if let player = queuePlayer, player.rate != 0 {
            player.rate = currentRate
        }
        updateSlomoLabel()
    }

    /// 1 — toggle 50% / 100% speed. Silent everywhere: the circle's glyph IS the indicator.
    private func toggleHalfSpeed() {
        if abs(currentRate - 0.5) < 0.001 {
            currentRate = 1.0
        } else {
            currentRate = 0.5
        }
        if let player = queuePlayer, player.rate != 0 {
            player.rate = currentRate
        }
        updateSlomoLabel()
    }

    /// Speed circle — same half-speed toggle as the "1" key.
    private func toggleSlomo() {
        toggleHalfSpeed()
    }

    private func updateSlomoLabel() {
        slomoButton?.setTitle(abs(currentRate - 0.5) < 0.001 ? "½" : "1")
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
        guard let window, videoPixelSize != nil else { return }
        if infoOpen { infoGeometryDirty = true }

        let screen = window.screen ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame.insetBy(dx: 20, dy: 20)
        let inspectorAlloc = infoOpen ? PlayerWindowLayout.inspectorAllocation : 0
        let fitted = PlayerWindowLayout.fitVideoSize(
            source: rotatedSourceSize,
            maxWidth: max(64, visible.width - inspectorAlloc),
            maxHeight: max(64, visible.height - frameChromeHeight - PlayerWindowLayout.footerHeight))
        lastVideoSize = fitted
        updateMinSize()

        let contentSize = PlayerWindowLayout.contentSize(videoSize: fitted, inspectorOpen: infoOpen)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        let old = window.frame
        frame.origin.x = old.midX - frame.width / 2
        frame.origin.y = old.midY - frame.height / 2
        isUpdatingLayout = true
        window.animationBehavior = .none
        window.setFrame(frame, display: true, animate: false)
        isUpdatingLayout = false
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

    /// User-driven resize: keep the VIDEO region at clip aspect; the footer and
    /// inspector are fixed chrome, so the whole window is not aspect-locked.
    func windowWillResize(_ sender: NSWindow, to proposed: NSSize) -> NSSize {
        let aspect = videoAspect
        guard aspect > 0 else { return proposed }
        if infoOpen { infoGeometryDirty = true }

        let proposedContent = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: proposed)).size
        let inspectorAlloc = infoOpen ? PlayerWindowLayout.inspectorAllocation : 0
        let visible = (sender.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 8, dy: 8)
            ?? NSRect(x: 0, y: 0, width: 10_000, height: 10_000)
        let maxVideo = CGSize(
            width: max(64, visible.width - inspectorAlloc),
            height: max(64, visible.height - frameChromeHeight - PlayerWindowLayout.footerHeight))
        let corrected = PlayerWindowLayout.aspectCorrectedContentSize(
            proposedContent: proposedContent,
            videoAspect: aspect,
            lastVideoSize: lastVideoSize,
            inspectorOpen: infoOpen,
            maxVideoSize: maxVideo)
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: corrected)).size
    }

    func windowDidResize(_ notification: Notification) {
        if !isUpdatingLayout, let surface = playerSurface {
            lastVideoSize = surface.bounds.size
        }
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
        metadataSession?.invalidate()
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
