import CoreGraphics
import Foundation
@testable import GlideBoardCore

@MainActor
func composerDeliveryChecks() async {
    let c = Checks.shared
    c.begin("Composer delivery")

    await c.test("global send submits a populated draft after inserting it") {
        try expectEqual(ComposerDeliveryIntent.globalSend(draft: "Hola"), .insertAndSubmit)
    }

    await c.test("global send submits even when the draft is empty") {
        try expectEqual(ComposerDeliveryIntent.globalSend(draft: ""), .insertAndSubmit)
    }

    await c.test("the board Return key only submits an empty draft") {
        try expectEqual(ComposerDeliveryIntent.boardReturn(draft: "Hola"), .insertOnly)
        try expectEqual(ComposerDeliveryIntent.boardReturn(draft: ""), .insertAndSubmit)
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
