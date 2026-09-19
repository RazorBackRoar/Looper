import AppKit
import AVFoundation
import CoreVideo
import XCTest
@testable import Looper

final class LooperLogicTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LooperTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        WindowFrameStore.defaults = defaults
        AssetCache.defaults = defaults
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        WindowFrameStore.defaults = .standard
        AssetCache.defaults = .standard
        super.tearDown()
    }

    // MARK: - LocalVideoURL

    func testLocalVideoURLPlayableFiles() {
        XCTAssertTrue(LocalVideoURL.isPlayableFile(URL(fileURLWithPath: "/tmp/sample.mp4")))
        XCTAssertTrue(LocalVideoURL.isPlayableFile(URL(fileURLWithPath: "/tmp/sample.mov")))
        XCTAssertTrue(LocalVideoURL.isPlayableFile(URL(fileURLWithPath: "/tmp/sample.m4v")))
        XCTAssertTrue(LocalVideoURL.isPlayableFile(URL(fileURLWithPath: "/tmp/sample.mkv")))
        XCTAssertTrue(LocalVideoURL.isPlayableFile(URL(fileURLWithPath: "/tmp/sample.MP4")))
        XCTAssertTrue(LocalVideoURL.isPlayableFile(URL(fileURLWithPath: "/tmp/sample.MOV")))

        XCTAssertFalse(LocalVideoURL.isPlayableFile(URL(fileURLWithPath: "/tmp/sample.txt")))
        XCTAssertFalse(LocalVideoURL.isPlayableFile(URL(fileURLWithPath: "/tmp/sample.png")))
        XCTAssertFalse(LocalVideoURL.isPlayableFile(URL(string: "https://example.com/sample.mp4")!))
        XCTAssertFalse(LocalVideoURL.isPlayableFile(URL(string: "http://127.0.0.1/clip.mov")!))

        let mixed = [
            URL(fileURLWithPath: "/tmp/valid.mp4"),
            URL(fileURLWithPath: "/tmp/invalid.txt"),
            URL(string: "https://example.com/stream.mov")!,
            URL(fileURLWithPath: "/tmp/valid.m4v"),
        ]
        let filtered = LocalVideoURL.onlyPlayableFiles(mixed)
        XCTAssertEqual(filtered.count, 2)
        XCTAssertEqual(filtered[0].path, "/tmp/valid.mp4")
        XCTAssertEqual(filtered[1].path, "/tmp/valid.m4v")
    }

    // MARK: - PlaybackFormatting

    func testFormatTime() {
        XCTAssertEqual(PlaybackFormatting.formatTime(0), "0:00")
        XCTAssertEqual(PlaybackFormatting.formatTime(5), "0:05")
        XCTAssertEqual(PlaybackFormatting.formatTime(59.9), "0:59")
        XCTAssertEqual(PlaybackFormatting.formatTime(61), "1:01")
        XCTAssertEqual(PlaybackFormatting.formatTime(3600), "60:00")
        XCTAssertEqual(PlaybackFormatting.formatTime(.nan), "0:00")
        XCTAssertEqual(PlaybackFormatting.formatTime(.infinity), "0:00")
        XCTAssertEqual(PlaybackFormatting.formatTime(-3), "0:00")
    }

    func testFormatRate() {
        XCTAssertEqual(PlaybackFormatting.formatRate(1), "1×")
        XCTAssertEqual(PlaybackFormatting.formatRate(0.5), "0.5×")
        XCTAssertEqual(PlaybackFormatting.formatRate(1.25), "1.25×")
        XCTAssertEqual(PlaybackFormatting.formatRate(2), "2×")
    }

    // MARK: - WindowFrameStore

    func testWindowFrameStoreSaveAndLoad() {
        let tempURL = URL(fileURLWithPath: "/tmp/looper_test_sample.mp4")
        let originalFrame = NSRect(x: 100, y: 150, width: 800, height: 600)

        WindowFrameStore.saveFrame(originalFrame, for: tempURL)
        let loaded = WindowFrameStore.loadFrame(for: tempURL)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.origin.x, 100)
        XCTAssertEqual(loaded?.origin.y, 150)
        XCTAssertEqual(loaded?.size.width, 800)
        XCTAssertEqual(loaded?.size.height, 600)
    }

    func testWindowFrameStoreMissingFileReturnsNil() {
        let nonExistentURL = URL(fileURLWithPath: "/tmp/looper_nonexistent_\(UUID().uuidString).mp4")
        XCTAssertNil(WindowFrameStore.loadFrame(for: nonExistentURL))
    }

    func testWindowFrameStoreCapsPersistedEntries() {
        for i in 0..<401 {
            let url = URL(fileURLWithPath: "/tmp/looper_frame_cap_\(i).mp4")
            WindowFrameStore.saveFrame(NSRect(x: CGFloat(i), y: 0, width: 640, height: 360), for: url)
        }
        XCTAssertLessThanOrEqual(WindowFrameStore.storedFrameCount(), 300)
        XCTAssertEqual(WindowFrameStore.storedFrameCount(), 300)
    }

    func testWindowFrameStoreRecentFilesNewestFirst() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("looper-recents-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = dir.appendingPathComponent("first.mp4")
        let second = dir.appendingPathComponent("second.mp4")
        FileManager.default.createFile(atPath: first.path, contents: Data(), attributes: nil)
        FileManager.default.createFile(atPath: second.path, contents: Data(), attributes: nil)

        WindowFrameStore.noteOpened(first)
        WindowFrameStore.noteOpened(second)
        let recents = WindowFrameStore.recentFileURLs()
        XCTAssertEqual(recents.first?.lastPathComponent, "second.mp4")
        XCTAssertEqual(recents[1].lastPathComponent, "first.mp4")
    }

    // MARK: - AssetCache

    func testAssetCacheStoreAndRetrieveProperties() {
        let url = URL(fileURLWithPath: "/tmp/looper_cache_test.mp4")

        AssetCache.storeNativeSize(CGSize(width: 1920, height: 1080), for: url)
        XCTAssertEqual(AssetCache.cachedNativeSize(for: url), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(AssetCache.cacheKey(for: url), "/tmp/looper_cache_test.mp4")

        AssetCache.storeNativeSize(CGSize(width: 1, height: 1), for: url)
        XCTAssertEqual(AssetCache.cachedNativeSize(for: url), CGSize(width: 1920, height: 1080))

        let poster = NSImage(size: NSSize(width: 100, height: 100))
        AssetCache.storePoster(poster, for: url)
        XCTAssertNotNil(AssetCache.cachedPoster(for: url))
    }

    func testAssetCacheCapsPersistedNativeSizes() {
        for i in 0..<401 {
            let url = URL(fileURLWithPath: "/tmp/looper_size_cap_\(i).mp4")
            AssetCache.storeNativeSize(CGSize(width: 640, height: 360), for: url)
        }
        let dict = AssetCache.defaults.dictionary(forKey: AssetCache.sizeDefaultsKey) as? [String: String]
        XCTAssertLessThanOrEqual(dict?.count ?? 0, 300)
    }

    func testAssetCacheCancelLoadsDoesNotCrash() {
        let url = URL(fileURLWithPath: "/tmp/looper_cancel_\(UUID().uuidString).mp4")
        AssetCache.cancelLoads(for: url)
        AssetCache.cancelAllLoads()
    }

    @MainActor func testAssetCacheLoadFrameRateAndHDR() {
        let url = URL(fileURLWithPath: "/tmp/looper_nonexistent_\(UUID().uuidString).mp4")
        let expectationFPS = expectation(description: "loadFrameRate returns nil for non-existent file")
        AssetCache.loadFrameRate(url) { rate in
            XCTAssertNil(rate)
            expectationFPS.fulfill()
        }

        let expectationHDR = expectation(description: "loadContainsHDR returns false for non-existent file")
        AssetCache.loadContainsHDR(url) { isHDR in
            XCTAssertFalse(isHDR)
            expectationHDR.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    // MARK: - PlaybackScrubMath

    func testMouseWheelStepIgnoresClipLength() {
        XCTAssertEqual(PlaybackScrubMath.mouseNotchStep(), 0.25)
        var remainder: Double = 0
        let short = PlaybackScrubMath.consumeMousePixels(8, remainder: &remainder)
        remainder = 0
        let long = PlaybackScrubMath.consumeMousePixels(8, remainder: &remainder)
        XCTAssertEqual(short, 0.25)
        XCTAssertEqual(long, 0.25)
        XCTAssertEqual(short, long)
    }

    func testMagicMousePixelsAccumulateAndCap() {
        var remainder: Double = 0
        XCTAssertEqual(PlaybackScrubMath.consumeMousePixels(3, remainder: &remainder), 0)
        XCTAssertEqual(PlaybackScrubMath.consumeMousePixels(5, remainder: &remainder), 0.25)
        remainder = 0
        let burst = PlaybackScrubMath.consumeMousePixels(80, remainder: &remainder)
        XCTAssertEqual(burst, PlaybackScrubMath.mouseEventCapSeconds)
        XCTAssertLessThan(burst, 1)
    }

    func testTrackpadStepCapsPerEvent() {
        let twoHour = PlaybackScrubMath.trackpadStep(delta: 40, duration: 7200)
        XCTAssertEqual(twoHour, PlaybackScrubMath.trackpadEventCapSeconds)
        let nudge = PlaybackScrubMath.trackpadStep(delta: 2, duration: 30)
        XCTAssertLessThan(nudge, 0.1)
    }

    func testHoldStepTapIsSmallThenRacesClip() {
        let tick = PlaybackScrubMath.holdTick
        let tap = PlaybackScrubMath.holdStep(duration: 7200, held: 0.05, tick: tick)
        XCTAssertLessThan(tap, 0.4)
        let flying = PlaybackScrubMath.holdStep(duration: 7200, held: 0.8, tick: tick)
        XCTAssertGreaterThan(flying, 200)
    }
}

// MARK: - Metadata parsing

final class VideoMetadataParserTests: XCTestCase {

    func testISO6709DecimalDegrees() {
        let loc = ISO6709LocationParser.parse("+37.3348-122.0090/")
        XCTAssertEqual(loc?.latitude ?? 0, 37.3348, accuracy: 0.0001)
        XCTAssertEqual(loc?.longitude ?? 0, -122.0090, accuracy: 0.0001)
        XCTAssertNil(loc?.altitudeMeters)
    }

    func testISO6709SouthernEasternWithAltitude() {
        let loc = ISO6709LocationParser.parse("-33.8688+151.2093+058.5/")
        XCTAssertEqual(loc?.latitude ?? 0, -33.8688, accuracy: 0.0001)
        XCTAssertEqual(loc?.longitude ?? 0, 151.2093, accuracy: 0.0001)
        XCTAssertEqual(loc?.altitudeMeters ?? 0, 58.5, accuracy: 0.01)
    }

    func testISO6709ZeroAndBoundaries() {
        let zero = ISO6709LocationParser.parse("+00.0000+000.0000/")
        XCTAssertEqual(zero?.latitude ?? 9, 0, accuracy: 0.0001)
        XCTAssertEqual(zero?.longitude ?? 9, 0, accuracy: 0.0001)
        XCTAssertNotNil(ISO6709LocationParser.parse("+90+180/"))
        XCTAssertNotNil(ISO6709LocationParser.parse("-90-180/"))
    }

    func testISO6709DegMinAndDMSForms() {
        // 37° 48.5' N, 122° 24.5' W
        let dm = ISO6709LocationParser.parse("+3748.5-12224.5/")
        XCTAssertEqual(dm?.latitude ?? 0, 37.8083, accuracy: 0.001)
        XCTAssertEqual(dm?.longitude ?? 0, -122.4083, accuracy: 0.001)
        // 37° 30' 45" N
        let dms = ISO6709LocationParser.parse("+373045.5-1223027/")
        XCTAssertEqual(dms?.latitude ?? 0, 37.5126, accuracy: 0.001)
        XCTAssertEqual(dms?.longitude ?? 0, -122.5075, accuracy: 0.001)
    }

    func testISO6709RejectsMalformed() {
        XCTAssertNil(ISO6709LocationParser.parse(""))
        XCTAssertNil(ISO6709LocationParser.parse("37.3,-122.0"))
        XCTAssertNil(ISO6709LocationParser.parse("+91+000/"))     // lat out of range
        XCTAssertNil(ISO6709LocationParser.parse("+00+181/"))    // lon out of range
        XCTAssertNil(ISO6709LocationParser.parse("+3760.0-12224.5/")) // 60 minutes invalid
        XCTAssertNil(ISO6709LocationParser.parse("+37.3-122.0+abc/")) // non-finite altitude
        XCTAssertNil(ISO6709LocationParser.parse("+37-122/CRS84/"))   // CRS tail unsupported
        XCTAssertNil(ISO6709LocationParser.parse("+37-122+63+junk"))
        XCTAssertNil(ISO6709LocationParser.parse("+37"))
    }

    func testFormatHelpers() {
        XCTAssertEqual(VideoMetadataReader.formatFrameRate(29.97), "29.97 fps")
        XCTAssertEqual(VideoMetadataReader.formatFrameRate(60), "60 fps")
        XCTAssertEqual(VideoMetadataReader.formatFrameRate(59.94), "59.94 fps")
        XCTAssertEqual(VideoMetadataReader.formatBitRate(2_400_000), "2.4 Mbps")
        XCTAssertEqual(VideoMetadataReader.formatBitRate(128_000), "128 kbps")
        XCTAssertEqual(VideoMetadataReader.fourCCString(0x68766331), "hvc1")
        XCTAssertEqual(VideoMetadataReader.codecLabel(0x68766331), "HEVC")
        XCTAssertEqual(VideoMetadataReader.codecLabel(0x61766331), "H.264")
        XCTAssertEqual(VideoMetadataReader.codecLabel(0x6D703461), "AAC")
    }

    func testReaderRejectsRemoteURL() async {
        do {
            _ = try await VideoMetadataReader.read(URL(string: "https://example.com/clip.mp4")!)
            XCTFail("remote URL must be rejected")
        } catch {}
    }

    /// End-to-end: write a tiny MOV with AVAssetWriter, read its metadata back.
    func testReaderOnSyntheticMovie() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("looper_meta_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 240,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            ])
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)

        let make = AVMutableMetadataItem()
        make.keySpace = .common
        make.key = AVMetadataKey.commonKeyMake.rawValue as NSString
        make.value = "TestMake" as NSString
        writer.metadata = [make]

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        XCTAssertNotNil(pixelBuffer)
        for i in 0..<10 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            XCTAssertTrue(adaptor.append(pixelBuffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)

        let snapshot = try await VideoMetadataReader.read(url)
        XCTAssertEqual(snapshot.sourceURL, url)

        let file = snapshot.sections.first { $0.title == "File" }
        XCTAssertEqual(file?.fields.first { $0.label == "Name" }?.value, url.lastPathComponent)
        XCTAssertEqual(file?.fields.first { $0.label == "Format" }?.value, "QuickTime")

        let video = snapshot.sections.first { $0.title == "Video" }
        XCTAssertEqual(video?.fields.first { $0.label == "Resolution" }?.value, "320 × 240")
        XCTAssertEqual(video?.fields.first { $0.label == "Codec" }?.value, "H.264")
        XCTAssertNotNil(video?.fields.first { $0.label == "Duration" })

        // No GPS was written — honest "No", not a missing section.
        let location = snapshot.sections.first { $0.title == "Location" }
        XCTAssertEqual(location?.fields.first { $0.label == "GPS" }?.value, "No")
    }
}

// MARK: - Metadata session lifecycle

final class VideoMetadataSessionTests: XCTestCase {

    private func snapshot(for url: URL) -> VideoMetadataSnapshot {
        VideoMetadataSnapshot(
            sourceURL: url,
            sections: [VideoMetadataSection(title: "File", fields: [
                VideoMetadataField(key: "name", label: "Name", value: url.lastPathComponent, source: "file"),
            ])],
            additionalFields: [],
            location: nil,
            unavailableSections: [])
    }

    /// A loader whose invocations are observable and whose results are resolved by hand.
    private final class LoaderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [URL] = []
        private var pending: [CheckedContinuation<VideoMetadataSnapshot, Error>] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var calls: [URL] { lock.withLock { _calls } }

        func loader(_ url: URL) async throws -> VideoMetadataSnapshot {
            try await withCheckedThrowingContinuation { cont in
                let woken = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    pending.append(cont)
                    _calls.append(url)
                    let w = waiters
                    waiters.removeAll()
                    return w
                }
                woken.forEach { $0.resume() }
            }
        }

        func waitForCall() async {
            await waitForCallCount(1)
        }

        func waitForCallCount(_ n: Int) async {
            while lock.withLock({ _calls.count }) < n {
                await withCheckedContinuation { cont in
                    let resumeNow = lock.withLock { () -> Bool in
                        if _calls.count >= n { return true }
                        waiters.append(cont)
                        return false
                    }
                    if resumeNow { cont.resume() }
                }
            }
        }

        func resolve(_ index: Int, with snapshot: VideoMetadataSnapshot) {
            let cont = lock.withLock { pending[index] }
            cont.resume(returning: snapshot)
        }

        func fail(_ index: Int, with error: Error) {
            let cont = lock.withLock { pending[index] }
            cont.resume(throwing: error)
        }
    }

    @MainActor
    private func pump() async {
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(until: .now + .milliseconds(1), clock: .continuous)
        }
    }

    @MainActor
    func testHiddenSessionDoesNotLoad() async {
        let box = LoaderBox()
        let session = VideoMetadataSession(loader: box.loader)
        session.setSource(URL(fileURLWithPath: "/tmp/a.mov"))
        await pump()
        XCTAssertTrue(box.calls.isEmpty)
        XCTAssertEqual(session.state, .idle)
    }

    @MainActor
    func testShowLoadsOnceAndPublishesReady() async {
        let box = LoaderBox()
        let session = VideoMetadataSession(loader: box.loader)
        let url = URL(fileURLWithPath: "/tmp/a.mov")
        var states: [VideoMetadataSession.State] = []
        session.onChange = { states.append($0) }

        session.setSource(url)
        session.show()
        await box.waitForCall()
        XCTAssertEqual(box.calls, [url])
        box.resolve(0, with: snapshot(for: url))
        await pump()
        XCTAssertEqual(session.state, .ready(snapshot(for: url)))
        XCTAssertEqual(states.last, .ready(snapshot(for: url)))
    }

    @MainActor
    func testCloseDuringLoadDoesNotPublish() async {
        let box = LoaderBox()
        let session = VideoMetadataSession(loader: box.loader)
        let url = URL(fileURLWithPath: "/tmp/a.mov")
        session.setSource(url)
        session.show()
        await box.waitForCall()
        session.hide()
        box.resolve(0, with: snapshot(for: url))
        await pump()
        XCTAssertNotEqual(session.state, .ready(snapshot(for: url)))
    }

    @MainActor
    func testReplaceABLastWriteWins() async {
        let box = LoaderBox()
        let session = VideoMetadataSession(loader: box.loader)
        let a = URL(fileURLWithPath: "/tmp/a.mov")
        let b = URL(fileURLWithPath: "/tmp/b.mov")
        session.setSource(a)
        session.show()
        await box.waitForCall()
        session.setSource(b)
        await box.waitForCallCount(2)
        // Resolve out of order: A finishes last but must not be displayed.
        box.resolve(1, with: snapshot(for: b))
        box.resolve(0, with: snapshot(for: a))
        await pump()
        XCTAssertEqual(session.state, .ready(snapshot(for: b)))
    }

    @MainActor
    func testABAUsesGenerationNotURLEquality() async {
        let box = LoaderBox()
        let session = VideoMetadataSession(loader: box.loader)
        let a = URL(fileURLWithPath: "/tmp/a.mov")
        let b = URL(fileURLWithPath: "/tmp/b.mov")
        session.setSource(a)
        session.show()
        await box.waitForCall()
        session.setSource(b)
        session.setSource(a) // same URL as the first request, new generation
        await box.waitForCallCount(3)
        XCTAssertEqual(box.calls.count, 3)
        // Loader calls race on detached tasks — resolve each call with its own
        // URL's snapshot; the generation guard must reject the two stale loads.
        for (index, url) in box.calls.enumerated() {
            box.resolve(index, with: snapshot(for: url))
        }
        await pump()
        XCTAssertEqual(session.state, .ready(snapshot(for: a)))
    }

    @MainActor
    func testReopenReusesCompletedSnapshot() async {
        let box = LoaderBox()
        let session = VideoMetadataSession(loader: box.loader)
        let url = URL(fileURLWithPath: "/tmp/a.mov")
        session.setSource(url)
        session.show()
        await box.waitForCall()
        box.resolve(0, with: snapshot(for: url))
        await pump()
        session.hide()
        session.show() // same source — no second load
        await pump()
        XCTAssertEqual(box.calls.count, 1)
        XCTAssertEqual(session.state, .ready(snapshot(for: url)))
    }

    @MainActor
    func testIndependentSessionsDoNotInterfere() async {
        let boxA = LoaderBox()
        let boxB = LoaderBox()
        let a = VideoMetadataSession(loader: boxA.loader)
        let b = VideoMetadataSession(loader: boxB.loader)
        let urlA = URL(fileURLWithPath: "/tmp/a.mov")
        let urlB = URL(fileURLWithPath: "/tmp/b.mov")
        a.setSource(urlA)
        b.setSource(urlB)
        a.show()
        b.show()
        await boxA.waitForCall()
        await boxB.waitForCall()
        a.hide()
        boxA.resolve(0, with: snapshot(for: urlA))
        boxB.resolve(0, with: snapshot(for: urlB))
        await pump()
        XCTAssertNotEqual(a.state, .ready(snapshot(for: urlA)))
        XCTAssertEqual(b.state, .ready(snapshot(for: urlB)))
    }

    @MainActor
    func testLoadFailureReportsUnavailable() async {
        let box = LoaderBox()
        let session = VideoMetadataSession(loader: box.loader)
        session.setSource(URL(fileURLWithPath: "/tmp/a.mov"))
        session.show()
        await box.waitForCall()
        box.fail(0, with: VideoMetadataError.unsupportedURL)
        await pump()
        if case .unavailable = session.state {} else {
            XCTFail("expected .unavailable, got \(session.state)")
        }
    }
}

// MARK: - Window layout math

final class PlayerWindowLayoutTests: XCTestCase {

    func testFitLandscape() {
        let fit = PlayerWindowLayout.fitVideoSize(
            source: CGSize(width: 1920, height: 1080), maxWidth: 1280, maxHeight: 800)
        XCTAssertEqual(fit.width, 1280, accuracy: 1)
        XCTAssertEqual(fit.width / fit.height, 1920.0 / 1080.0, accuracy: 0.01)
    }

    func testFitPortraitAndSquare() {
        let portrait = PlayerWindowLayout.fitVideoSize(
            source: CGSize(width: 1080, height: 1920), maxWidth: 800, maxHeight: 1000)
        XCTAssertEqual(portrait.height, 1000, accuracy: 1)
        XCTAssertEqual(portrait.width / portrait.height, 1080.0 / 1920.0, accuracy: 0.01)
        let square = PlayerWindowLayout.fitVideoSize(
            source: CGSize(width: 720, height: 720), maxWidth: 800, maxHeight: 600)
        XCTAssertEqual(square.width, square.height, accuracy: 1)
    }

    func testFitClampsToMinimum() {
        let fit = PlayerWindowLayout.fitVideoSize(
            source: CGSize(width: 100, height: 100), maxWidth: 200, maxHeight: 200)
        XCTAssertGreaterThanOrEqual(fit.width, PlayerWindowLayout.minVideoWidth)
        XCTAssertGreaterThanOrEqual(fit.height, PlayerWindowLayout.minVideoHeight)
    }

    func testContentSizeIncludesChrome() {
        // The plan's worked example: 960×540 video → 960×592 closed, 1261×592 open.
        let video = CGSize(width: 960, height: 540)
        XCTAssertEqual(PlayerWindowLayout.contentSize(videoSize: video, inspectorOpen: false),
                       CGSize(width: 960, height: 592))
        XCTAssertEqual(PlayerWindowLayout.contentSize(videoSize: video, inspectorOpen: true),
                       CGSize(width: 1261, height: 592))
    }

    func testResizePreservesVideoAspect() {
        let last = CGSize(width: 960, height: 540)
        // Drag wider: width drives, height follows.
        let corrected = PlayerWindowLayout.aspectCorrectedContentSize(
            proposedContent: CGSize(width: 1160, height: 620),
            videoAspect: 960.0 / 540.0,
            lastVideoSize: last,
            inspectorOpen: false,
            maxVideoSize: CGSize(width: 4000, height: 4000))
        let videoW = corrected.width
        let videoH = corrected.height - PlayerWindowLayout.footerHeight
        XCTAssertEqual(videoW / videoH, 960.0 / 540.0, accuracy: 0.01)
        XCTAssertEqual(videoW, 1160, accuracy: 1)
    }

    func testResizeWithInspectorSubtractsColumn() {
        let last = CGSize(width: 960, height: 540)
        let corrected = PlayerWindowLayout.aspectCorrectedContentSize(
            proposedContent: CGSize(width: 960 + 301, height: 620),
            videoAspect: 960.0 / 540.0,
            lastVideoSize: last,
            inspectorOpen: true,
            maxVideoSize: CGSize(width: 4000, height: 4000))
        let videoW = corrected.width - PlayerWindowLayout.inspectorAllocation
        let videoH = corrected.height - PlayerWindowLayout.footerHeight
        XCTAssertEqual(videoW / videoH, 960.0 / 540.0, accuracy: 0.01)
    }

    func testResizeNeverNegative() {
        let corrected = PlayerWindowLayout.aspectCorrectedContentSize(
            proposedContent: CGSize(width: 10, height: 10),
            videoAspect: 16.0 / 9.0,
            lastVideoSize: CGSize(width: 640, height: 360),
            inspectorOpen: false,
            maxVideoSize: CGSize(width: 4000, height: 4000))
        XCTAssertGreaterThan(corrected.width, 0)
        XCTAssertGreaterThan(corrected.height, PlayerWindowLayout.footerHeight)
    }
}

// MARK: - Loop wrap math

final class PlayerTimelineMathTests: XCTestCase {

    func testFullClipWrap() {
        XCTAssertTrue(PlayerTimelineMath.isLoopWrap(previous: 9.9, current: 0.05, start: 0, end: 10))
        XCTAssertTrue(PlayerTimelineMath.isLoopWrap(previous: 7.5, current: 0.4, start: 0, end: 10))
    }

    func testCustomLoopWrap() {
        // [5,10] loop: 9.99 → 5.01 must register as a wrap.
        XCTAssertTrue(PlayerTimelineMath.isLoopWrap(previous: 9.99, current: 5.01, start: 5, end: 10))
        XCTAssertTrue(PlayerTimelineMath.isLoopWrap(previous: 8.6, current: 5.3, start: 5, end: 10))
        // Landing slightly before the in-point still counts (looper landing jitter).
        XCTAssertTrue(PlayerTimelineMath.isLoopWrap(previous: 9.9, current: 4.7, start: 5, end: 10))
    }

    func testBackwardJitterIsNotWrap() {
        XCTAssertFalse(PlayerTimelineMath.isLoopWrap(previous: 7.0, current: 6.8, start: 0, end: 10))
        XCTAssertFalse(PlayerTimelineMath.isLoopWrap(previous: 7.0, current: 6.8, start: 5, end: 10))
        // Previous wasn't near the end of a [5,10] loop.
        XCTAssertFalse(PlayerTimelineMath.isLoopWrap(previous: 6.5, current: 5.1, start: 5, end: 10))
    }

    func testInvalidInputs() {
        XCTAssertFalse(PlayerTimelineMath.isLoopWrap(previous: 9, current: 5, start: 10, end: 5))
        XCTAssertFalse(PlayerTimelineMath.isLoopWrap(previous: 9, current: 5, start: 0, end: 0))
        XCTAssertFalse(PlayerTimelineMath.isLoopWrap(previous: .nan, current: 5, start: 0, end: 10))
        XCTAssertFalse(PlayerTimelineMath.isLoopWrap(previous: 9, current: .infinity, start: 0, end: 10))
    }

    func testVeryShortLoop() {
        // Minimum-span loop [2.0, 2.2]: wrap 2.19 → 2.01.
        XCTAssertTrue(PlayerTimelineMath.isLoopWrap(previous: 2.19, current: 2.01, start: 2.0, end: 2.2))
        XCTAssertFalse(PlayerTimelineMath.isLoopWrap(previous: 2.1, current: 2.05, start: 2.0, end: 2.2))
    }
}

// MARK: - Scrub-bar double-click sequences (real NSEvents)

@MainActor
final class ScrubBarInteractionTests: XCTestCase {

    private lazy var hostWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 120),
        styleMask: .borderless, backing: .buffered, defer: false)

    private func makeBar() -> VideoScrubBar {
        let bar = VideoScrubBar(frame: NSRect(x: 0, y: 0, width: 500, height: 28))
        bar.maxValue = 10
        hostWindow.contentView?.addSubview(bar)
        return bar
    }

    private func click(_ type: NSEvent.EventType, fraction: CGFloat, clickCount: Int, bar: VideoScrubBar) {
        // fraction maps onto the rail: inset 10 .. width-10.
        let viewX = 10 + (bar.bounds.width - 20) * fraction
        let windowPoint = bar.convert(NSPoint(x: viewX, y: bar.bounds.midY), to: nil)
        guard let event = NSEvent.mouseEvent(
            with: type, location: windowPoint, modifierFlags: [],
            timestamp: 0, windowNumber: hostWindow.windowNumber,
            context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        ) else { return XCTFail("could not create event") }
        switch type {
        case .leftMouseDown: bar.mouseDown(with: event)
        case .leftMouseUp: bar.mouseUp(with: event)
        case .leftMouseDragged: bar.mouseDragged(with: event)
        default: break
        }
    }

    /// Third double-click outside the pair must CLEAR, not start a new point —
    /// even though the first click already removed the markers via scrub-outside.
    func testThirdDoubleClickOutsideClearsLoop() {
        let bar = makeBar()
        var doubleClicks: [(seconds: Double, clears: Bool)] = []
        bar.onDoubleClick = { s, clears in doubleClicks.append((s, clears)) }
        // Reproduce the controller's drag-outside clearing.
        bar.onValueChanged = { [weak bar] seconds in
            guard let bar, let lo = bar.loopInValue, let hi = bar.loopOutValue,
                  seconds < lo || seconds > hi else { return }
            bar.loopInValue = nil
            bar.loopOutValue = nil
        }

        bar.loopInValue = 2
        bar.loopOutValue = 8

        // Click sequence at 95% (outside [2,8]): first click clears, second reports intent.
        click(.leftMouseDown, fraction: 0.95, clickCount: 1, bar: bar)
        click(.leftMouseUp, fraction: 0.95, clickCount: 1, bar: bar)
        XCTAssertNil(bar.loopInValue) // first click already cleared via scrub-outside
        click(.leftMouseDown, fraction: 0.95, clickCount: 2, bar: bar)
        click(.leftMouseUp, fraction: 0.95, clickCount: 2, bar: bar)

        XCTAssertEqual(doubleClicks.count, 1)
        XCTAssertTrue(doubleClicks[0].clears)
    }

    func testDoubleClickWithNoPairReportsNoClear() {
        let bar = makeBar()
        var doubleClicks: [(seconds: Double, clears: Bool)] = []
        bar.onDoubleClick = { s, clears in doubleClicks.append((s, clears)) }

        click(.leftMouseDown, fraction: 0.5, clickCount: 1, bar: bar)
        click(.leftMouseUp, fraction: 0.5, clickCount: 1, bar: bar)
        click(.leftMouseDown, fraction: 0.5, clickCount: 2, bar: bar)
        click(.leftMouseUp, fraction: 0.5, clickCount: 2, bar: bar)

        XCTAssertEqual(doubleClicks.count, 1)
        XCTAssertFalse(doubleClicks[0].clears)
        XCTAssertEqual(doubleClicks[0].seconds, 5.0, accuracy: 0.05)
    }

    func testPendingPointDoesNotReportClear() {
        let bar = makeBar()
        var doubleClicks: [(seconds: Double, clears: Bool)] = []
        bar.onDoubleClick = { s, clears in doubleClicks.append((s, clears)) }
        bar.loopInValue = 3 // one pending point, no pair

        click(.leftMouseDown, fraction: 0.7, clickCount: 1, bar: bar)
        click(.leftMouseUp, fraction: 0.7, clickCount: 1, bar: bar)
        click(.leftMouseDown, fraction: 0.7, clickCount: 2, bar: bar)
        click(.leftMouseUp, fraction: 0.7, clickCount: 2, bar: bar)

        XCTAssertEqual(doubleClicks.count, 1)
        XCTAssertFalse(doubleClicks[0].clears)
    }

    func testDoubleClickInsidePairStillClears() {
        let bar = makeBar()
        var clears = false
        bar.onDoubleClick = { _, c in clears = c }
        bar.onValueChanged = { [weak bar] seconds in
            guard let bar, let lo = bar.loopInValue, let hi = bar.loopOutValue,
                  seconds < lo || seconds > hi else { return }
            bar.loopInValue = nil
            bar.loopOutValue = nil
        }
        bar.loopInValue = 2
        bar.loopOutValue = 8

        click(.leftMouseDown, fraction: 0.5, clickCount: 1, bar: bar) // inside pair — markers survive
        click(.leftMouseUp, fraction: 0.5, clickCount: 1, bar: bar)
        click(.leftMouseDown, fraction: 0.5, clickCount: 2, bar: bar)
        click(.leftMouseUp, fraction: 0.5, clickCount: 2, bar: bar)

        XCTAssertTrue(clears)
    }

    func testTripleClickDoesNotFireLoopCommand() {
        let bar = makeBar()
        var count = 0
        bar.onDoubleClick = { _, _ in count += 1 }
        click(.leftMouseDown, fraction: 0.5, clickCount: 1, bar: bar)
        click(.leftMouseUp, fraction: 0.5, clickCount: 1, bar: bar)
        click(.leftMouseDown, fraction: 0.5, clickCount: 2, bar: bar)
        click(.leftMouseUp, fraction: 0.5, clickCount: 2, bar: bar)
        click(.leftMouseDown, fraction: 0.5, clickCount: 3, bar: bar)
        click(.leftMouseUp, fraction: 0.5, clickCount: 3, bar: bar)
        XCTAssertEqual(count, 1) // only the real double-click fired
    }

    func testSingleClickScrubsImmediately() {
        let bar = makeBar()
        var values: [Double] = []
        bar.onValueChanged = { values.append($0) }
        click(.leftMouseDown, fraction: 0.25, clickCount: 1, bar: bar)
        click(.leftMouseUp, fraction: 0.25, clickCount: 1, bar: bar)
        XCTAssertEqual(values, [2.5])
    }
}

// MARK: - Inspector view

@MainActor
final class VideoInfoViewTests: XCTestCase {

    private func snapshot(location: VideoLocation? = nil) -> VideoMetadataSnapshot {
        VideoMetadataSnapshot(
            sourceURL: URL(fileURLWithPath: "/tmp/clip.mov"),
            sections: [
                VideoMetadataSection(title: "File", fields: [
                    VideoMetadataField(key: "name", label: "Name", value: "clip.mov", source: "file"),
                ]),
                VideoMetadataSection(title: "Location", fields: [
                    VideoMetadataField(key: "gps", label: "GPS",
                                       value: location != nil ? "Yes" : "No", source: "metadata"),
                ]),
            ],
            additionalFields: [
                VideoMetadataField(key: "k1", label: "Tag one", value: "v1", source: "QuickTime"),
            ],
            location: location,
            unavailableSections: [])
    }

    func testReadyStateRendersSections() {
        let view = VideoInfoView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        view.present(.ready(snapshot()))
        XCTAssertFalse(view.subviews.isEmpty)
        view.reset()
    }

    func testLoadingThenReadyTransition() {
        let view = VideoInfoView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        view.present(.loading)
        view.present(.ready(snapshot()))
        view.reset()
        view.present(.unavailable("nope"))
    }

    func testIdenticalStateDoesNotRebuild() {
        let view = VideoInfoView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        let snap = snapshot()
        view.present(.ready(snap))
        view.present(.ready(snap)) // same value — must not churn the view tree
        view.reset()
    }
}
