import AppKit
@testable import GlideBoardCore

@main
struct GlideBoardChecksMain {
    @MainActor
    static func main() async {
        // Views under test need an app instance; we never call run().
        _ = NSApplication.shared

        // This process has no bundle id, so UserDefaults.standard resolves to
        // its own domain (never the real app's). Wipe it for repeatable runs.
        UserDefaults.standard.removePersistentDomain(
            forName: ProcessInfo.processInfo.processName)

        guard FileManager.default.fileExists(atPath: "Resources/es_words.txt") else {
            print("Word lists not found: run from the repo root — ./test.sh")
            exit(2)
        }

        await lexiconChecks()
        await gestureDecoderChecks()
        await gestureRankingChecks()
        await phraseMemoryChecks()
        await bigramModelChecks()
        await completionChecks()
        await transformChecks()
        await settingsChecks()
        await composerDeliveryChecks()
        await dictationChecks()
        await voiceAttentionChecks()
        await numaAudioChecks()
        await numaStateMachineChecks()
        await numaLifecycleChecks()
        await numaPresentationChecks()
        await keyboardLayerChecks()
        await swipeGestureChecks()
        await doubleOptionChecks()
        await actionCatalogChecks()
        await workspaceProfileChecks()

        Checks.shared.finish()
    }
}
