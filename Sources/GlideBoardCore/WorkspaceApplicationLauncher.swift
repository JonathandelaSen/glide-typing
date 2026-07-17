import AppKit

enum WorkspaceLaunchResult {
    case success(NSRunningApplication)
    case failure(String)
}

/// Resolves bundle IDs to installed apps and launches them without
/// activation, waiting a bounded time for the process to come up.
@MainActor
final class WorkspaceApplicationLauncher {
    func runningApp(bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { !$0.isTerminated }
    }

    func ensureRunning(bundleID: String,
                       timeout: TimeInterval = 15) async -> WorkspaceLaunchResult {
        if let app = runningApp(bundleID: bundleID) {
            return .success(app)
        }
        guard let url = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID) else {
            return .failure("\(bundleID) is not installed")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url,
                                                             configuration: configuration)
        } catch {
            return .failure("Launch failed: \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let app = runningApp(bundleID: bundleID), app.isFinishedLaunching {
                return .success(app)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if let app = runningApp(bundleID: bundleID) {
            return .success(app)
        }
        return .failure("Did not finish launching within \(Int(timeout))s")
    }
}
