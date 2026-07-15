import AppKit
import Foundation

enum WorkspaceLifecycleBlocker: Hashable {
    case sleeping
    case sessionInactive
    case screensSleeping
}

struct WorkspaceLifecycleBlockers: Equatable {
    private(set) var reasons: Set<WorkspaceLifecycleBlocker> = []
    var isSuspended: Bool { !reasons.isEmpty }

    /// Returns true only when this mutation crosses the suspended boundary.
    mutating func insert(_ reason: WorkspaceLifecycleBlocker) -> Bool {
        let wasSuspended = isSuspended
        reasons.insert(reason)
        return wasSuspended != isSuspended
    }

    mutating func remove(_ reason: WorkspaceLifecycleBlocker) -> Bool {
        let wasSuspended = isSuspended
        reasons.remove(reason)
        return wasSuspended != isSuspended
    }
}

@MainActor
final class WorkspaceLifecycleMonitor {
    private var observers: [NSObjectProtocol] = []
    private var blockers = WorkspaceLifecycleBlockers()
    private let suspendedChanged: (Bool) -> Void

    init(suspendedChanged: @escaping (Bool) -> Void) {
        self.suspendedChanged = suspendedChanged
        let center = NSWorkspace.shared.notificationCenter
        observe(center, NSWorkspace.willSleepNotification, blocker: .sleeping, insert: true)
        observe(center, NSWorkspace.didWakeNotification, blocker: .sleeping, insert: false)
        observe(center, NSWorkspace.sessionDidResignActiveNotification,
                blocker: .sessionInactive, insert: true)
        observe(center, NSWorkspace.sessionDidBecomeActiveNotification,
                blocker: .sessionInactive, insert: false)
        observe(center, NSWorkspace.screensDidSleepNotification,
                blocker: .screensSleeping, insert: true)
        observe(center, NSWorkspace.screensDidWakeNotification,
                blocker: .screensSleeping, insert: false)
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }

    private func observe(_ center: NotificationCenter,
                         _ name: Notification.Name,
                         blocker: WorkspaceLifecycleBlocker,
                         insert: Bool)
    {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let crossed = insert
                    ? blockers.insert(blocker)
                    : blockers.remove(blocker)
                if crossed { suspendedChanged(blockers.isSuspended) }
            }
        })
    }
}
