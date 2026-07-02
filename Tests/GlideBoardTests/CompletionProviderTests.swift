import XCTest
import ApplicationServices
@testable import GlideBoard

final class CompletionProviderTests: XCTestCase {
    func testFocusedTextTargetRecognizesEditableRoles() {
        XCTAssertTrue(FocusedFieldReader.isEditableTextTarget(role: kAXTextFieldRole as String,
                                                              supportsTextSelection: false))
        XCTAssertTrue(FocusedFieldReader.isEditableTextTarget(role: kAXTextAreaRole as String,
                                                              supportsTextSelection: false))
        XCTAssertTrue(FocusedFieldReader.isEditableTextTarget(role: kAXWebAreaRole as String,
                                                              supportsTextSelection: true))
        XCTAssertFalse(FocusedFieldReader.isEditableTextTarget(role: kAXButtonRole as String,
                                                               supportsTextSelection: false))
    }

    func testUnknownTextTargetStillAllowsInsertionAttempt() {
        XCTAssertTrue(FocusedFieldReader.TextTargetStatus.unknown.canAttemptInsertion)
        XCTAssertTrue(FocusedFieldReader.textTargetStatus(role: nil,
                                                          supportsTextSelection: false).canAttemptInsertion)
    }

    func testKnownNonEditableTargetBlocksInsertionAttempt() {
        XCTAssertFalse(FocusedFieldReader.TextTargetStatus.notEditable.canAttemptInsertion)
        XCTAssertFalse(FocusedFieldReader.textTargetStatus(role: kAXButtonRole as String,
                                                           supportsTextSelection: false).canAttemptInsertion)
    }

    func testContextForModelPreservesTrailingWhitespace() {
        XCTAssertEqual(CompletionCleaner.contextForModel("vamos a revisar esto "), "vamos a revisar esto ")
    }

    func testContextForModelKeepsOnlyRecentTextWithoutCuttingAWord() {
        let old = String(repeating: "antiguo ", count: 100)
        let result = CompletionCleaner.contextForModel(old + "contexto reciente", maxLength: 40)

        XCTAssertEqual(result, "antiguo antiguo antiguo contexto reciente")
    }

    func testCleanerRejectsMetaCommentaryInsteadOfOfferingItForInsertion() {
        XCTAssertNil(CompletionCleaner.clean("Respuesta: puedes terminar la frase", context: "Creo que"))
        XCTAssertNil(CompletionCleaner.clean("No hay suficiente contexto", context: "Creo que"))
    }

    func testCleanerRemovesEchoAndKeepsNaturalContinuation() {
        XCTAssertEqual(
            CompletionCleaner.clean("revisar el código antes de enviarlo", context: "Tenemos que revisar el código"),
            "antes de enviarlo"
        )
    }

    func testCleanerRemovesPromptDelimitersFromContinuation() {
        XCTAssertEqual(
            CompletionCleaner.clean("<<<necesitamos>>><<<soluciones>>>", context: "fox ese"),
            "necesitamos soluciones"
        )
    }

    func testCleanerRemovesPromptDelimitersWhileDroppingEcho() {
        XCTAssertEqual(
            CompletionCleaner.clean("fox ese <<<necesitamos>>> <<<soluciones>>>", context: "fox ese"),
            "necesitamos soluciones"
        )
    }
}
