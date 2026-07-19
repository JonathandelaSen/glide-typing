import Foundation

/// Stable identifiers for every action Numa can execute. Raw values are
/// persisted (optional shortcuts, palette recents) and must never change.
enum NumaActionID: String, CaseIterable, Sendable {
    case toggleBoard = "board.toggle"
    case focusComposer = "board.composer.focus"
    case sendDraft = "board.draft.send"
    case toggleHandsFreeDictation = "dictation.handsfree.toggle"
    case pushToTalk = "dictation.pushtotalk"
    case transformText = "text.transform"
    case toggleAttention = "numa.attention.toggle"
    case manageWorkspaceProfiles = "workspace.profiles.manage"
    case openSettings = "app.settings.open"
    case togglePalette = "palette.toggle"
}

enum NumaActionCategory: String, Sendable {
    case board
    case dictation
    case text
    case attention
    case system
}

/// How an action can be started. A press/release action needs a held key and
/// therefore cannot run from a one-shot surface like the palette or a menu.
enum NumaActionExecutionPolicy: Equatable, Sendable {
    case invoke
    case pressRelease(oneShotExplanation: String)
}

enum NumaActionOutcome: Equatable, Sendable {
    case completed
    case openedSurface
    case unavailable(String)
    case failed(String)
    case requiresConfirmation(String)
}

/// The surface an execution came from. Only actions whose semantics depend on
/// it (dictation start/stop sources) look at it.
enum NumaActionInvocation: Equatable, Sendable {
    case palette
    case statusMenu
    case hotKey
    case boardButton
    case doubleOption
}

struct NumaActionAvailability: Equatable, Sendable {
    let isAvailable: Bool
    let reason: String?

    static let available = NumaActionAvailability(isAvailable: true, reason: nil)
    static func unavailable(_ reason: String) -> NumaActionAvailability {
        NumaActionAvailability(isAvailable: false, reason: reason)
    }
}

struct NumaActionDescriptor: Sendable {
    let id: NumaActionID
    let title: String
    let subtitle: String
    /// Alternate names the user may search for (Spanish menu wording, etc.).
    let aliases: [String]
    let keywords: [String]
    let symbolName: String
    let category: NumaActionCategory
    let policy: NumaActionExecutionPolicy
    /// The palette shows a curated subset; every action still routes through
    /// the catalog from its other surfaces (menu, hotkeys).
    let showsInPalette: Bool
}

/// Executes catalog actions against the real app. Implementations never reach
/// into palette views; they return a typed outcome and the surface presents it.
@MainActor
protocol NumaActionExecuting: AnyObject {
    func performAction(_ id: NumaActionID,
                       from invocation: NumaActionInvocation) -> NumaActionOutcome
    func pressPushToTalk()
    func releasePushToTalk()
}

/// Owns the stable action list and routes every surface (palette, status
/// menu, global shortcuts, voice) through the same executor.
@MainActor
final class NumaActionCatalog {
    struct ResolvedAction {
        let descriptor: NumaActionDescriptor
        let availability: NumaActionAvailability
        /// Carbon key code + modifiers; nil when the user configured nothing.
        let shortcut: (keyCode: UInt32, modifiers: UInt32)?
        let voicePhrase: String?
    }

    private let descriptors: [NumaActionDescriptor]
    private weak var executor: NumaActionExecuting?
    private let availabilityProvider: (NumaActionID) -> NumaActionAvailability
    private let shortcutProvider: (NumaActionID) -> (keyCode: UInt32, modifiers: UInt32)?
    private let voicePhraseProvider: (NumaActionID) -> String?

    init(descriptors: [NumaActionDescriptor] = NumaActionCatalog.defaultDescriptors(),
         executor: NumaActionExecuting?,
         availability: @escaping (NumaActionID) -> NumaActionAvailability = { _ in .available },
         shortcut: @escaping (NumaActionID) -> (keyCode: UInt32, modifiers: UInt32)? = { _ in nil },
         voicePhrase: @escaping (NumaActionID) -> String? = { _ in nil })
    {
        self.descriptors = descriptors
        self.executor = executor
        self.availabilityProvider = availability
        self.shortcutProvider = shortcut
        self.voicePhraseProvider = voicePhrase
    }

    func descriptor(for id: NumaActionID) -> NumaActionDescriptor? {
        descriptors.first { $0.id == id }
    }

    /// Every action with its current availability and metadata, in stable
    /// catalog order. Metadata is resolved live so settings changes show up
    /// without rebuilding the catalog.
    func resolvedActions() -> [ResolvedAction] {
        descriptors.map { descriptor in
            ResolvedAction(descriptor: descriptor,
                           availability: effectiveAvailability(of: descriptor),
                           shortcut: shortcutProvider(descriptor.id),
                           voicePhrase: voicePhraseProvider(descriptor.id))
        }
    }

    @discardableResult
    func execute(_ id: NumaActionID,
                 from invocation: NumaActionInvocation) -> NumaActionOutcome
    {
        guard let descriptor = descriptor(for: id) else {
            return .failed("Unknown action \(id.rawValue)")
        }
        if case .pressRelease(let explanation) = descriptor.policy {
            return .unavailable(explanation)
        }
        let availability = availabilityProvider(id)
        guard availability.isAvailable else {
            return .unavailable(availability.reason ?? "Not available right now")
        }
        guard let executor else { return .failed("No executor attached") }
        return executor.performAction(id, from: invocation)
    }

    /// Push-to-talk keeps its existing press/release semantics: the global
    /// shortcut routes through here, never through one-shot `execute`.
    func pressPushToTalk() { executor?.pressPushToTalk() }
    func releasePushToTalk() { executor?.releasePushToTalk() }

    private func effectiveAvailability(of descriptor: NumaActionDescriptor)
        -> NumaActionAvailability
    {
        if case .pressRelease(let explanation) = descriptor.policy {
            return .unavailable(explanation)
        }
        return availabilityProvider(descriptor.id)
    }

    nonisolated static func defaultDescriptors() -> [NumaActionDescriptor] {
        [
            NumaActionDescriptor(
                id: .toggleBoard,
                title: "Show or Hide the Keyboard",
                subtitle: "Opens the Board ready to write in its composer",
                aliases: ["teclado", "mostrar u ocultar el teclado", "keyboard", "board"],
                keywords: ["board", "panel", "show", "hide", "toggle", "write"],
                symbolName: "keyboard",
                category: .board,
                policy: .invoke,
                showsInPalette: true),
            NumaActionDescriptor(
                id: .focusComposer,
                title: "Write in the Composer",
                subtitle: "Focus the Board draft for the physical keyboard",
                aliases: ["borrador", "escribir en el borrador", "draft"],
                keywords: ["composer", "focus", "write", "type"],
                symbolName: "square.and.pencil",
                category: .board,
                policy: .invoke,
                showsInPalette: false),
            NumaActionDescriptor(
                id: .sendDraft,
                title: "Send the Draft",
                subtitle: "Insert the Board draft into the focused app",
                aliases: ["enviar el borrador", "enviar"],
                keywords: ["send", "insert", "deliver", "draft"],
                symbolName: "paperplane",
                category: .board,
                policy: .invoke,
                showsInPalette: false),
            NumaActionDescriptor(
                id: .toggleHandsFreeDictation,
                title: "Start or Stop Hands-Free Dictation",
                subtitle: "Local dictation that ends on silence or a stop",
                aliases: ["dictado", "manos libres", "grabar audio", "grabar"],
                keywords: ["dictation", "record", "voice", "microphone", "whisper", "stop"],
                symbolName: "mic",
                category: .dictation,
                policy: .invoke,
                showsInPalette: true),
            NumaActionDescriptor(
                id: .pushToTalk,
                title: "Push-to-Talk Dictation",
                subtitle: "Hold its shortcut and speak; release to transcribe",
                aliases: ["dictado mantenido", "pulsar para hablar"],
                keywords: ["dictation", "hold", "talk", "voice"],
                symbolName: "mic.fill",
                category: .dictation,
                policy: .pressRelease(
                    oneShotExplanation: "Runs by holding its shortcut, not from here"),
                showsInPalette: false),
            NumaActionDescriptor(
                id: .transformText,
                title: "Transform Focused Text",
                subtitle: "Rewrite the selection or draft with an instruction",
                aliases: ["transformar texto enfocado", "transformar", "instrucción"],
                keywords: ["transform", "rewrite", "ai", "instruction", "selection"],
                symbolName: "wand.and.stars",
                category: .text,
                policy: .invoke,
                showsInPalette: false),
            NumaActionDescriptor(
                id: .toggleAttention,
                title: "Pause or Resume Numa Attention",
                subtitle: "Toggle the always-on voice listener",
                aliases: ["pausar escucha", "reanudar escucha", "atención"],
                keywords: ["attention", "pause", "resume", "listen", "voice"],
                symbolName: "ear",
                category: .attention,
                policy: .invoke,
                showsInPalette: true),
            NumaActionDescriptor(
                id: .manageWorkspaceProfiles,
                title: "Manage Workspace Profiles",
                subtitle: "Inspect, update or apply saved workspace layouts",
                aliases: ["workspace profiles", "profiles", "desktops", "layouts"],
                keywords: ["workspace", "profile", "spaces", "desktop", "layout", "apply"],
                symbolName: "rectangle.3.group",
                category: .system,
                policy: .invoke,
                showsInPalette: true),
            NumaActionDescriptor(
                id: .openSettings,
                title: "Open Settings",
                subtitle: "Numa preferences, shortcuts and voice commands",
                aliases: ["ajustes", "preferencias"],
                keywords: ["settings", "preferences", "configure", "options"],
                symbolName: "gearshape",
                category: .system,
                policy: .invoke,
                showsInPalette: true),
            NumaActionDescriptor(
                id: .togglePalette,
                title: "Command Palette",
                subtitle: "Open or close the action palette",
                aliases: ["paleta de comandos", "paleta"],
                keywords: ["palette", "command", "actions", "launcher"],
                symbolName: "command",
                category: .system,
                policy: .invoke,
                showsInPalette: false)
        ]
    }
}
