import XCTest
@testable import RemoteDesk

final class DisplayFitTests: XCTestCase {
    func mode(_ w: Int, _ h: Int, scale: Int = 1, hz: Double = 60) -> DisplayModeCandidate {
        DisplayModeCandidate(width: w, height: h, pixelWidth: w * scale, pixelHeight: h * scale, refreshRate: hz)
    }

    func testPicksMatchingAspect() {
        let modes = [mode(1920, 1080, scale: 2), mode(1680, 1050, scale: 2), mode(1440, 900, scale: 2), mode(2560, 1440)]
        let best = DisplayFit.bestMode(among: modes, current: modes[0], targetWidth: 1440, targetHeight: 900, preferHiDPI: true)
        XCTAssertEqual(best, mode(1440, 900, scale: 2))
    }

    func testNoSwitchWhenCurrentAlreadyBest() {
        let modes = [mode(1920, 1080, scale: 2), mode(1280, 720, scale: 2)]
        XCTAssertNil(DisplayFit.bestMode(among: modes, current: modes[0], targetWidth: 1920, targetHeight: 1080, preferHiDPI: true))
    }

    func testNotchedMacBookTarget() {
        // MacBook Air 13" full screen below the notch: 1470x924 pt (aspect 1.59)
        let modes = [mode(1920, 1080, scale: 2), mode(1680, 1050, scale: 2), mode(1440, 900, scale: 2), mode(1280, 800, scale: 2)]
        let best = DisplayFit.bestMode(among: modes, current: modes[0], targetWidth: 1470, targetHeight: 924, preferHiDPI: true)
        XCTAssertEqual(best, mode(1440, 900, scale: 2))
    }

    func testPrefersHiDPIAndRefresh() {
        let modes = [mode(1440, 900, scale: 1, hz: 60), mode(1440, 900, scale: 2, hz: 60), mode(1440, 900, scale: 2, hz: 120)]
        let best = DisplayFit.bestMode(among: modes, current: mode(1920, 1080), targetWidth: 1440, targetHeight: 900, preferHiDPI: true)
        XCTAssertEqual(best, mode(1440, 900, scale: 2, hz: 120))
    }

    func testDoesNotShrinkToTinyHiDPIMode() {
        // 1080p monitor on the host, Retina MacBook client.
        let modes = [mode(1920, 1080), mode(960, 540, scale: 2), mode(1600, 900), mode(1280, 720)]
        let best = DisplayFit.bestMode(among: modes, current: modes[0], targetWidth: 1470, targetHeight: 924, preferHiDPI: true)
        XCTAssertEqual(best, mode(1600, 900))
    }

    func testStreamSizeCapsAndFits() {
        XCTAssertTrue(DisplayFit.streamSize(sourceWidth: 3840, sourceHeight: 2160, maxDimension: 2560) == (2560, 1440))
        XCTAssertTrue(DisplayFit.streamSize(sourceWidth: 2880, sourceHeight: 1800, maxDimension: 2560, fitWidth: 1920, fitHeight: 1200) == (1920, 1200))
        XCTAssertTrue(DisplayFit.streamSize(sourceWidth: 1920, sourceHeight: 1080, maxDimension: 2560, fitWidth: 2940, fitHeight: 1848) == (1920, 1080))
        let odd = DisplayFit.streamSize(sourceWidth: 3024, sourceHeight: 1964, maxDimension: 2560, fitWidth: 2940, fitHeight: 1848)
        XCTAssertEqual(odd.width % 2, 0); XCTAssertEqual(odd.height % 2, 0)
        XCTAssertLessThanOrEqual(odd.height, 1848)
    }
}
