import AppKit

struct WorkspaceWindowRecipe {
    let id: String
    let bundleID: String
    let summary: String
    /// Triggers the creation of exactly one window and returns whether the
    /// trigger itself succeeded; the executor verifies the window appears.
    let createWindow: @MainActor (NSRunningApplication) async -> Bool
}

/// Creates missing windows only through explicit per-app recipes. Apps
/// without a recipe launch but never get a synthesized generic Command-N.
final class WorkspaceWindowRecipeRegistry {
    private let recipes: [String: WorkspaceWindowRecipe]

    init(recipes: [WorkspaceWindowRecipe]) {
        var byBundle: [String: WorkspaceWindowRecipe] = [:]
        for recipe in recipes {
            byBundle[recipe.bundleID] = recipe
        }
        self.recipes = byBundle
    }

    var creationRecipeBundleIDs: Set<String> { Set(recipes.keys) }

    func recipe(bundleID: String) -> WorkspaceWindowRecipe? {
        recipes[bundleID]
    }

    func recipeID(bundleID: String) -> String? {
        recipes[bundleID]?.id
    }

    /// The initial app inventory from the plan. Reopening is the documented
    /// way single-window apps restore their main window (the Dock-click
    /// semantic); Brave gets real new windows through the Chromium singleton
    /// (`--new-window` forwarded by a throwaway second instance), and Finder
    /// windows come from revealing the home folder.
    @MainActor
    static func standard() -> WorkspaceWindowRecipeRegistry {
        let reopenBundles = [
            "com.spotify.client",
            "dev.kdrag0n.MacVirt",
            "com.google.antigravity-ide",
            "com.openai.codex",
            "com.anthropic.claudefordesktop",
        ]
        var recipes = reopenBundles.map { bundleID in
            WorkspaceWindowRecipe(
                id: "reopen-main:\(bundleID)",
                bundleID: bundleID,
                summary: "Reopen the app to restore its main window") { app in
                    await Self.reopen(app)
                }
        }
        recipes.append(WorkspaceWindowRecipe(
            id: "brave-new-window",
            bundleID: "com.brave.Browser",
            summary: "Open a new Brave window via --new-window") { app in
                guard let url = app.bundleURL else { return false }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.createsNewApplicationInstance = true
                configuration.arguments = ["--new-window"]
                do {
                    _ = try await NSWorkspace.shared.openApplication(
                        at: url, configuration: configuration)
                    return true
                } catch {
                    return false
                }
            })
        recipes.append(WorkspaceWindowRecipe(
            id: "finder-new-window",
            bundleID: "com.apple.finder",
            summary: "Open a Finder window on the home folder") { _ in
                NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
            })
        return WorkspaceWindowRecipeRegistry(recipes: recipes)
    }

    @MainActor
    private static func reopen(_ app: NSRunningApplication) async -> Bool {
        guard let url = app.bundleURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url,
                                                             configuration: configuration)
            return true
        } catch {
            return false
        }
    }
}
