import XCTest
import Carbon
@testable import GlideBoard

private final class DictationEngineSpy: DictationEngine {
    var startCount = 0
    var stopCount = 0
    var cancelCount = 0
    var receivedLanguages: [String] = []
    var transcript = ""

    func startRecording() async throws {
        startCount += 1
    }

    func stopRecordingAndTranscribe(language: String) async throws -> String {
        stopCount += 1
        receivedLanguages.append(language)
        return transcript
    }

    func cancelRecording() {
        cancelCount += 1
    }
}

@MainActor
final class DictationControllerTests: XCTestCase {
    func testPressStartsRecordingAndPublishesRecordingState() async {
        let engine = DictationEngineSpy()
        var states: [DictationState] = []
        let controller = DictationController(
            engine: engine,
            language: { "es" },
            output: { _ in },
            stateChanged: { states.append($0) }
        )

        await controller.press()

        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(controller.state, .recording)
        XCTAssertEqual(states, [.preparing, .recording])
    }

    func testReleaseTranscribesInCurrentLanguageAndEmitsTrimmedText() async {
        let engine = DictationEngineSpy()
        engine.transcript = "  Hola desde WhisperKit. \n"
        var output: [String] = []
        let controller = DictationController(
            engine: engine,
            language: { "es" },
            output: { output.append($0) },
            stateChanged: { _ in }
        )

        await controller.press()
        await controller.release()

        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(engine.receivedLanguages, ["es"])
        XCTAssertEqual(output, ["Hola desde WhisperKit."])
        XCTAssertEqual(controller.state, .idle)
    }

    func testReleaseDoesNotEmitAnEmptyTranscript() async {
        let engine = DictationEngineSpy()
        engine.transcript = " \n "
        var output: [String] = []
        let controller = DictationController(
            engine: engine,
            language: { "en" },
            output: { output.append($0) },
            stateChanged: { _ in }
        )

        await controller.press()
        await controller.release()

        XCTAssertTrue(output.isEmpty)
        XCTAssertEqual(controller.state, .idle)
    }

    func testInsertionAddsASeparatorAfterExistingDraftText() {
        XCTAssertEqual(
            DictationInsertion.text(transcript: "nuevo texto", existingText: "borrador"),
            " nuevo texto"
        )
        XCTAssertEqual(
            DictationInsertion.text(transcript: "nuevo texto", existingText: "borrador "),
            "nuevo texto"
        )
        XCTAssertEqual(
            DictationInsertion.text(transcript: "nuevo texto", existingText: ""),
            "nuevo texto"
        )
    }

    func testCarbonHotKeyEventsMapToPressAndReleasePhases() {
        XCTAssertEqual(hotKeyPhase(eventKind: UInt32(kEventHotKeyPressed)), .pressed)
        XCTAssertEqual(hotKeyPhase(eventKind: UInt32(kEventHotKeyReleased)), .released)
        XCTAssertNil(hotKeyPhase(eventKind: UInt32(kEventRawKeyDown)))
    }
}
