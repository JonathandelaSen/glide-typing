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

    func decode(points input: [CGPoint], activeLanguage: Language,
                contextScore: (String) -> Double = { _ in 0 },
                personalScore: (String) -> Double = { _ in 0 },
                maxResults: Int = 4) -> [String] {
        guard input.count >= 2 else { return [] }
        let raw = Self.simplify(Self.smooth(input), tolerance: keyWidth * 0.10)
        let gesture = Self.resample(raw, count: resampleCount)
        let gestureLength = Self.pathLength(raw)

        // Broad, cheap pass over the full lexicon prevents catastrophic
        // endpoint pruning. Expensive anchor/turn scoring then runs only on
        // plausible shapes, keeping word commits responsive.
        var coarse: [(entry: Lexicon.Entry, cost: Double)] = []
        coarse.reserveCapacity(lexicon.entries.count)
        for entry in lexicon.entries {
            guard let cost = coarseScore(entry: entry, gesture: gesture,
                                         rawGesture: raw, gestureLength: gestureLength) else { continue }
            coarse.append((entry, cost))
        }
        coarse.sort { $0.cost < $1.cost }

        var scored: [GestureCandidate] = []
        for item in coarse.prefix(320) {
            let entry = item.entry
            guard let cost = score(entry: entry, gesture: gesture, rawGesture: raw,
                                   gestureLength: gestureLength) else { continue }
            scored.append(GestureCandidate(word: entry.word, gestureCost: cost,
                                           rank: entry.rank, language: entry.language))
        }
        scored = GestureRanker.rank(scored, activeLanguage: activeLanguage,
                                    contextScore: contextScore, personalScore: personalScore)
        var seen = Set<String>()
        var out: [String] = []
        for s in scored where !seen.contains(s.word) {
            seen.insert(s.word)
            out.append(s.word)
            if out.count == maxResults { break }
        }
        return out
    }

    private func coarseScore(entry: Lexicon.Entry, gesture: [CGPoint], rawGesture: [CGPoint],
                             gestureLength: CGFloat) -> Double? {
        var ideal: [CGPoint] = []
        ideal.reserveCapacity(entry.keySequence.count)
        for ch in entry.keySequence {
            guard let c = keyCenters[ch] else { return nil }
            ideal.append(c)
        }
        let idealLength = Self.pathLength(ideal)
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
        return 0.72 * location + 0.70 * shapeDistance(gesture, word)
            + 0.34 * endpointDistance(rawGesture, ideal)
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

    private func score(entry: Lexicon.Entry, gesture: [CGPoint], rawGesture: [CGPoint],
                       gestureLength: CGFloat) -> Double? {
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
        let anchors = anchorDistance(rawGesture, ideal)
        let turns = turnDistance(rawGesture, ideal)
        let endpoints = endpointDistance(rawGesture, ideal)
        return 0.72 * location + 0.70 * shape + 0.62 * anchors
            + 0.42 * turns + 0.34 * endpoints
    }

    private func endpointDistance(_ gesture: [CGPoint], _ ideal: [CGPoint]) -> Double {
        guard let start = gesture.first, let end = gesture.last,
              let idealStart = ideal.first, let idealEnd = ideal.last else { return 10 }
        return Double((hypot(start.x - idealStart.x, start.y - idealStart.y)
                     + hypot(end.x - idealEnd.x, end.y - idealEnd.y)) / (2 * keyWidth))
    }

    private func anchorDistance(_ gesture: [CGPoint], _ ideal: [CGPoint]) -> Double {
        guard !ideal.isEmpty else { return 10 }
        var total: CGFloat = 0, weights: CGFloat = 0
        for (index, anchor) in ideal.enumerated() {
            let weight: CGFloat = index == 0 || index == ideal.count - 1 ? 2.2 : 1
            let nearest = gesture.map { hypot($0.x - anchor.x, $0.y - anchor.y) }.min() ?? keyWidth * 4
            total += min(nearest / keyWidth, 2.5) * weight
            weights += weight
        }
        return Double(total / weights)
    }

    private func turnDistance(_ gesture: [CGPoint], _ ideal: [CGPoint]) -> Double {
        let a = Self.turnAngles(Self.simplify(gesture, tolerance: keyWidth * 0.14))
        let b = Self.turnAngles(ideal)
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let count = max(a.count, b.count)
        return zip(Self.resampleValues(a, count: count), Self.resampleValues(b, count: count))
            .map { abs($0 - $1) / .pi }.reduce(0, +) / Double(count)
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

    static func simplify(_ pts: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        let first = pts[0], last = pts[pts.count - 1]
        var maxDistance: CGFloat = 0, split = 0
        for i in 1..<(pts.count - 1) {
            let d = pointSegmentDistance(pts[i], first, last)
            if d > maxDistance { maxDistance = d; split = i }
        }
        guard maxDistance > tolerance else { return [first, last] }
        let left = simplify(Array(pts[0...split]), tolerance: tolerance)
        let right = simplify(Array(pts[split...]), tolerance: tolerance)
        return left.dropLast() + right
    }

    private static func pointSegmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1e-9 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private static func turnAngles(_ pts: [CGPoint]) -> [Double] {
        guard pts.count > 2 else { return [] }
        return (1..<(pts.count - 1)).compactMap { i in
            var delta = atan2(Double(pts[i + 1].y - pts[i].y), Double(pts[i + 1].x - pts[i].x))
                - atan2(Double(pts[i].y - pts[i - 1].y), Double(pts[i].x - pts[i - 1].x))
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            return abs(delta) > 0.20 ? delta : nil
        }
    }

    private static func resampleValues(_ values: [Double], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard !values.isEmpty else { return Array(repeating: 0, count: count) }
        guard values.count > 1, count > 1 else { return Array(repeating: values[0], count: count) }
        return (0..<count).map { i in
            let position = Double(i) * Double(values.count - 1) / Double(count - 1)
            let low = Int(position.rounded(.down)), high = min(values.count - 1, low + 1)
            let t = position - Double(low)
            return values[low] * (1 - t) + values[high] * t
        }
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
