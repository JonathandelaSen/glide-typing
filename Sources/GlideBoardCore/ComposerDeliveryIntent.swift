import Foundation

/// States whether a composer delivery must finish by pressing Return in the
/// destination app after inserting the draft.
enum ComposerDeliveryIntent: Equatable {
    case insertOnly
    case insertAndSubmit

    /// The global send shortcut is an explicit "send" action. It must submit
    /// after inserting a draft, and still submit when the draft is empty.
    static func globalSend(draft: String) -> Self {
        // The draft is deliberately accepted here so callers make the empty
        // draft case explicit in the same decision point.
        _ = draft
        return .insertAndSubmit
    }

    /// The Return key on the board keeps the existing two-step behavior: the
    /// first Return inserts a draft; a Return on an empty draft submits it.
    static func boardReturn(draft: String) -> Self {
        draft.isEmpty ? .insertAndSubmit : .insertOnly
    }

    var pressReturn: Bool {
        self == .insertAndSubmit
    }
}
