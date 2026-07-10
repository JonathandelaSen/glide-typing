import CoreGraphics
import Foundation
@testable import GlideBoardCore

@MainActor
func composerDeliveryChecks() async {
    let c = Checks.shared
    c.begin("Composer delivery")

    await c.test("sending a populated draft only inserts it for review") {
        try expectEqual(ComposerDeliveryIntent.send(draft: "Hola"), .insertOnly)
    }

    await c.test("sending an empty draft forwards Return to submit") {
        try expectEqual(ComposerDeliveryIntent.send(draft: ""), .insertAndSubmit)
    }

    await c.test("hotkey modifiers still held postpone injection") {
        try expectTrue(TextInjector.modifiersBlockTyping([.maskCommand]))
        try expectTrue(TextInjector.modifiersBlockTyping([.maskControl]))
        try expectTrue(TextInjector.modifiersBlockTyping([.maskShift, .maskAlternate]))
    }

    await c.test("latched or empty modifier state does not postpone injection") {
        try expectFalse(TextInjector.modifiersBlockTyping([]))
        try expectFalse(TextInjector.modifiersBlockTyping(.maskAlphaShift)) // caps lock
        try expectFalse(TextInjector.modifiersBlockTyping(.maskNonCoalesced))
    }
}
