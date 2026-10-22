import CoreGraphics
import XCTest
@testable import OzCore

final class StripTests: XCTestCase {
    // 1000pt tall viewport starting at y=50 (menu bar), gap 10.
    let params = LayoutParams(viewport: CGRect(x: 10, y: 50, width: 1000, height: 1000),
                              hardTop: 40, hardBottom: 1100, gap: 10, minVisible: 80)
    let vh: CGFloat = 1000

    func makeStrip(_ heights: [CGFloat]) -> Strip {
        let s = Strip()
        for (i, h) in heights.enumerated() {
            s.insert(WinID(i + 1), height: h, anchor: nil, position: .end)
        }
        return s
    }

    func frames(_ s: Strip, scroll: CGFloat, minHeights: [WinID: CGFloat] = [:]) -> [WinID: Placement] {
        Dictionary(uniqueKeysWithValues: s.layout(params, scroll: scroll, minHeights: minHeights).map { ($0.id, $0.placement) })
    }

    func testStacksRowsVertically() {
        let s = makeStrip([495, 495, 495])
        let f = frames(s, scroll: 0)
        XCTAssertEqual(f[1], .frame(CGRect(x: 10, y: 50, width: 1000, height: 495)))
        XCTAssertEqual(f[2], .frame(CGRect(x: 10, y: 555, width: 1000, height: 495)))
        // Third row starts at 1060 < hardBottom -> partially visible below.
        XCTAssertEqual(f[3], .frame(CGRect(x: 10, y: 1060, width: 1000, height: 495)))
    }

    func testHalfRatioFillsViewport() {
        let h = Strip.height(forRatio: 0.5, viewportHeight: vh, gap: 10)
        XCTAssertEqual(h * 2 + 10, vh)
    }

    func testScrollParksAndShrinks() {
        let s = makeStrip([495, 495, 495])
        // Scrolled so row 1 has only 45pt left above the viewport -> parked (below minVisible).
        var f = frames(s, scroll: 460)
        XCTAssertEqual(f[1], .park)
        // Scrolled a little: row 1 pinned to hardTop and shrunk.
        f = frames(s, scroll: 100)
        XCTAssertEqual(f[1], .frame(CGRect(x: 10, y: 40, width: 1000, height: 405)))
        // A window that can't get that small gets parked instead.
        f = frames(s, scroll: 100, minHeights: [1: 450])
        XCTAssertEqual(f[1], .park)
    }

    func testScrollAreaCutsOffAtItsBottom() {
        // Right half of the screen, ending at y=700 (above the screen bottom).
        var p = LayoutParams(viewport: CGRect(x: 510, y: 50, width: 500, height: 640),
                             hardTop: 40, hardBottom: 700, gap: 10, topOverflow: .slide, minVisible: 80, cutBottom: true)
        let s = makeStrip([315, 315, 315])
        var f = Dictionary(uniqueKeysWithValues: s.layout(p, scroll: 0).map { ($0.id, $0.placement) })
        XCTAssertEqual(f[1], .frame(CGRect(x: 510, y: 50, width: 500, height: 315)))
        XCTAssertEqual(f[2], .frame(CGRect(x: 510, y: 375, width: 500, height: 315)))
        // Starts at 700 = the area's bottom: out of view.
        XCTAssertEqual(f[3], .park)
        // Scrolled half a row: the second row crosses the bottom edge and is drawn cut off.
        f = Dictionary(uniqueKeysWithValues: s.layout(p, scroll: -100).map { ($0.id, $0.placement) })
        XCTAssertEqual(f[2], .overflow(CGRect(x: 510, y: 475, width: 500, height: 315)))
        // Shrink mode keeps only the part inside the area.
        p.topOverflow = .shrink
        f = Dictionary(uniqueKeysWithValues: s.layout(p, scroll: -100).map { ($0.id, $0.placement) })
        XCTAssertEqual(f[2], .frame(CGRect(x: 510, y: 475, width: 500, height: 225)))
        // Without cutBottom (area reaching the screen bottom) windows run off as before.
        p.cutBottom = false
        p.hardBottom = 1100
        f = Dictionary(uniqueKeysWithValues: s.layout(p, scroll: -100).map { ($0.id, $0.placement) })
        XCTAssertEqual(f[2], .frame(CGRect(x: 510, y: 475, width: 500, height: 315)))
    }

    func testDroppingBetweenRowsAndBesideAWindow() {
        let s = makeStrip([300, 300, 300])   // rows: [1] [2] [3]
        // Window 3 dragged above row 2.
        s.remove(3)
        s.insertRow(3, height: 300, before: 2)
        XCTAssertEqual(s.rows.map(\.windows), [[1], [3], [2]])
        // Window 1 dropped on the right of window 2: they share a row.
        s.remove(1)
        XCTAssertTrue(s.insertBeside(1, anchor: 2, right: true))
        XCTAssertEqual(s.rows.map(\.windows), [[3], [2, 1]])
        // ...and to the end of the strip.
        s.remove(3)
        s.insertRow(3, height: 300, before: nil)
        XCTAssertEqual(s.rows.map(\.windows), [[2, 1], [3]])
        XCTAssertFalse(s.insertBeside(4, anchor: 99, right: false))
    }

    func testSlideModeReportsOverflow() {
        var p = params
        p.topOverflow = .slide
        let s = makeStrip([495, 495])
        let f = Dictionary(uniqueKeysWithValues: s.layout(p, scroll: 100).map { ($0.id, $0.placement) })
        XCTAssertEqual(f[1], .overflow(CGRect(x: 10, y: -50, width: 1000, height: 495)))
        XCTAssertEqual(f[2], .frame(CGRect(x: 10, y: 455, width: 1000, height: 495)))
        // Fully above the top is still parked.
        let g = Dictionary(uniqueKeysWithValues: s.layout(p, scroll: 600).map { ($0.id, $0.placement) })
        XCTAssertEqual(g[1], .park)
    }

    func testRowWithTwoPanels() {
        let s = makeStrip([495, 495])
        XCTAssertTrue(s.slurpIn(1))
        XCTAssertEqual(s.rows.count, 1)
        let f = frames(s, scroll: 0)
        XCTAssertEqual(f[1], .frame(CGRect(x: 10, y: 50, width: 495, height: 495)))
        XCTAssertEqual(f[2], .frame(CGRect(x: 515, y: 50, width: 495, height: 495)))
        XCTAssertTrue(s.barfOut(2))
        XCTAssertEqual(s.rows.map(\.windows), [[1], [2]])
    }

    func testWidthsWithinRow() {
        let s = makeStrip([495, 495, 495])
        s.slurpIn(1)  // row 0 = [1, 2]
        XCTAssertEqual(s.widthFraction(1)!, 0.5, accuracy: 0.001)
        XCTAssertTrue(s.setWidthFraction(1, 2.0 / 3))
        XCTAssertEqual(s.widthFraction(1)!, 2.0 / 3, accuracy: 0.001)
        let f = frames(s, scroll: 0)
        XCTAssertEqual(f[1], .frame(CGRect(x: 10, y: 50, width: 660, height: 495)))
        XCTAssertEqual(f[2], .frame(CGRect(x: 680, y: 50, width: 330, height: 495)))
        XCTAssertEqual(s.cycledWidthFraction(1, ratios: [1.0 / 3, 0.5, 2.0 / 3], forward: true)!, 1.0 / 3, accuracy: 0.001)
        s.equalizeRow(of: 2)
        XCTAssertEqual(s.widthFraction(2)!, 0.5, accuracy: 0.001)
        // Alone in a row: nothing to share.
        XCTAssertFalse(s.setWidthFraction(3, 0.5))
    }

    func testNarrowLoneWindowLeavesSpace() {
        let s = makeStrip([400, 300])
        // Narrowed alone: half width, the rest of the row stays empty, even with a narrow
        // window in the next row that would fit there.
        s.setLoneWidth(1, 0.5)
        s.setLoneWidth(2, 0.3)
        XCTAssertEqual(s.rows.map(\.windows), [[1], [2]])
        XCTAssertEqual(frames(s, scroll: 0)[1], .frame(CGRect(x: 10, y: 50, width: 500, height: 400)))
        // Back to full width.
        s.setLoneWidth(1, nil)
        XCTAssertEqual(frames(s, scroll: 0)[1], .frame(CGRect(x: 10, y: 50, width: 1000, height: 400)))
    }

    func testNarrowLoneWindowKeepsItsPlace() {
        let s = makeStrip([400])
        // Narrowed from its left edge: it sits on the right of the row.
        s.setLoneWidth(1, 0.4)
        s.setLoneOffset(1, 0.6)
        XCTAssertEqual(frames(s, scroll: 0)[1], .frame(CGRect(x: 610, y: 50, width: 400, height: 400)))
        // Wider again: it stays where it is as far as it fits, then moves left.
        s.setLoneWidth(1, 0.5)
        XCTAssertEqual(frames(s, scroll: 0)[1], .frame(CGRect(x: 510, y: 50, width: 500, height: 400)))
        // In the middle.
        s.setLoneOffset(1, 0.25)
        XCTAssertEqual(frames(s, scroll: 0)[1], .frame(CGRect(x: 260, y: 50, width: 500, height: 400)))
        // Full width forgets the place.
        s.setLoneWidth(1, nil)
        XCTAssertNil(s.widthOffsets[1])
        XCTAssertEqual(frames(s, scroll: 0)[1], .frame(CGRect(x: 10, y: 50, width: 1000, height: 400)))
    }

    func testMovingIntoARowWithRoom() {
        let s = makeStrip([400, 300, 300])          // rows: [1] [2] [3]
        s.setLoneWidth(1, 0.5)                      // 1 takes the left half of its row
        s.setLoneWidth(3, 0.4)
        // 3 (0.4) moves up past 2, which is full width: no room there.
        XCTAssertFalse(s.joinIfFits(3, by: -1))
        s.moveVertical(3, by: -1)                   // [1] [3] [2]
        // Now the row above holds 1 with half the row free: 3 joins it, on the right.
        s.setLoneOffset(3, 0.6)
        XCTAssertTrue(s.joinIfFits(3, by: -1))
        XCTAssertEqual(s.rows.map(\.windows), [[1, 3], [2]])
        // They share the row 0.5 : 0.4 (990 pt after the gap).
        let f = frames(s, scroll: 0)
        XCTAssertEqual(f[1], .frame(CGRect(x: 10, y: 50, width: 550, height: 400)))
        XCTAssertEqual(f[3], .frame(CGRect(x: 570, y: 50, width: 440, height: 400)))
        // Moving on up leaves the row again (into a row of its own above it).
        XCTAssertFalse(s.joinIfFits(3, by: -1))
        s.moveVertical(3, by: -1)
        XCTAssertEqual(s.rows.map(\.windows), [[3], [1], [2]])
        // A full-width window never fits anywhere.
        XCTAssertFalse(s.joinIfFits(2, by: -1))
    }

    func testJoinRows() {
        let s = makeStrip([300, 300, 300])
        XCTAssertTrue(s.joinVertical(2, by: -1))
        XCTAssertEqual(s.rows.map(\.windows), [[1, 2], [3]])
        XCTAssertTrue(s.joinVertical(1, by: 1))
        XCTAssertEqual(s.rows.map(\.windows), [[2], [1, 3]])
        XCTAssertFalse(s.joinVertical(2, by: -1))
        XCTAssertTrue(s.joinVertical(2, by: 1))
        XCTAssertEqual(s.rows.map(\.windows), [[2, 1, 3]])
    }

    func testRemoveFocusesNeighbor() {
        let s = makeStrip([300, 300, 300])
        s.focused = 2
        XCTAssertEqual(s.remove(2), 3)
        XCTAssertEqual(s.focused, 3)
        XCTAssertEqual(s.remove(3), 1)
    }

    func testMoveAndNeighbors() {
        let s = makeStrip([300, 300, 300])
        XCTAssertTrue(s.moveVertical(1, by: 1))
        XCTAssertEqual(s.windowIDs, [2, 1, 3])
        XCTAssertFalse(s.moveVertical(3, by: 1))
        XCTAssertEqual(s.neighbor(of: 1, .down), 3)
        XCTAssertEqual(s.neighbor(of: 1, .up), 2)
        XCTAssertNil(s.neighbor(of: 1, .left))
    }

    func testRevealAndSnap() {
        let s = makeStrip([495, 495, 495, 495])
        // Row 3 (top 1010) needs scrolling to 1010+495-1000 = 505.
        XCTAssertEqual(s.scrollToReveal(3, viewportHeight: vh, gap: 10), 505)
        s.scrollY = 900
        XCTAssertEqual(s.scrollToReveal(2, viewportHeight: vh, gap: 10), 505)
        // Row tops, capped at max scroll (content 2010 - 1000).
        XCTAssertEqual(s.snapTargets(viewportHeight: vh, gap: 10), [0, 505, 1010])
    }

    func testMagneticSnapBringsCutWindowsIn() {
        // Rows at 0-495, 505-1000, 1010-1505, 1515-2010; screen 1000 tall, max scroll 1010.
        let s = makeStrip([495, 495, 495, 495])
        // At 300 row 0 is cut at the top (0) and row 2 at the bottom (1505 - 1000 = 505).
        // Still: the nearer one; moving: the side it moves towards.
        XCTAssertEqual(s.snapTarget(from: 300, velocity: 0, viewportHeight: vh, gap: 10), 505)
        XCTAssertEqual(s.snapTarget(from: 200, velocity: 0, viewportHeight: vh, gap: 10), 0)
        XCTAssertEqual(s.snapTarget(from: 200, velocity: 200, viewportHeight: vh, gap: 10), 505)
        XCTAssertEqual(s.snapTarget(from: 400, velocity: -200, viewportHeight: vh, gap: 10), 0)
        // Nothing cut (both edges on whole windows): stays.
        XCTAssertEqual(s.snapTarget(from: 505, velocity: 0, viewportHeight: vh, gap: 10), 505)
        // Only the bottom one cut: its bottom goes to the bottom edge, not its top to the top.
        let two = makeStrip([300, 900])
        XCTAssertEqual(two.snapTarget(from: 0, velocity: 0, viewportHeight: vh, gap: 10), 210)
        // A window taller than the screen isn't pulled to.
        let tall = makeStrip([400, 1500, 400])
        XCTAssertEqual(tall.snapTarget(from: 900, velocity: 0, viewportHeight: vh, gap: 10), 900)
    }

    func testFreeScrollSnapsOnlyNearEdges() {
        let s = makeStrip([495, 495, 495, 495])  // content 2010, max scroll 1010
        // Released far from any edge: stays where the glide ends.
        XCTAssertEqual(s.restingScroll(from: 250, velocity: 0, viewportHeight: vh, gap: 10, snapDistance: 60), 250)
        // Close to row 1's top (505): snaps to it.
        XCTAssertEqual(s.restingScroll(from: 470, velocity: 0, viewportHeight: vh, gap: 10, snapDistance: 60), 505)
        // Momentum carries it on: 100 + 1000*0.25 = 350, then free.
        XCTAssertEqual(s.restingScroll(from: 100, velocity: 1000, viewportHeight: vh, gap: 10, snapDistance: 60), 350)
        // Never past the ends.
        XCTAssertEqual(s.restingScroll(from: 900, velocity: 4000, viewportHeight: vh, gap: 10, snapDistance: 60), 1010)
        // Bottom edges count too: row 2 bottom (1010+495) on the screen bottom = 505 (same as row 1 top here).
        XCTAssertTrue(s.edgeTargets(viewportHeight: vh, gap: 10).contains(505))
        XCTAssertEqual(s.restingScroll(from: 300, velocity: 0, viewportHeight: vh, gap: 10, snapDistance: 0), 300)
    }

    func testCycleHeight() {
        let s = makeStrip([495])
        let ratios: [CGFloat] = [1.0 / 3, 0.5, 2.0 / 3, 1]
        XCTAssertEqual(s.cycledHeight(1, ratios: ratios, viewportHeight: vh, gap: 10, forward: true), 663)
        s.rows[0].height = 1000
        XCTAssertEqual(s.cycledHeight(1, ratios: ratios, viewportHeight: vh, gap: 10, forward: true), 327)
        XCTAssertEqual(s.cycledHeight(1, ratios: ratios, viewportHeight: vh, gap: 10, forward: false), 663)
    }

    func testInsertBelowFocused() {
        let s = makeStrip([300, 300])
        s.insert(9, height: 300, anchor: 1, position: .below)
        XCTAssertEqual(s.windowIDs, [1, 9, 2])
        s.insert(8, height: 300, anchor: 2, position: .above)
        XCTAssertEqual(s.windowIDs, [1, 9, 8, 2])
    }

    func testTopVisibleRow() {
        let s = makeStrip([495, 495, 495])
        XCTAssertEqual(s.topVisibleRow(scroll: 505, viewportHeight: vh, gap: 10), 1)
        XCTAssertEqual(s.topVisibleRow(scroll: 300, viewportHeight: vh, gap: 10), 1)
    }
}
