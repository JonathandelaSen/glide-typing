import Foundation

/// Minimal test harness. The Command Line Tools toolchain ships neither
/// XCTest nor swift-testing, so checks run as a plain debug executable:
/// each suite is a function of named closures, assertions throw, and the
/// process exits non-zero when anything fails. Assertion names mirror
/// XCTest semantics so a future migration to a real framework is mechanical.
struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    let location: String
    var description: String { "\(message) [\(location)]" }
}

@MainActor
final class Checks {
    static let shared = Checks()
    private var passed = 0
    private var failures: [String] = []
    private var suite = ""

    func begin(_ name: String) {
        suite = name
        print("\n== \(name)")
    }

    func test(_ name: String, _ body: @MainActor () async throws -> Void) async {
        do {
            try await body()
            passed += 1
            print("   ok   \(name)")
        } catch {
            failures.append("\(suite) — \(name): \(error)")
            print("   FAIL \(name): \(error)")
        }
    }

    func finish() -> Never {
        if failures.isEmpty {
            print("\nOK — \(passed) checks passed")
            exit(0)
        }
        print("\nFAILED — \(passed) passed, \(failures.count) failed:")
        for failure in failures { print("  · \(failure)") }
        exit(1)
    }
}

func expectTrue(_ condition: Bool, _ message: String = "expected true",
                file: StaticString = #fileID, line: UInt = #line) throws {
    guard condition else {
        throw CheckFailure(message: message, location: "\(file):\(line)")
    }
}

func expectFalse(_ condition: Bool, _ message: String = "expected false",
                 file: StaticString = #fileID, line: UInt = #line) throws {
    try expectTrue(!condition, message, file: file, line: line)
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                               file: StaticString = #fileID, line: UInt = #line) throws {
    guard actual == expected else {
        let prefix = message.isEmpty ? "" : message + " — "
        throw CheckFailure(message: "\(prefix)got \(actual), expected \(expected)",
                           location: "\(file):\(line)")
    }
}

func expectNil<T>(_ value: T?, _ message: String = "expected nil",
                  file: StaticString = #fileID, line: UInt = #line) throws {
    guard value == nil else {
        throw CheckFailure(message: "\(message), got \(value!)",
                           location: "\(file):\(line)")
    }
}

func unwrap<T>(_ value: T?, _ message: String = "unexpected nil",
               file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else {
        throw CheckFailure(message: message, location: "\(file):\(line)")
    }
    return value
}

/// A fresh empty directory under the system temp dir, for modules that
/// persist state (they take a `directory:` override precisely for this).
func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("GlideBoardChecks-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
