import AppKit
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
