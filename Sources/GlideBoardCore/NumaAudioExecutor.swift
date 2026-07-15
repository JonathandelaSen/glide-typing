import Foundation

/// Single FIFO executor for every ring, routing and session-buffer mutation.
/// Capture callbacks only enqueue work here; they never mutate audio state.
final class NumaAudioExecutor: @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String = "com.jon.glideboard.numa.audio") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func enqueue(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }

    func perform<T: Sendable>(_ operation: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: operation())
            }
        }
    }
}
