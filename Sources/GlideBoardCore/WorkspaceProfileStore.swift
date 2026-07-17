import Foundation

/// Versioned JSON persistence for workspace profiles. The visible product is
/// Numa but the support directory stays `GlideBoard`, like every other store.
final class WorkspaceProfileStore {
    private struct Document: Codable {
        var schemaVersion: Int
        var profiles: [WorkspaceProfile]
    }

    private let url: URL
    private(set) var profiles: [WorkspaceProfile] = []
    /// Set when the file exists but cannot be used; saving is refused so a
    /// newer schema or corrupt document is never silently overwritten.
    private(set) var loadFailure: String?

    /// `directory` overrides the Application Support location (tests use a
    /// temporary folder so runs never touch — or depend on — real user data).
    init(directory: URL? = nil) {
        let support = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask)[0]
                .appendingPathComponent("GlideBoard", isDirectory: true)
        try? FileManager.default.createDirectory(at: support,
                                                 withIntermediateDirectories: true)
        url = support.appendingPathComponent("workspace_profiles.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(Document.self, from: data) else {
            loadFailure = "workspace_profiles.json is unreadable; fix or delete it"
            return
        }
        guard document.schemaVersion <= WorkspaceSchema.version else {
            loadFailure = "workspace_profiles.json uses schema \(document.schemaVersion); "
                + "this build understands up to \(WorkspaceSchema.version)"
            return
        }
        profiles = migrate(document).profiles
    }

    private func migrate(_ document: Document) -> Document {
        var document = document
        document.schemaVersion = WorkspaceSchema.version
        return document
    }

    @discardableResult
    private func persist() -> Bool {
        guard loadFailure == nil else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let document = Document(schemaVersion: WorkspaceSchema.version, profiles: profiles)
        guard let data = try? encoder.encode(document) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    func profile(id: UUID) -> WorkspaceProfile? {
        profiles.first { $0.id == id }
    }

    @discardableResult
    func save(_ profile: WorkspaceProfile) -> Bool {
        var profile = profile
        profile.updatedAt = Date()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        return persist()
    }

    @discardableResult
    func rename(id: UUID, to name: String) -> Bool {
        guard var profile = profile(id: id) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        profile.name = trimmed
        return save(profile)
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        let before = profiles.count
        profiles.removeAll { $0.id == id }
        guard profiles.count != before else { return false }
        return persist()
    }
}
