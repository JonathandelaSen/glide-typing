import Foundation

/// Append-only diagnostics for workspace profiles, mirroring DictationLog:
/// the unified log redacts dynamic strings as <private>, so a plain file
/// under Application Support keeps the evidence. Window titles are never
/// logged — bundle IDs, window IDs, Spaces, and frames only.
enum WorkspaceLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("GlideBoard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workspace-log.txt")
    }()

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let maxBytes = 262_144

    static func write(_ message: String) {
        let line = "\(timeFormat.string(from: Date())) [v\(BuildVersion.code)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        rotateIfNeeded()
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func rotateIfNeeded() {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int,
              size > maxBytes else { return }
        let old = url.deletingLastPathComponent()
            .appendingPathComponent("workspace-log.old.txt")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    static func describe(_ rect: CGRect) -> String {
        "(\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))×\(Int(rect.height)))"
    }
}
