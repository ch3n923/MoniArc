import XCTest
@testable import MoniArc

final class DisplayGeometryTests: XCTestCase {
    func testSafeNotchUsesExactOverlayFrames() {
        let display = snapshot(notchWidth: 185)

        let collapsed = PanelGeometry.resolve(display: display, preference: .automatic, expanded: false)
        let expanded = PanelGeometry.resolve(display: display, preference: .automatic, expanded: true)

        XCTAssertEqual(collapsed.placement, .overlay)
        XCTAssertEqual(collapsed.frame.size, CGSize(width: 512, height: 138))
        XCTAssertEqual(expanded.frame.size, CGSize(width: 512, height: 244))
        XCTAssertEqual(collapsed.frame.maxY, expanded.frame.maxY)
        XCTAssertEqual(collapsed.physicalNotchWidth, 185)
        XCTAssertTrue(collapsed.usesWingLayout)
    }

    func testFloatingFramesRemainTopAnchoredWithNegativeScreenOrigin() {
        var display = snapshot(notchWidth: nil)
        display.frame = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        display.visibleFrame = CGRect(x: -1920, y: 200, width: 1920, height: 1055)

        let collapsed = PanelGeometry.resolve(display: display, preference: .automatic, expanded: false)
        let expanded = PanelGeometry.resolve(display: display, preference: .automatic, expanded: true)

        XCTAssertEqual(collapsed.placement, .floating)
        XCTAssertEqual(collapsed.frame.size, CGSize(width: 512, height: 240))
        XCTAssertEqual(expanded.frame.size, CGSize(width: 512, height: 316))
        XCTAssertEqual(collapsed.frame.maxY, expanded.frame.maxY)
        XCTAssertEqual(collapsed.frame.maxY, display.frame.maxY - display.topChromeHeight - 8)
    }

    func test218PointNotchIsAllowedAndWiderNotchFallsBack() {
        let exact = PanelGeometry.resolve(display: snapshot(notchWidth: 218), preference: .automatic, expanded: false)
        let tooWide = PanelGeometry.resolve(display: snapshot(notchWidth: 218.5), preference: .overlay, expanded: false)

        XCTAssertEqual(exact.placement, .overlay)
        XCTAssertEqual(tooWide.placement, .floating)
        XCTAssertTrue(tooWide.fellBackForSafety)
    }

    func testTooTallOrIncompleteNotchFallsBackButFlatManualOverlayRemainsAvailable() {
        var tooTall = snapshot(notchWidth: 185)
        tooTall.safeAreaTop = 33
        XCTAssertEqual(PanelGeometry.resolve(display: tooTall, preference: .automatic, expanded: false).placement, .floating)

        var incomplete = snapshot(notchWidth: 185)
        incomplete.auxiliaryTopRightArea = nil
        XCTAssertEqual(PanelGeometry.resolve(display: incomplete, preference: .overlay, expanded: false).placement, .floating)

        let flatOverlay = PanelGeometry.resolve(display: snapshot(notchWidth: nil), preference: .overlay, expanded: false)
        XCTAssertEqual(flatOverlay.placement, .overlay)
        XCTAssertFalse(flatOverlay.usesWingLayout)
        XCTAssertEqual(flatOverlay.frame.size, CGSize(width: 512, height: 136))
    }

    func testTopEdgePointerHitUsesClosedUpperBoundAndSmallOvershoot() {
        let rect = CGRect(x: 100, y: 900, width: 304, height: 34)

        XCTAssertTrue(PointerHitTesting.contains(CGPoint(x: 252, y: rect.maxY), in: rect))
        XCTAssertTrue(PointerHitTesting.contains(CGPoint(x: 252, y: rect.maxY + 1.5), in: rect))
        XCTAssertFalse(PointerHitTesting.contains(CGPoint(x: 252, y: rect.maxY + 2.5), in: rect))
        XCTAssertFalse(PointerHitTesting.contains(CGPoint(x: rect.maxX + 0.5, y: rect.maxY), in: rect))
    }

    func testCollapsedOverlayHoverRegionExcludesGlowAndInsetsVisibleSurface() {
        let panelFrame = CGRect(x: 500, y: 844, width: 512, height: 138)

        let region = PointerHitTesting.hoverRegion(
            panelFrame: panelFrame,
            placement: .overlay,
            phase: .collapsed
        )

        XCTAssertEqual(region, CGRect(x: 612, y: 951, width: 288, height: 28))
        XCTAssertFalse(PointerHitTesting.contains(CGPoint(x: region.midX, y: panelFrame.minY), in: region))
    }

    func testCollapsedFloatingHoverRegionTracksVisibleSurfaceInsideBothGlowMargins() {
        let panelFrame = CGRect(x: 500, y: 709, width: 512, height: 240)

        let region = PointerHitTesting.hoverRegion(
            panelFrame: panelFrame,
            placement: .floating,
            phase: .expandPending
        )

        XCTAssertEqual(region, CGRect(x: 612, y: 816, width: 288, height: 26))
    }

    func testExpandedHoverRegionKeepsTheWholeInteractiveSurfaceAvailable() {
        let panelFrame = CGRect(x: 500, y: 738, width: 512, height: 244)

        let region = PointerHitTesting.hoverRegion(
            panelFrame: panelFrame,
            placement: .overlay,
            phase: .expanded
        )

        XCTAssertEqual(region, CGRect(x: 604, y: 842, width: 304, height: 140))
    }

    private func snapshot(notchWidth: CGFloat?) -> DisplaySnapshot {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        if let notchWidth {
            let leftMax = frame.midX - notchWidth / 2
            let rightMin = frame.midX + notchWidth / 2
            return DisplaySnapshot(
                identifier: "test",
                frame: frame,
                visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949),
                safeAreaTop: 32,
                statusBarThickness: 24,
                auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: leftMax, height: 32),
                auxiliaryTopRightArea: CGRect(x: rightMin, y: 950, width: frame.maxX - rightMin, height: 32),
                backingScaleFactor: 2
            )
        }
        return DisplaySnapshot(
            identifier: "flat",
            frame: frame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 957),
            safeAreaTop: 0,
            statusBarThickness: 24,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            backingScaleFactor: 2
        )
    }
}
