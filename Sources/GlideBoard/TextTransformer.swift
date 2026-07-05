import AppKit

/// Plan A — transform-anywhere: reads the selection (or whole field) of the
/// focused app via AX, shows a small action menu at the pointer, asks the
/// model for the transformation, and writes the result back in place.
/// Independent from the ghost pipeline.
final class TextTransformer {
    /// nil when the AI engine is off.
    private let provider: () -> CompletionProvider?
    /// The app whose focused field is being transformed.
    private let targetApp: () -> NSRunningApplication?
    /// User-visible status (the board's flash when visible, log otherwise).
    private let notify: (String) -> Void

    private var menu: TransformMenuPanel?
    private var task: Task<Void, Never>?

    init(provider: @escaping () -> CompletionProvider?,
         targetApp: @escaping () -> NSRunningApplication?,
         notify: @escaping (String) -> Void) {
        self.provider = provider
        self.targetApp = targetApp
        self.notify = notify
    }

    /// Hotkey entry point. Pressing it again with the menu open dismisses it.
    func begin() {
        if let menu, menu.isVisible {
            closeMenu()
            return
        }
        guard provider() != nil else {
            notify("Transformar: el motor de IA está apagado")
            return
        }
        guard let (text, scope) = FocusedFieldReader.transformableText(in: targetApp()) else {
            notify("Transformar: el campo enfocado no expone texto (AX)")
            return
        }
        let menu = TransformMenuPanel(actions: TransformAction.allCases) { [weak self] action in
            self?.run(action, on: text, scope: scope)
        }
        menu.show(at: NSEvent.mouseLocation)
        self.menu = menu
    }

    private func closeMenu() {
        menu?.close()
        menu = nil
    }

    private func run(_ action: TransformAction, on text: String,
                     scope: FocusedFieldReader.SelectionScope) {
        guard let provider = provider() else { return }
        menu?.showBusy("\(action.title)…")
        // The console shows what the transformation operated on — the same
        // signal the plan's phase-1 AX validation matrix needs.
        QueryLog.shared.currentSource = scope == .selection ? "selección (AX)" : "campo (AX)"
        task?.cancel()
        task = Task { @MainActor [weak self] in
            let result = try? await provider.transform(action: action, text: text)
            guard let self, !Task.isCancelled else { return }
            self.closeMenu()
            guard let result else {
                self.notify("Transformar: el modelo no devolvió texto")
                return
            }
            self.apply(result, scope: scope)
        }
    }

    private func apply(_ result: String, scope: FocusedFieldReader.SelectionScope) {
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

/// Borderless, non-activating action menu shown at the pointer. It must never
/// take key status: the target field has to keep the AX focus so the result
/// can be written back to it (same gotcha as the board panel).
final class TransformMenuPanel: NSPanel {
    private let onPick: (TransformAction) -> Void
    private var clickMonitor: Any?
    private let stack = NSStackView()

    init(actions: [TransformAction], onPick: @escaping (TransformAction) -> Void) {
        self.onPick = onPick
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
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor)
        ])
        for action in actions {
            let button = NSButton(title: action.title, target: self,
                                  action: #selector(pick(_:)))
            button.isBordered = false
            button.contentTintColor = .labelColor
            button.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            stack.addArrangedSubview(button)
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
    }

    /// Replace the actions with a single progress label while the model runs.
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
