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

        AssetCache.storeFPS(60.0, for: url)
        XCTAssertEqual(AssetCache.cachedFPS(for: url), 60.0)

        AssetCache.storeHDR(true, for: url)
        XCTAssertEqual(AssetCache.cachedHDR(for: url), true)
    }
}

