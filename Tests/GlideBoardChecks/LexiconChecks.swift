import Foundation
@testable import GlideBoardCore

@MainActor
func lexiconChecks() async {
    let c = Checks.shared
    c.begin("Lexicon")

    await c.test("keySequence strips accents and consecutive duplicates") {
        try expectEqual(Lexicon.keySequence(for: "hola"), ["h", "o", "l", "a"])
        try expectEqual(Lexicon.keySequence(for: "llave"), ["l", "a", "v", "e"])
        try expectEqual(Lexicon.keySequence(for: "está"), ["e", "s", "t", "a"])
    }

    await c.test("baseKey maps accents to their key and leaves ñ alone") {
        try expectEqual(Lexicon.baseKey("á"), "a")
        try expectEqual(Lexicon.baseKey("ü"), "u")
        try expectEqual(Lexicon.baseKey("ñ"), "ñ")
    }

    await c.test("isSubsequence detects in-order abbreviations") {
        try expectTrue(Lexicon.isSubsequence("tcld", of: "teclado"))
        try expectFalse(Lexicon.isSubsequence("xyz", of: "teclado"))
        try expectTrue(Lexicon.isSubsequence("", of: "teclado"))
    }

    let lexicon = Lexicon(languages: [.spanish])

    await c.test("loads the Spanish word list") {
        try expectTrue(lexicon.entries.count > 1000,
                       "only \(lexicon.entries.count) entries loaded")
        try expectTrue(lexicon.contains("hola"))
    }

    await c.test("prefix completions rank frequent words first") {
        let out = lexicon.completions(prefix: "hol")
        try expectTrue(out.contains("hola"), "got \(out)")
        // Completions never suggest the prefix itself.
        try expectFalse(lexicon.completions(prefix: "hola").contains("hola"))
    }

    await c.test("accentless prefixes still find accented words") {
        let out = lexicon.completions(prefix: "adio")
        try expectTrue(out.contains("adiós") || out.contains("adios"), "got \(out)")
    }

    await c.test("abbreviation fallback finds subsequence matches") {
        let out = lexicon.completions(prefix: "tcld")
        try expectTrue(out.contains("teclado"), "got \(out)")
    }

    await c.test("learned words become completable and glidable") {
        let fresh = Lexicon(languages: [.spanish])
        try expectTrue(fresh.learn("Zorrolobo"))
        try expectTrue(fresh.contains("zorrolobo"))
        try expectTrue(fresh.completions(prefix: "zorrol").contains("zorrolobo"))
        try expectFalse(fresh.learn("zorrolobo"), "relearning must be a no-op")
        try expectFalse(fresh.learn("ab"), "too short")
        try expectFalse(fresh.learn("x1y"), "digits are not learnable")
    }

    await c.test("UserDictionary trims, lowercases, dedupes and persists") {
        let dir = temporaryDirectory()
        let dictionary = UserDictionary(directory: dir)
        dictionary.replaceAll([" Hola ", "hola", "mundo", ""])
        try expectEqual(dictionary.words, ["hola", "mundo"])
        dictionary.add("teclado")
        let reloaded = UserDictionary(directory: dir)
        try expectEqual(reloaded.words, ["hola", "mundo", "teclado"])
    }
}
