import XCTest
@testable import GlideBoard

final class CompletionProviderTests: XCTestCase {
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
}
