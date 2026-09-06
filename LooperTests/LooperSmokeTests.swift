import AppKit
import XCTest
@testable import Looper

final class LooperSmokeTests: XCTestCase {
    func testSmoke() {
        XCTAssertTrue(true)
    }

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
        let loaded = WindowFrameStore.loadFrame(for: nonExistentURL)
        XCTAssertNil(loaded)
    }

    func testAssetCacheStoreAndRetrieveProperties() {
        let url = URL(fileURLWithPath: "/tmp/looper_cache_test.mp4")

        AssetCache.storeNativeSize(CGSize(width: 1920, height: 1080), for: url)
        XCTAssertEqual(AssetCache.cachedNativeSize(for: url), CGSize(width: 1920, height: 1080))

        let poster = NSImage(size: NSSize(width: 100, height: 100))
        AssetCache.storePoster(poster, for: url)
        XCTAssertNotNil(AssetCache.cachedPoster(for: url))
    }

    func testAssetCacheLoadFrameRateAndHDR() {
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

    func testLocalVideoURLFiltering() {
        XCTAssertTrue(LocalVideoURL.isPlayableFile(URL(fileURLWithPath: "/tmp/sample.mp4")))
        XCTAssertTrue(LocalVideoURL.isPlayableFile(URL(fileURLWithPath: "/tmp/sample.mov")))
        XCTAssertTrue(LocalVideoURL.isPlayableFile(URL(fileURLWithPath: "/tmp/sample.m4v")))
        XCTAssertTrue(LocalVideoURL.isPlayableFile(URL(fileURLWithPath: "/tmp/sample.mkv")))
        XCTAssertTrue(LocalVideoURL.isPlayableFile(URL(fileURLWithPath: "/tmp/sample.MP4")))
        XCTAssertTrue(LocalVideoURL.isPlayableFile(URL(fileURLWithPath: "/tmp/sample.MOV")))

        XCTAssertFalse(LocalVideoURL.isPlayableFile(URL(fileURLWithPath: "/tmp/sample.txt")))
        XCTAssertFalse(LocalVideoURL.isPlayableFile(URL(fileURLWithPath: "/tmp/sample.png")))
        XCTAssertFalse(LocalVideoURL.isPlayableFile(URL(string: "https://example.com/sample.mp4")!))

        let mixed = [
            URL(fileURLWithPath: "/tmp/valid.mp4"),
            URL(fileURLWithPath: "/tmp/invalid.txt"),
            URL(string: "https://example.com/stream.mov")!,
            URL(fileURLWithPath: "/tmp/valid.m4v")
        ]
        let filtered = LocalVideoURL.onlyPlayableFiles(mixed)
        XCTAssertEqual(filtered.count, 2)
        XCTAssertEqual(filtered[0].path, "/tmp/valid.mp4")
        XCTAssertEqual(filtered[1].path, "/tmp/valid.m4v")
    }
}
