import CoreGraphics

/// Splits the part of the screen outside the Oz zone (the scroll area) into rectangles that
/// windows dropped outside the zone are tiled in.
///
/// The outside is a frame around the zone with up to four sides (left, right, top, bottom).
/// Each side becomes one rectangle, which is the fewest possible; what remains to choose is
/// which side each corner square belongs to (the strip above/below or the one beside it).
/// Of those choices we keep the one with the longest rectangle (then the second longest,
/// and so on, then the largest area). Sides too thin to hold a window are left out.
public enum OutsideRegions {
    public static func compute(outer o: CGRect, zone z0: CGRect, minThickness: CGFloat = 150) -> [CGRect] {
        let z = z0.intersection(o)
        guard !z.isNull, !z.isEmpty else { return [] }
        let left = z.minX - o.minX, right = o.maxX - z.maxX
        let top = z.minY - o.minY, bottom = o.maxY - z.maxY
        let hasL = left >= minThickness, hasR = right >= minThickness
        let hasT = top >= minThickness, hasB = bottom >= minThickness

        var best: [CGRect] = []
        var bestScore: [CGFloat] = []
        // Bit set: that corner goes to the vertical strip (left/right) instead of top/bottom.
        // Order: top-left, top-right, bottom-left, bottom-right.
        for mask in 0..<16 {
            func bit(_ i: Int) -> Bool { mask & (1 << i) != 0 }
            // A corner is a choice only between two strips that both exist; otherwise it goes
            // to the one that does (or stays uncovered). Skip masks that set a non-choice bit.
            let choice = [hasL && hasT, hasR && hasT, hasL && hasB, hasR && hasB]
            if (0..<4).contains(where: { bit($0) && !choice[$0] }) { continue }
            // true: the corner belongs to the vertical strip beside it.
            let tlSide = hasL && (!hasT || bit(0)), trSide = hasR && (!hasT || bit(1))
            let blSide = hasL && (!hasB || bit(2)), brSide = hasR && (!hasB || bit(3))
            var rects: [CGRect] = []
            if hasL {
                let y0 = tlSide ? o.minY : z.minY, y1 = blSide ? o.maxY : z.maxY
                rects.append(CGRect(x: o.minX, y: y0, width: left, height: y1 - y0))
            }
            if hasR {
                let y0 = trSide ? o.minY : z.minY, y1 = brSide ? o.maxY : z.maxY
                rects.append(CGRect(x: z.maxX, y: y0, width: right, height: y1 - y0))
            }
            if hasT {
                let x0 = tlSide ? z.minX : o.minX, x1 = trSide ? z.maxX : o.maxX
                rects.append(CGRect(x: x0, y: o.minY, width: x1 - x0, height: top))
            }
            if hasB {
                let x0 = blSide ? z.minX : o.minX, x1 = brSide ? z.maxX : o.maxX
                rects.append(CGRect(x: x0, y: z.maxY, width: x1 - x0, height: bottom))
            }
            let score = rects.map { max($0.width, $0.height) }.sorted(by: >)
                + [rects.reduce(0) { $0 + $1.width * $1.height }]
            if best.isEmpty || score.lexicographicallyPrecedes(bestScore, by: >) {
                best = rects
                bestScore = score
            }
        }
        // Stable order: top to bottom, then left to right.
        return best.sorted { $0.minY != $1.minY ? $0.minY < $1.minY : $0.minX < $1.minX }
    }

    /// Frames for `count` windows sharing `region`, side by side along its long side
    /// (stacked when it's taller than wide), with `gap` between them and around them.
    public static func frames(in region: CGRect, count: Int, gap: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let r = region.insetBy(dx: gap, dy: gap)
        let vertical = r.height >= r.width
        let total = (vertical ? r.height : r.width) - gap * CGFloat(count - 1)
        var out: [CGRect] = []
        var pos = vertical ? r.minY : r.minX
        for i in 0..<count {
            // The last one takes what's left so rounding never leaves a gap.
            let end = vertical ? r.maxY : r.maxX
            let len = i == count - 1 ? end - pos : (total / CGFloat(count)).rounded()
            out.append(vertical ? CGRect(x: r.minX, y: pos, width: r.width, height: len)
                                : CGRect(x: pos, y: r.minY, width: len, height: r.height))
            pos += len + gap
        }
        return out
    }
}
