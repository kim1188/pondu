import XCTest
@testable import FeatureSession

final class PhotoSizingTests: XCTestCase {
    func testLandscapeScalesLongSideTo1600() {
        let s = PhotoSizing.targetSize(width: 4032, height: 3024, longSide: 1600)
        XCTAssertEqual(s.width, 1600)
        XCTAssertEqual(s.height, 1200)
    }

    func testPortraitScalesLongSideTo480() {
        let s = PhotoSizing.targetSize(width: 3024, height: 4032, longSide: 480)
        XCTAssertEqual(s.height, 480)
        XCTAssertEqual(s.width, 360)
    }

    func testNeverUpscales() {
        let s = PhotoSizing.targetSize(width: 800, height: 600, longSide: 1600)
        XCTAssertEqual(s.width, 800)
        XCTAssertEqual(s.height, 600)
        XCTAssertEqual(PhotoSizing.maxPixel(originalWidth: 800, originalHeight: 600, limit: 1600), 800)
    }

    func testMaxPixelCapsAtLimit() {
        XCTAssertEqual(PhotoSizing.maxPixel(originalWidth: 4032, originalHeight: 3024, limit: 1600), 1600)
        XCTAssertEqual(PhotoSizing.maxPixel(originalWidth: 4032, originalHeight: 3024, limit: 480), 480)
    }

    func testZeroSize() {
        let s = PhotoSizing.targetSize(width: 0, height: 0, longSide: 1600)
        XCTAssertEqual(s.width, 0)
    }

    func testByteLimitsFromSRD() {
        XCTAssertEqual(PhotoSizing.fullMaxBytes, 400_000)
        XCTAssertEqual(PhotoSizing.thumbMaxBytes, 60_000)
        XCTAssertEqual(PhotoSizing.qualityLadder, PhotoSizing.qualityLadder.sorted(by: >))
    }

    func testStoragePathsAreLowercase() {
        let user = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000001")!
        let session = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000002")!
        XCTAssertEqual(PhotoPaths.full(userID: user, sessionID: session),
                       "abcdef12-0000-0000-0000-000000000001/abcdef12-0000-0000-0000-000000000002/full.heic")
        XCTAssertEqual(PhotoPaths.thumb(userID: user, sessionID: session),
                       "abcdef12-0000-0000-0000-000000000001/abcdef12-0000-0000-0000-000000000002/thumb.heic")
    }
}
