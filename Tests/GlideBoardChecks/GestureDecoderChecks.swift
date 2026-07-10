import AppKit
@testable import GlideBoardCore

/// Key centers (unit-grid coordinates) and average key width taken from the
/// real Spanish letters layer — the same geometry the app decodes against.
@MainActor
private func spanishGeometry() -> (centers: [Character: CGPoint], keyWidth: CGFloat) {
    let layout = KeyboardLayout.build(for: .spanish)
    var centers: [Character: CGPoint] = [:]
    var totalWidth: CGFloat = 0
    var letterCount = 0
    for key in layout.keys {
        guard let letter = key.letter else { continue }
        centers[letter] = CGPoint(x: key.unitFrame.midX, y: key.unitFrame.midY)
        totalWidth += key.unitFrame.width
        letterCount += 1
    }
    return (centers, totalWidth / CGFloat(max(1, letterCount)))
}

/// The ideal polyline for a word, densified so it looks like a drawn path.
private func idealGesture(for word: String, centers: [Character: CGPoint]) -> [CGPoint] {
    let anchors = Lexicon.keySequence(for: word).compactMap { centers[$0] }
    return GestureDecoder.resample(anchors, count: 30)
}

@MainActor
func gestureDecoderChecks() async {
    let c = Checks.shared
    c.begin("GestureDecoder")

    await c.test("resample yields equidistant points with exact endpoints") {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]
        let out = GestureDecoder.resample(pts, count: 5)
        try expectEqual(out.count, 5)
        try expectEqual(out.first!, CGPoint(x: 0, y: 0))
        try expectEqual(out.last!, CGPoint(x: 10, y: 0))
        try expectTrue(abs(out[2].x - 5) < 0.01, "midpoint at \(out[2])")
    }

    await c.test("pathLength sums segment lengths") {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 4), CGPoint(x: 3, y: 14)]
        try expectTrue(abs(GestureDecoder.pathLength(pts) - 15) < 0.001)
    }

    await c.test("truncate cuts a polyline at the requested arc length") {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]
        let cut = GestureDecoder.truncate(pts, toLength: 4)
        try expectEqual(cut.count, 2)
        try expectTrue(abs(cut.last!.x - 4) < 0.001, "cut at \(cut.last!)")
    }

    await c.test("smooth removes jitter but keeps exact endpoints") {
        var pts: [CGPoint] = []
        for i in 0..<30 {
            pts.append(CGPoint(x: CGFloat(i), y: i.isMultiple(of: 2) ? 0.4 : -0.4))
        }
        let out = GestureDecoder.smooth(pts)
        try expectEqual(out.first!, pts.first!)
        try expectEqual(out.last!, pts.last!)
        // Interior jitter is damped well below its original amplitude.
        try expectTrue(abs(out[15].y) < 0.2, "still jittery: \(out[15])")
    }

    await c.test("simplify collapses collinear points to the endpoints") {
        let pts = (0...10).map { CGPoint(x: CGFloat($0), y: 0) }
        try expectEqual(GestureDecoder.simplify(pts, tolerance: 0.1).count, 2)
    }

    let (centers, keyWidth) = spanishGeometry()
    let lexicon = Lexicon(languages: [.spanish])
    let decoder = GestureDecoder(keyCenters: centers, keyWidth: keyWidth, lexicon: lexicon)

    await c.test("a clean glide through h-o-l-a decodes to 'hola'") {
        let out = decoder.decode(points: idealGesture(for: "hola", centers: centers),
                                 activeLanguage: .spanish)
        try expectTrue(out.contains("hola"), "got \(out)")
    }

    await c.test("a clean glide decodes longer words too") {
        let out = decoder.decode(points: idealGesture(for: "gracias", centers: centers),
                                 activeLanguage: .spanish)
        try expectEqual(out.first, "gracias", "got \(out)")
    }

    await c.test("context score decides between words with identical paths") {
        // "esta" and "está" share the exact key sequence, so their gesture
        // cost is identical — only ranking signals can separate them.
        let gesture = idealGesture(for: "esta", centers: centers)
        let boosted = decoder.decode(points: gesture, activeLanguage: .spanish,
                                     contextScore: { $0 == "está" ? 1 : 0 })
        let plain = try unwrap(boosted.firstIndex(of: "esta"), "got \(boosted)")
        let accented = try unwrap(boosted.firstIndex(of: "está"), "got \(boosted)")
        try expectTrue(accented < plain,
                       "context boost must put 'está' first: \(boosted)")
    }

    await c.test("decodePartial only previews words starting near the gesture") {
        let full = Lexicon.keySequence(for: "gracias").compactMap { centers[$0] }
        let partialLength = GestureDecoder.pathLength(full) * 0.7
        let partial = GestureDecoder.resample(
            GestureDecoder.truncate(full, toLength: partialLength), count: 25)
        let out = decoder.decodePartial(points: partial, maxResults: 6)
        try expectFalse(out.isEmpty)
        // Candidates must all begin within the prune radius of the start key.
        let start = try unwrap(centers["g"])
        for word in out {
            let first = try unwrap(Lexicon.keySequence(for: word).first)
            let center = try unwrap(centers[first])
            try expectTrue(hypot(center.x - start.x, center.y - start.y) <= keyWidth * 1.6,
                           "'\(word)' starts too far from the gesture: \(out)")
        }
    }

    await c.test("degenerate inputs return no candidates instead of crashing") {
        try expectEqual(decoder.decode(points: [], activeLanguage: .spanish), [])
        try expectEqual(decoder.decode(points: [CGPoint(x: 1, y: 1)],
                                       activeLanguage: .spanish), [])
        try expectEqual(decoder.decodePartial(points: [CGPoint(x: 1, y: 1)]), [])
    }
}
