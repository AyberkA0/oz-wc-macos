import CoreGraphics

/// Where in the strip a window dropped in the zone goes.
public enum DropSlot: Equatable {
    /// A row of its own just above the row holding this window (nil: after the last row).
    case row(before: WinID?)
    /// In this window's row, on its right or left.
    case beside(WinID, right: Bool)
}

extension Strip {
    /// The slot a window dragged to `p` (inside the zone) would take, and the split line that
    /// shows it: beside a window when the cursor is near its left or right edge (a quarter of
    /// its width, at most 160 pt), otherwise between the rows above or below the cursor (above
    /// the row under it in its upper half). nil when it would land where it already is.
    public func dropSlot(at p: CGPoint, dragging id: WinID, params lp: LayoutParams,
                         minHeights: [WinID: CGFloat] = [:], lineThickness t: CGFloat = 6) -> (slot: DropSlot, line: CGRect)? {
        let vp = lp.viewport, gap = lp.gap
        guard !rows.isEmpty else {
            return (.row(before: nil), CGRect(x: vp.minX, y: vp.minY, width: vp.width, height: t))
        }
        var frames: [WinID: CGRect] = [:]
        for item in layout(lp, scroll: renderScrollY, minHeights: minHeights) { frames[item.id] = item.frame }
        func top(_ i: Int) -> CGFloat { vp.minY - renderScrollY + rowTop(i, gap: gap) }
        func bottom(_ i: Int) -> CGFloat { top(i) + rows[i].height }
        let (rowX0, rowWidth) = Strip.rowExtent(lp)
        // The row under the cursor (or the nearest one).
        let r = rows.indices.first { p.y < bottom($0) + gap / 2 } ?? rows.count - 1
        let own = locate(id)

        // Near a window's left/right edge: beside it.
        if let c = rows[r].windows.firstIndex(where: { frames[$0].map { p.x >= $0.minX - gap && p.x <= $0.maxX + gap } ?? false }),
           let f = frames[rows[r].windows[c]], rows[r].windows[c] != id {
            let edge = min(f.width * 0.25, 160)
            let right: Bool? = p.x < f.minX + edge ? false : p.x > f.maxX - edge ? true : nil
            if let right {
                // Already right there (the neighbour on that side is the dragged window): no move.
                let neighbour = right ? c + 1 : c - 1
                let noop = own.map { $0.row == r && $0.col == neighbour } ?? false
                if !noop {
                    let x = right ? f.maxX + gap / 2 : f.minX - gap / 2
                    let y0 = max(top(r), vp.minY), y1 = min(bottom(r), vp.maxY)
                    return (.beside(rows[r].windows[c], right: right),
                            CGRect(x: (x - t / 2).rounded(), y: y0, width: t, height: max(y1 - y0, t)))
                }
            }
        }

        // Between rows: above this row when the cursor is in its upper half, else below it.
        let index = p.y < (top(r) + bottom(r)) / 2 ? r : r + 1
        func boundary(_ k: Int) -> CGFloat { k == 0 ? top(0) - gap / 2 : bottom(k - 1) + gap / 2 }
        // Landing where it already is: no line.
        if let own, rows[own.row].windows.count == 1, index == own.row || index == own.row + 1 { return nil }
        let anchor = index < rows.count ? rows[index].windows.first { $0 != id } : nil
        let y = min(max(boundary(index), vp.minY + t / 2), vp.maxY - t / 2)
        return (.row(before: anchor), CGRect(x: rowX0, y: (y - t / 2).rounded(), width: rowWidth, height: t))
    }
}

/// Scrolling the strip while a window is dragged over the zone: only the bands along the
/// zone's top and bottom edges (15% of its height, at least 60 pt) scroll, faster the deeper
/// the cursor is in them, from 0.15 to 1.5 screen heights a second.
public enum DragScroll {
    /// `velocity` in points/s (positive = down), 0 where it can't scroll further that way;
    /// `inBand` false in the middle of the zone.
    public static func velocity(cursorY y: CGFloat, zone: CGRect, viewportHeight vh: CGFloat,
                                scroll: CGFloat, maxScroll: CGFloat) -> (velocity: CGFloat, inBand: Bool) {
        let band = max(60, zone.height * 0.15)
        let depth: CGFloat, dir: CGFloat
        if y - zone.minY < band {
            depth = 1 - (y - zone.minY) / band
            dir = -1
        } else if zone.maxY - y < band {
            depth = 1 - (zone.maxY - y) / band
            dir = 1
        } else {
            return (0, false)
        }
        if (dir < 0 && scroll <= 0) || (dir > 0 && scroll >= maxScroll) { return (0, true) }
        // A gentle start at the band's inner border, quick at the very edge.
        return (dir * vh * (0.15 + 1.35 * pow(min(max(depth, 0), 1), 1.5)), true)
    }
}
