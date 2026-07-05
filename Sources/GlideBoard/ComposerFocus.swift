import AppKit

/// A non-activating panel that can still take key status so its composer can
/// receive physical-keyboard input without becoming the active application.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Shows the board and moves keyboard focus to the end of its current draft.
func focusComposer(panel: NSPanel, composer: NSTextView) {
    panel.orderFrontRegardless()
    panel.makeKey()
    panel.makeFirstResponder(composer)
    let end = (composer.string as NSString).length
    composer.setSelectedRange(NSRange(location: end, length: 0))
    composer.scrollRangeToVisible(composer.selectedRange())
}
