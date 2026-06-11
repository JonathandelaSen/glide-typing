import AppKit

/// SHARK2-style gesture decoder: compares the drawn path against the ideal
/// polyline through each candidate word's key centers, scoring location,
/// shape and word frequency.
final class GestureDecoder {
    private let resampleCount = 40
    private let keyCenters: [Character: CGPoint]
    private let keyWidth: CGFloat
    private let lexicon: Lexicon

    init(keyCenters: [Character: CGPoint], keyWidth: CGFloat, lexicon: Lexicon) {
        self.keyCenters = keyCenters
        self.keyWidth = keyWidth
        self.lexicon = lexicon
    }

    func decode(points input: [CGPoint], maxResults: Int = 4) -> [String] {
        guard input.count >= 2 else { return [] }
        let raw = Self.smooth(input)
        let gesture = Self.resample(raw, count: resampleCount)
        let gestureLength = Self.pathLength(raw)
        let start = raw.first!, end = raw.last!
        let pruneRadius = keyWidth * 1.6

        // Prune by first/last key proximity using the (first,last) index.
        var firsts: [Character] = [], lasts: [Character] = []
        for (ch, c) in keyCenters {
            if hypot(c.x - start.x, c.y - start.y) <= pruneRadius { firsts.append(ch) }
            if hypot(c.x - end.x, c.y - end.y) <= pruneRadius { lasts.append(ch) }
        }

        var scored: [(word: String, cost: Double)] = []
        for f in firsts {
            for l in lasts {
                guard let bucket = lexicon.byEnds["\(f)\(l)"] else { continue }
                for entry in bucket {
                    guard let cost = score(entry: entry, gesture: gesture, gestureLength: gestureLength) else { continue }
                    scored.append((entry.word, cost))
                }
            }
        }
        scored.sort { $0.cost < $1.cost }
        var seen = Set<String>()
        var out: [String] = []
        for s in scored where !seen.contains(s.word) {
            seen.insert(s.word)
            out.append(s.word)
            if out.count == maxResults { break }
        }
        return out
    }

    /// Decode an in-progress gesture: the path so far is matched against the
    /// *beginning* of each candidate word's ideal path, so we can preview the
    /// word being formed before the user lifts the finger.
    func decodePartial(points input: [CGPoint], maxResults: Int = 4) -> [String] {
        guard input.count >= 2 else { return [] }
        let raw = Self.smooth(input)
        let gestureLength = Self.pathLength(raw)
        guard gestureLength > keyWidth * 0.8 else { return [] }
        let gesture = Self.resample(raw, count: resampleCount)
        let start = raw.first!
        let pruneRadius = keyWidth * 1.6

        var scored: [(word: String, cost: Double)] = []
        for (ch, c) in keyCenters {
            guard hypot(c.x - start.x, c.y - start.y) <= pruneRadius,
                  let bucket = lexicon.byFirst[ch] else { continue }
            for entry in bucket {
                var ideal: [CGPoint] = []
                for k in entry.keySequence {
                    guard let kc = keyCenters[k] else { ideal = []; break }
                    ideal.append(kc)
                }
                guard !ideal.isEmpty else { continue }
                let idealLength = Self.pathLength(ideal)
                // The word's full path must be at least roughly as long as what
                // has been drawn so far, and not absurdly longer.
                if idealLength < gestureLength * 0.55 || idealLength > gestureLength * 6 { continue }
                let prefix = Self.truncate(ideal, toLength: min(gestureLength, idealLength))
                let word = Self.resample(prefix, count: resampleCount)

                var locSum: CGFloat = 0
                for i in 0..<resampleCount {
                    locSum += hypot(gesture[i].x - word[i].x, gesture[i].y - word[i].y)
                }
                let location = Double(locSum / CGFloat(resampleCount) / keyWidth)
                let frequency = 0.30 * log10(Double(entry.rank + 10))
                scored.append((entry.word, location + frequency))
            }
        }
        scored.sort { $0.cost < $1.cost }
        var seen = Set<String>()
        var out: [String] = []
        for s in scored where !seen.contains(s.word) {
            seen.insert(s.word)
            out.append(s.word)
            if out.count == maxResults { break }
        }
        return out
    }

    /// Cut a polyline at a given arc length from its start.
    static func truncate(_ pts: [CGPoint], toLength target: CGFloat) -> [CGPoint] {
        guard pts.count > 1, target > 0 else { return pts }
        var out: [CGPoint] = [pts[0]]
        var remaining = target
        for i in 1..<pts.count {
            let seg = hypot(pts[i].x - pts[i-1].x, pts[i].y - pts[i-1].y)
            if seg >= remaining {
                let t = seg < 1e-9 ? 0 : remaining / seg
                out.append(CGPoint(x: pts[i-1].x + t * (pts[i].x - pts[i-1].x),
                                   y: pts[i-1].y + t * (pts[i].y - pts[i-1].y)))
                return out
            }
            remaining -= seg
            out.append(pts[i])
        }
        return out
    }

    private func score(entry: Lexicon.Entry, gesture: [CGPoint], gestureLength: CGFloat) -> Double? {
        var ideal: [CGPoint] = []
        for ch in entry.keySequence {
            guard let c = keyCenters[ch] else { return nil }
            ideal.append(c)
        }
        let idealLength = Self.pathLength(ideal)
        // Discard words whose ideal path length is wildly different.
        if gestureLength > keyWidth {
            let ratio = idealLength / gestureLength
            if ratio < 0.3 || ratio > 2.6 { return nil }
        }
        let word = Self.resample(ideal, count: resampleCount)

        var locSum: CGFloat = 0
        for i in 0..<resampleCount {
            locSum += hypot(gesture[i].x - word[i].x, gesture[i].y - word[i].y)
        }
        let location = Double(locSum / CGFloat(resampleCount) / keyWidth)

        let shape = shapeDistance(gesture, word)
        let frequency = 0.30 * log10(Double(entry.rank + 10))

        return location + 0.9 * shape + frequency
    }

    /// Distance after normalizing translation and scale.
    private func shapeDistance(_ a: [CGPoint], _ b: [CGPoint]) -> Double {
        let na = Self.normalize(a), nb = Self.normalize(b)
        var sum: CGFloat = 0
        for i in 0..<na.count {
            sum += hypot(na[i].x - nb[i].x, na[i].y - nb[i].y)
        }
        return Double(sum / CGFloat(na.count))
    }

    private static func normalize(_ pts: [CGPoint]) -> [CGPoint] {
        var minX = CGFloat.greatestFiniteMagnitude, minY = minX
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = maxX
        var cx: CGFloat = 0, cy: CGFloat = 0
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
            cx += p.x; cy += p.y
        }
        cx /= CGFloat(pts.count); cy /= CGFloat(pts.count)
        let scale = max(maxX - minX, maxY - minY)
        let s = scale < 1e-6 ? 1 : scale
        return pts.map { CGPoint(x: ($0.x - cx) / s, y: ($0.y - cy) / s) }
    }

    /// Moving-average smoothing: removes pointer jitter that would otherwise
    /// inflate the gesture's arc length and distort matching.
    static func smooth(_ pts: [CGPoint], window: Int = 7) -> [CGPoint] {
        guard pts.count > window else { return pts }
        let half = window / 2
        var out: [CGPoint] = []
        out.reserveCapacity(pts.count)
        for i in 0..<pts.count {
            let lo = max(0, i - half), hi = min(pts.count - 1, i + half)
            var sx: CGFloat = 0, sy: CGFloat = 0
            for j in lo...hi { sx += pts[j].x; sy += pts[j].y }
            let n = CGFloat(hi - lo + 1)
            out.append(CGPoint(x: sx / n, y: sy / n))
        }
        // Keep exact endpoints — first/last letter pruning depends on them.
        out[0] = pts[0]
        out[out.count - 1] = pts[pts.count - 1]
        return out
    }

    static func pathLength(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count > 1 else { return 0 }
        var len: CGFloat = 0
        for i in 1..<pts.count {
            len += hypot(pts[i].x - pts[i-1].x, pts[i].y - pts[i-1].y)
        }
        return len
    }

    /// Resample a polyline to `count` equidistant points.
    static func resample(_ pts: [CGPoint], count: Int) -> [CGPoint] {
        guard pts.count > 1 else {
            return Array(repeating: pts.first ?? .zero, count: count)
        }
        let total = pathLength(pts)
        guard total > 1e-6 else {
            return Array(repeating: pts[0], count: count)
        }
        let step = total / CGFloat(count - 1)
        var out: [CGPoint] = [pts[0]]
        var accumulated: CGFloat = 0
        var i = 1
        var prev = pts[0]
        while out.count < count - 1 && i < pts.count {
            let seg = hypot(pts[i].x - prev.x, pts[i].y - prev.y)
            if accumulated + seg >= step {
                let t = (step - accumulated) / seg
                let np = CGPoint(x: prev.x + t * (pts[i].x - prev.x),
                                 y: prev.y + t * (pts[i].y - prev.y))
                out.append(np)
                prev = np
                accumulated = 0
            } else {
                accumulated += seg
                prev = pts[i]
                i += 1
            }
        }
        while out.count < count { out.append(pts.last!) }
        return out
    }
}
