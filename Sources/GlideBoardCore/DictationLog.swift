import Foundation

/// Append-only diagnostics for dictation targeting and delivery. The unified
/// log redacts our dynamic strings as <private>, which made field failures
/// invisible; a plain file under Application Support keeps the evidence.
enum DictationLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("GlideBoard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dictation-log.txt")
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

    /// One overwrite-on-rotate generation is enough history for debugging.
    private static func rotateIfNeeded() {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int,
              size > maxBytes else { return }
        let old = url.deletingLastPathComponent().appendingPathComponent("dictation-log.old.txt")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}
