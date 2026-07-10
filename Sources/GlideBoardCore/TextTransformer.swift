import AppKit

/// Plans A+B — transform/prompt-anywhere. One hotkey opens a small menu at
/// the pointer: predefined transformations of the selection (or whole field,
/// or the board's draft), plus a free-instruction field that generates new
/// text with the AX context of wherever it will land. Predictable transforms
/// write back in place; everything else previews in the board's composer,
/// where it can be edited and iterated before injecting.
final class TextTransformer {
    /// What a transformation reads from — decided once, at hotkey time.
    enum Subject {
        case field(text: String, scope: FocusedFieldReader.SelectionScope)
        /// The board's composer draft (iteration mode: results come back here).
        case draft(text: String)
        /// Nothing to transform; only free instructions make sense.
        case none
    }

    private let provider: () -> CompletionProvider?
    private let targetApp: () -> NSRunningApplication?
    /// The board's draft for iteration mode. The flag asks whether the
    /// composer must hold key focus: true for the ⌘⌥T shortcut (which could
    /// fire from any app), false for the on-board ✨ chip (unambiguously the
    /// board's draft).
    private let composerDraft: (_ requireFocus: Bool) -> String?
    /// Send a result to the board for review/edit before injecting.
    private let preview: (String) -> Void
    /// User-visible status (the board's flash when visible, log otherwise).
    private let notify: (String) -> Void

    private var menu: TransformMenuPanel?
    private var task: Task<Void, Never>?

    init(provider: @escaping () -> CompletionProvider?,
         targetApp: @escaping () -> NSRunningApplication?,
         composerDraft: @escaping (_ requireFocus: Bool) -> String?,
         preview: @escaping (String) -> Void,
         notify: @escaping (String) -> Void) {
        self.provider = provider
        self.targetApp = targetApp
        self.composerDraft = composerDraft
        self.preview = preview
        self.notify = notify
    }

    /// Entry point. `fromBoard` is true for the on-board ✨ chip, which means
    /// the board's draft is the subject whenever it has text. Pressing again
    /// with the menu open dismisses it.
    func begin(fromBoard: Bool = false) {
        if let menu, menu.isVisible {
            closeMenu()
            return
        }
        guard provider() != nil else {
            notify("Transformar: el motor de IA está apagado")
            return
        }

        // Snapshot everything now: once the menu takes key status for its
        // instruction field, AX answers about the target get less reliable.
        let app = targetApp()
        let subject: Subject
        if let draft = composerDraft(!fromBoard) {
            subject = .draft(text: draft)
        } else if let (text, scope) = FocusedFieldReader.transformableText(in: app) {
            subject = .field(text: text, scope: scope)
        } else {
            subject = .none
        }
        let target = FocusedFieldReader.targetDescription(in: app)
        let context = gatherContext(app: app, subject: subject)

        let hasSubject: Bool
        if case .none = subject { hasSubject = false } else { hasSubject = true }
        let menu = TransformMenuPanel(
            actions: TransformAction.allCases,
            history: Array(Settings.promptHistory.prefix(3)),
            showActions: hasSubject,
            onPick: { [weak self] action in
                self?.run(action, subject: subject)
            },
            onInstruction: { [weak self] instruction, direct in
                self?.runInstruction(instruction, subject: subject,
                                     context: context, target: target, direct: direct)
            })
        menu.show(at: NSEvent.mouseLocation)
        self.menu = menu
    }

    /// Field text before the caret plus — with the explicit opt-in and never
    /// in excluded apps — the visible text around the field (chat thread,
    /// quoted mail). Both end up verbatim in the debug console.
    private func gatherContext(app: NSRunningApplication?, subject: Subject) -> String? {
        var parts: [String] = []
        if Settings.surroundingContextEnabled {
            let bundle = app?.bundleIdentifier ?? ""
            let excluded = Settings.surroundingContextExcludedApps
                .contains { bundle.hasPrefix($0) }
            if !excluded, let around = FocusedFieldReader.surroundingContext(in: app) {
                parts.append(around)
            }
        }
        // When iterating the board's draft, the draft travels separately.
        if case .draft = subject {} else if let before = FocusedFieldReader.textBeforeCursor() {
            parts.append(before)
        }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private func closeMenu() {
        menu?.close()
        menu = nil
    }

    private func run(_ action: TransformAction, subject: Subject) {
        guard let provider = provider() else { return }
        let text: String
        switch subject {
        case .field(let t, _): text = t
        case .draft(let t): text = t
        case .none: return
        }
        menu?.showBusy("\(action.title)…")
        QueryLog.shared.currentSource = sourceLabel(for: subject)
        task?.cancel()
        task = Task { @MainActor [weak self] in
            let result = try? await provider.transform(action: action, text: text)
            guard let self, !Task.isCancelled else { return }
            self.closeMenu()
            guard let result else {
                self.notify("Transformar: el modelo no devolvió texto")
                return
            }
            self.deliver(result, subject: subject, inPlace: action.deliversInPlace)
        }
    }

    private func runInstruction(_ instruction: String, subject: Subject,
                                context: String?, target: String?, direct: Bool) {
        guard let provider = provider() else { return }
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        rememberInstruction(trimmed)
        menu?.showBusy("Generando…")
        QueryLog.shared.currentSource = sourceLabel(for: subject)
        var draft: String?
        if case .draft(let t) = subject { draft = t }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            let result = try? await provider.generate(instruction: trimmed, draft: draft,
                                                      context: context, target: target)
            guard let self, !Task.isCancelled else { return }
            self.closeMenu()
            guard let result else {
                self.notify("Instrucción: el modelo no devolvió texto")
                return
            }
            self.deliver(result, subject: subject, inPlace: direct)
        }
    }

    private func deliver(_ result: String, subject: Subject, inPlace: Bool) {
        switch subject {
        case .draft:
            // Iterations over the board's draft always come back to the board.
            preview(result)
        case .field(_, let scope):
            if inPlace {
                applyToField(result, scope: scope)
            } else {
                preview(result)
            }
        case .none:
            if inPlace {
                TextInjector.type(result)
            } else {
                preview(result)
            }
        }
    }

    private func sourceLabel(for subject: Subject) -> String {
        switch subject {
        case .field(_, .selection): return "selección (AX)"
        case .field(_, .wholeField): return "campo (AX)"
        case .draft: return "borrador"
        case .none: return "sin texto previo"
        }
    }

    private func rememberInstruction(_ instruction: String) {
        var history = Settings.promptHistory
        history.removeAll { $0 == instruction }
        history.insert(instruction, at: 0)
        Settings.promptHistory = history
    }

    private func applyToField(_ result: String, scope: FocusedFieldReader.SelectionScope) {
        if FocusedFieldReader.replaceTransformableText(result, scope: scope, in: targetApp()) {
            return
        }
        pasteReplacing(result, selectAllFirst: scope == .wholeField)
    }

    /// AX write not supported by the app: paste over the selection, restoring
    /// the user's clipboard once the target has processed the ⌘V.
    private func pasteReplacing(_ text: String, selectAllFirst: Bool) {
        let snapshot = ClipboardSnapshot()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        var steps: [(key: CGKeyCode, flags: CGEventFlags)] = []
        if selectAllFirst { steps.append((TextInjector.aKey, .maskCommand)) }
        steps.append((TextInjector.vKey, .maskCommand))
        TextInjector.pressSequence(steps)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            snapshot.restore()
        }
    }
}

/// Borderless action menu shown at the pointer. Non-activating, so the target
/// app stays active — it only takes key status (like the board's composer)
/// so its instruction field can receive typing; all AX reads happen before.
final class TransformMenuPanel: NSPanel, NSTextFieldDelegate {
    override var canBecomeKey: Bool { true }

    private let onPick: (TransformAction) -> Void
    private let onInstruction: (String, Bool) -> Void
    private var clickMonitor: Any?
    private let stack = NSStackView()
    private let field = NSTextField()

    init(actions: [TransformAction], history: [String], showActions: Bool,
         onPick: @escaping (TransformAction) -> Void,
         onInstruction: @escaping (String, Bool) -> Void) {
        self.onPick = onPick
        self.onInstruction = onInstruction
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        becomesKeyOnlyIfNeeded = true
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        contentView = background

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor)
        ])

        field.placeholderString = "Instrucción libre…  ⏎ borrador · ⌘⏎ directo"
        field.font = NSFont.systemFont(ofSize: 12)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        stack.addArrangedSubview(field)

        for instruction in history {
            let button = NSButton(title: "↺ " + String(instruction.prefix(40)),
                                  target: self, action: #selector(pickHistory(_:)))
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 11)
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = instruction
            stack.addArrangedSubview(button)
        }

        if showActions {
            let separator = NSBox()
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
            for action in actions {
                let button = NSButton(title: action.title, target: self,
                                      action: #selector(pick(_:)))
                button.isBordered = false
                button.contentTintColor = .labelColor
                button.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
                stack.addArrangedSubview(button)
            }
        }

        // Clicking anywhere in another app dismisses the menu.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    @objc private func pick(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let action = TransformAction(rawValue: id) else { return }
        onPick(action)
    }

    @objc private func pickHistory(_ sender: NSButton) {
        field.stringValue = sender.toolTip ?? ""
        makeFirstResponder(field)
    }

    // Enter submits (⌘ held: direct in-place delivery); Esc closes.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let direct = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            onInstruction(field.stringValue, direct)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        return false
    }

    func show(at screenPoint: NSPoint) {
        layoutIfNeeded()
        let size = stack.fittingSize
        setContentSize(size)
        var origin = NSPoint(x: screenPoint.x + 8, y: screenPoint.y + 12)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(origin.x, visible.maxX - size.width - 4)
            origin.y = min(origin.y, visible.maxY - size.height - 4)
            origin.x = max(origin.x, visible.minX + 4)
            origin.y = max(origin.y, visible.minY + 4)
        }
        setFrameOrigin(origin)
        orderFrontRegardless()
        // Key status (not activation): typing lands in the instruction field
        // while the target app stays active underneath.
        makeKey()
        makeFirstResponder(field)
    }

    /// Replace the whole menu with a progress label while the model runs.
    func showBusy(_ message: String) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let label = NSTextField(labelWithString: message)
        label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)
        layoutIfNeeded()
        setContentSize(stack.fittingSize)
    }

    override func close() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        super.close()
    }
}
