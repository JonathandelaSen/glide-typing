import AppKit

/// Status-menu and settings coordination for workspace profiles. All work
/// funnels through the services; this type owns menus, alerts, and windows.
@MainActor
final class WorkspaceProfilesController: NSObject, NSMenuDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    private let spaceManager: SpaceManaging
    private let store: WorkspaceProfileStore
    private let catalog: WorkspaceWindowCatalog
    private let recipes: WorkspaceWindowRecipeRegistry
    private let launcher: WorkspaceApplicationLauncher
    private let undoStore: WorkspaceUndoStore
    private let captureService: WorkspaceCaptureService
    private let executor: WorkspaceProfileExecutor

    private var busy = false
    private var lastAppliedProfile: WorkspaceProfile?
    private var reportController: WorkspaceApplyReportWindowController?

    private var manageWindow: NSWindow?
    private var profilesTable: NSTableView?
    private var rulesTable: NSTableView?
    private var detailLabel: NSTextField?
    private var diagnosticsLabel: NSTextField?
    private var applyButton: NSButton?

    init(spaceManager: SpaceManaging = CGSSpaceManager(),
         store: WorkspaceProfileStore = WorkspaceProfileStore()) {
        self.spaceManager = spaceManager
        self.store = store
        let catalog = WorkspaceWindowCatalog()
        let recipes = WorkspaceWindowRecipeRegistry.standard()
        self.catalog = catalog
        self.recipes = recipes
        self.launcher = WorkspaceApplicationLauncher()
        self.undoStore = WorkspaceUndoStore()
        self.captureService = WorkspaceCaptureService(
            spaceManager: spaceManager, catalog: catalog, recipes: recipes)
        self.executor = WorkspaceProfileExecutor(
            spaceManager: spaceManager, catalog: catalog,
            launcher: launcher, recipes: recipes, undoStore: undoStore,
            mover: WorkspaceWindowMover(spaceManager: spaceManager, catalog: catalog))
        super.init()
    }

    // MARK: - Status menu

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Workspace Profiles", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Workspace Profiles")
        menu.autoenablesItems = false
        menu.delegate = self
        item.submenu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        WorkspaceLog.write("menu open: \(store.profiles.count) profiles, busy=\(busy)")

        if case .unavailable(let reason) = spaceManager.capability {
            let unavailable = NSMenuItem(title: "Unavailable on this macOS build",
                                         action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            unavailable.toolTip = reason
            menu.addItem(unavailable)
            addDiagnosticsItem(to: menu)
            return
        }
        if busy {
            let working = NSMenuItem(title: "Working…", action: nil, keyEquivalent: "")
            working.isEnabled = false
            menu.addItem(working)
            menu.addItem(.separator())
        }

        let current = DisplayConfigurationResolver.currentSignature(
            spaceManager: spaceManager)
        if store.profiles.isEmpty {
            let empty = NSMenuItem(title: "No saved profiles", action: nil,
                                   keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for profile in store.profiles {
            let item = NSMenuItem(title: profile.name,
                                  action: #selector(applyProfileItem(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            let mismatches = DisplayConfigurationResolver.mismatchReasons(
                saved: profile.display, current: current)
            item.isEnabled = mismatches.isEmpty && !busy
            if !mismatches.isEmpty {
                item.toolTip = mismatches.joined(separator: "\n")
                WorkspaceLog.write("menu: \"\(profile.name)\" disabled: "
                    + mismatches.joined(separator: "; "))
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let save = NSMenuItem(title: "Save Current Layout…",
                              action: #selector(saveCurrentLayout),
                              keyEquivalent: "")
        save.target = self
        save.isEnabled = !busy
        let issues = DisplayConfigurationResolver.currentPrerequisiteIssues()
        if !issues.isEmpty {
            save.toolTip = issues.joined(separator: "\n")
        }
        menu.addItem(save)

        if let snapshot = undoStore.latest {
            let undo = NSMenuItem(title: "Undo Last Apply (\(snapshot.profileName))",
                                  action: #selector(undoLastApply), keyEquivalent: "")
            undo.target = self
            undo.isEnabled = !busy
            menu.addItem(undo)
        }

        let manage = NSMenuItem(title: "Manage Profiles…",
                                action: #selector(manageProfiles), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
        addDiagnosticsItem(to: menu)
    }

    private func addDiagnosticsItem(to menu: NSMenu) {
        menu.addItem(.separator())
        let log = NSMenuItem(title: "Open Diagnostics Log",
                             action: #selector(openDiagnosticsLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)
    }

    @objc private func openDiagnosticsLog() {
        WorkspaceLog.write("diagnostics log opened from the menu")
        NSWorkspace.shared.open(WorkspaceLog.url)
    }

    // MARK: - Apply

    @objc private func applyProfileItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let profile = store.profile(id: id) else {
            WorkspaceLog.write("apply click ignored: menu item lost its profile")
            return
        }
        WorkspaceLog.write("apply click: \"\(profile.name)\"")
        lastAppliedProfile = profile
        runApply(profile: profile, limitTo: nil)
    }

    private func runApply(profile: WorkspaceProfile, limitTo: Set<UUID>?) {
        guard !busy else {
            WorkspaceLog.write("apply ignored: another operation is running")
            return
        }
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            let report = await self.executor.apply(profile, limitToRuleIDs: limitTo)
            self.setBusy(false)
            self.refreshManageWindow()
            WorkspaceLog.write("report shown: \(report.headline)")
            self.presentReport(report, mergingIntoPrevious: limitTo != nil)
        }
    }

    private func presentReport(_ report: WorkspaceApplyReport, mergingIntoPrevious: Bool) {
        var effective = report
        if mergingIntoPrevious,
           var previous = reportController?.report,
           previous.profileID == report.profileID {
            for result in report.results {
                if let index = previous.results.firstIndex(
                    where: { $0.rule.id == result.rule.id }) {
                    previous.results[index] = result
                } else {
                    previous.results.append(result)
                }
            }
            previous.finishedAt = report.finishedAt
            previous.diagnostics = report.diagnostics
            effective = previous
        }
        if reportController == nil {
            reportController = WorkspaceApplyReportWindowController { [weak self] rule in
                guard let self, let profile = self.lastAppliedProfile else { return }
                self.runApply(profile: profile, limitTo: [rule.id])
            }
        }
        reportController?.show(effective)
    }

    // MARK: - Capture

    @objc private func saveCurrentLayout() {
        capture(into: nil)
    }

    private func capture(into existing: WorkspaceProfile?) {
        guard !busy else {
            WorkspaceLog.write("capture ignored: another operation is running")
            return
        }
        WorkspaceLog.write("capture click"
            + (existing.map { " (updating \"\($0.name)\")" } ?? ""))
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                let name = existing?.name ?? "Profile \(self.store.profiles.count + 1)"
                let result = try await self.captureService.captureMainDisplay(named: name)
                self.setBusy(false)
                self.presentCapturePreview(result, updating: existing)
            } catch {
                self.setBusy(false)
                WorkspaceLog.write("capture failed: \(error)")
                self.presentError(title: "Capture failed",
                                  message: String(describing: error))
            }
        }
    }

    private func presentCapturePreview(_ result: WorkspaceCaptureService.CaptureResult,
                                       updating existing: WorkspaceProfile?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = existing.map { "Update “\($0.name)” with this layout?" }
            ?? "Save this layout as a profile?"
        var lines = result.summaryLines
        if !result.diagnostics.isEmpty {
            lines.append("")
            lines.append(contentsOf: result.diagnostics.map { "⚠ \($0)" })
        }
        alert.informativeText = lines.joined(separator: "\n")
        var nameField: NSTextField?
        if existing == nil {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.stringValue = result.profile.name
            field.placeholderString = "Profile name"
            alert.accessoryView = field
            nameField = field
        }
        alert.addButton(withTitle: existing == nil ? "Save Profile" : "Update Profile")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            WorkspaceLog.write("capture discarded from the preview")
            return
        }
        let saved: Bool
        let savedName: String
        if var existing {
            existing.display = result.profile.display
            existing.rules = result.profile.rules
            saved = store.save(existing)
            savedName = existing.name
        } else {
            var profile = result.profile
            if let name = nameField?.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                profile.name = name
            }
            saved = store.save(profile)
            savedName = profile.name
        }
        WorkspaceLog.write("profile \"\(savedName)\" "
            + (saved ? "saved" : "NOT saved: \(store.loadFailure ?? "write failed")"))
        if !saved {
            presentError(title: "The profile could not be saved",
                         message: store.loadFailure
                            ?? "Writing workspace_profiles.json failed")
        }
        refreshManageWindow()
    }

    // MARK: - Undo

    @objc private func undoLastApply() {
        guard !busy else { return }
        WorkspaceLog.write("undo click")
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            let lines = await self.executor.undoLastApply()
            self.setBusy(false)
            self.presentInfo(title: "Undo Last Apply",
                             message: lines.joined(separator: "\n"))
        }
    }

    // MARK: - Manage window

    @objc private func manageProfiles() {
        showManager()
    }

    func showManager() {
        if manageWindow == nil {
            buildManageWindow()
        }
        refreshManageWindow()
        NSApp.activate(ignoringOtherApps: true)
        manageWindow?.makeKeyAndOrderFront(nil)
    }

    private func buildManageWindow() {
        let profilesTable = makeTable(identifier: "profiles",
                                      columns: [("name", "Profile", 180)])
        let rulesTable = makeTable(identifier: "rules", columns: [
            ("slot", "Window", 170), ("space", "Space", 50),
            ("front", "Front", 44), ("state", "State", 80),
        ])
        self.profilesTable = profilesTable
        self.rulesTable = rulesTable

        let detail = NSTextField(wrappingLabelWithString: "")
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel = detail

        let diagnostics = NSTextField(wrappingLabelWithString: "")
        diagnostics.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        diagnostics.textColor = .secondaryLabelColor
        diagnosticsLabel = diagnostics

        func button(_ title: String, _ action: Selector) -> NSButton {
            let control = NSButton(title: title, target: self, action: action)
            control.bezelStyle = .rounded
            control.controlSize = .small
            return control
        }
        let apply = button("Apply Profile", #selector(applySelectedProfile))
        applyButton = apply
        let profileButtons = NSStackView(views: [
            button("Rename…", #selector(renameSelectedProfile)),
            button("Update from Current Layout…", #selector(updateSelectedProfile)),
            button("Delete…", #selector(deleteSelectedProfile)),
        ])
        profileButtons.spacing = 6
        let ruleButtons = NSStackView(views: [
            button("Exclude / Include", #selector(toggleSelectedRuleExcluded)),
            button("Make Front Window", #selector(makeSelectedRuleFront)),
        ])
        ruleButtons.spacing = 6

        let right = NSStackView(views: [
            detail, wrapInScroll(rulesTable, height: 180), ruleButtons,
            apply, profileButtons, diagnostics,
        ])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 8

        let split = NSStackView(views: [wrapInScroll(profilesTable, height: 300), right])
        split.orientation = .horizontal
        split.alignment = .top
        split.spacing = 10
        split.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        split.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            profilesTable.enclosingScrollView!.widthAnchor.constraint(equalToConstant: 190),
            right.widthAnchor.constraint(equalToConstant: 430),
        ])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered,
                              defer: false)
        window.title = "Numa — Workspace Profiles"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.center()
        manageWindow = window
    }

    private func makeTable(identifier: String,
                           columns: [(id: String, title: String, width: CGFloat)])
        -> NSTableView {
        let table = NSTableView()
        table.identifier = NSUserInterfaceItemIdentifier(identifier)
        for column in columns {
            let tableColumn = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            table.addTableColumn(tableColumn)
        }
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        return table
    }

    private func wrapInScroll(_ table: NSTableView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    private var selectedProfile: WorkspaceProfile? {
        guard let row = profilesTable?.selectedRow, row >= 0,
              row < store.profiles.count else { return nil }
        return store.profiles[row]
    }

    private var selectedRule: WorkspaceWindowRule? {
        guard let profile = selectedProfile,
              let row = rulesTable?.selectedRow, row >= 0,
              row < profile.rules.count else { return nil }
        return profile.rules[row]
    }

    private func refreshManageWindow() {
        guard manageWindow != nil else { return }
        profilesTable?.reloadData()
        if profilesTable?.selectedRow == -1, !store.profiles.isEmpty {
            profilesTable?.selectRowIndexes(IndexSet(integer: 0),
                                            byExtendingSelection: false)
        }
        refreshDetail()
    }

    private func refreshDetail() {
        rulesTable?.reloadData()
        var diagnostics = DisplayConfigurationResolver.currentPrerequisiteIssues()
        if case .unavailable(let reason) = spaceManager.capability {
            diagnostics.insert(reason, at: 0)
        }
        if let failure = store.loadFailure {
            diagnostics.insert(failure, at: 0)
        }
        guard let profile = selectedProfile else {
            detailLabel?.stringValue = store.profiles.isEmpty
                ? "No saved profiles. Use “Save Current Layout…” in the status menu."
                : "Select a profile"
            diagnosticsLabel?.stringValue = diagnostics.joined(separator: "\n")
            refreshApplyButton(for: nil)
            return
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var lines = ["\(profile.name) — updated \(formatter.string(from: profile.updatedAt))"]
        let spaceCount = profile.display.displays.first?.userSpaceCount ?? 0
        lines.append(contentsOf: WorkspaceCaptureService.summaryLines(
            profile: profile, spaceCount: spaceCount))
        let current = DisplayConfigurationResolver.currentSignature(
            spaceManager: spaceManager)
        let mismatches = DisplayConfigurationResolver.mismatchReasons(
            saved: profile.display, current: current)
        if !mismatches.isEmpty {
            diagnostics.append(contentsOf: mismatches.map {
                "Not applicable now: \($0)"
            })
        }
        detailLabel?.stringValue = lines.joined(separator: "\n")
        diagnosticsLabel?.stringValue = diagnostics.joined(separator: "\n")
        refreshApplyButton(for: profile)
    }

    private func refreshApplyButton(for profile: WorkspaceProfile?) {
        let reason = applyBlockReason(for: profile)
        applyButton?.isEnabled = reason == nil
        applyButton?.toolTip = reason
    }

    private func setBusy(_ value: Bool) {
        busy = value
        refreshApplyButton(for: selectedProfile)
    }

    private func applyBlockReason(for profile: WorkspaceProfile?) -> String? {
        if busy { return "Another workspace operation is running" }
        guard let profile else { return "Select a profile to apply" }
        if case .unavailable(let reason) = spaceManager.capability { return reason }
        let current = DisplayConfigurationResolver.currentSignature(
            spaceManager: spaceManager)
        let mismatches = DisplayConfigurationResolver.mismatchReasons(
            saved: profile.display, current: current)
        return mismatches.isEmpty ? nil : mismatches.joined(separator: "\n")
    }

    @objc private func applySelectedProfile() {
        guard let profile = selectedProfile,
              applyBlockReason(for: profile) == nil else { return }
        WorkspaceLog.write("apply click from manager: \"\(profile.name)\"")
        lastAppliedProfile = profile
        runApply(profile: profile, limitTo: nil)
    }

    @objc private func renameSelectedProfile() {
        guard let profile = selectedProfile else { return }
        let alert = NSAlert()
        alert.messageText = "Rename “\(profile.name)”"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = profile.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.rename(id: profile.id, to: field.stringValue)
        refreshManageWindow()
    }

    @objc private func updateSelectedProfile() {
        guard let profile = selectedProfile else { return }
        capture(into: profile)
    }

    @objc private func deleteSelectedProfile() {
        guard let profile = selectedProfile else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(profile.name)”?"
        alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.delete(id: profile.id)
        refreshManageWindow()
    }

    @objc private func toggleSelectedRuleExcluded() {
        guard var profile = selectedProfile, let rule = selectedRule,
              let index = profile.rules.firstIndex(where: { $0.id == rule.id })
        else { return }
        profile.rules[index].isExcluded.toggle()
        store.save(profile)
        refreshDetail()
    }

    @objc private func makeSelectedRuleFront() {
        guard var profile = selectedProfile, let rule = selectedRule else { return }
        profile.promoteRuleToFront(rule.id)
        store.save(profile)
        refreshDetail()
    }

    // MARK: - Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === profilesTable { return store.profiles.count }
        return selectedProfile?.rules.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let text: String
        if tableView === profilesTable {
            guard row < store.profiles.count else { return nil }
            text = store.profiles[row].name
        } else {
            guard let rules = selectedProfile?.rules, row < rules.count else { return nil }
            let rule = rules[row]
            switch tableColumn?.identifier.rawValue {
            case "slot": text = rule.slotName
            case "space": text = "\(rule.spaceOrdinal)"
            case "front": text = rule.isFrontWindow ? "●" : ""
            case "state": text = rule.isExcluded ? "excluded" : ""
            default: text = ""
            }
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === profilesTable {
            refreshDetail()
        }
    }

    // MARK: - Alerts

    private func presentError(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func presentInfo(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

/// Per-window result summary with individual retry, shown after every apply.
@MainActor
final class WorkspaceApplyReportWindowController: NSObject, NSTableViewDataSource,
    NSTableViewDelegate {
    private(set) var report: WorkspaceApplyReport?
    private let onRetry: (WorkspaceWindowRule) -> Void
    private var window: NSWindow?
    private var table: NSTableView?
    private var headlineLabel: NSTextField?
    private var diagnosticsLabel: NSTextField?
    private var retryButton: NSButton?

    init(onRetry: @escaping (WorkspaceWindowRule) -> Void) {
        self.onRetry = onRetry
        super.init()
    }

    func show(_ report: WorkspaceApplyReport) {
        self.report = report
        if window == nil {
            build()
        }
        window?.title = "Numa — \(report.profileName)"
        headlineLabel?.stringValue = report.headline
        var extraLines = report.diagnostics
        if !report.extraWindows.isEmpty {
            let extras = report.extraWindows
                .map { $0.title?.isEmpty == false ? $0.title! : $0.bundleID }
                .joined(separator: ", ")
            extraLines.append("Untouched extra windows: \(extras)")
        }
        diagnosticsLabel?.stringValue = extraLines.joined(separator: "\n")
        table?.reloadData()
        refreshRetryButton()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let table = NSTableView()
        let slot = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("slot"))
        slot.title = "Window"
        slot.width = 150
        let space = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("space"))
        space.title = "Space"
        space.width = 44
        let outcome = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("outcome"))
        outcome.title = "Result"
        outcome.width = 290
        table.addTableColumn(slot)
        table.addTableColumn(space)
        table.addTableColumn(outcome)
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        self.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true

        let headline = NSTextField(wrappingLabelWithString: "")
        headline.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        headlineLabel = headline

        let diagnostics = NSTextField(wrappingLabelWithString: "")
        diagnostics.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        diagnostics.textColor = .secondaryLabelColor
        diagnosticsLabel = diagnostics

        let retry = NSButton(title: "Retry Selected", target: self,
                             action: #selector(retrySelected))
        retry.bezelStyle = .rounded
        retry.isEnabled = false
        retryButton = retry

        let stack = NSStackView(views: [headline, scroll, retry, diagnostics])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: 520),
        ])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered,
                              defer: false)
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
    }

    private func refreshRetryButton() {
        guard let report, let row = table?.selectedRow, row >= 0,
              row < report.results.count else {
            retryButton?.isEnabled = false
            return
        }
        retryButton?.isEnabled = report.results[row].outcome.isFailure
    }

    @objc private func retrySelected() {
        guard let report, let row = table?.selectedRow, row >= 0,
              row < report.results.count else { return }
        onRetry(report.results[row].rule)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        report?.results.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let result = report?.results[safe: row] else { return nil }
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "slot": text = result.rule.slotName
        case "space": text = "\(result.rule.spaceOrdinal)"
        default: text = result.outcome.label
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        if tableColumn?.identifier.rawValue == "outcome",
           result.outcome.isFailure {
            label.textColor = .systemRed
        }
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshRetryButton()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
