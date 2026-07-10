import Foundation

/// States whether a composer delivery must finish by pressing Return in the
/// destination app after inserting the draft.
enum ComposerDeliveryIntent: Equatable {
    case insertOnly
    case insertAndSubmit

    /// Sending is a two-step gesture everywhere — global hotkey and board
    /// Return alike. With a draft, only insert it into the target so it can
    /// be reviewed before committing; on an empty draft, forward Return so
    /// the target submits what was already inserted.
    static func send(draft: String) -> Self {
        draft.isEmpty ? .insertAndSubmit : .insertOnly
    }

    var pressReturn: Bool {
        self == .insertAndSubmit
    }
}
