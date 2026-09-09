import Foundation

/// A minimal test harness. No XCTest, no swift-testing: a registry of named
/// closures, assertion helpers that record failures with file/line, and a
/// summary with a non-zero exit code when anything failed.
final class Harness {
    static let shared = Harness()

    struct Failure { let test: String; let message: String; let file: String; let line: Int }

    private(set) var failures: [Failure] = []
    private(set) var ran = 0
    private var current = ""
    private var filter: String?

    func configure(filter: String?) { self.filter = filter }

    func test(_ name: String, _ body: () throws -> Void) {
        if let f = filter, !name.lowercased().contains(f.lowercased()) { return }
        current = name
        ran += 1
        let before = failures.count
        let sw = Date()
        do {
            try body()
        } catch {
            failures.append(Failure(test: name, message: "threw \(error)", file: "", line: 0))
        }
        let ms = Int(Date().timeIntervalSince(sw) * 1000)
        let ok = failures.count == before
        print("\(ok ? "PASS" : "FAIL")  \(name)  (\(ms) ms)")
    }

    func record(_ message: String, file: String, line: Int) {
        failures.append(Failure(test: current, message: message, file: file, line: line))
    }

    func finish() -> Never {
        print("")
        if failures.isEmpty {
            print("\(ran) tests passed")
            exit(0)
        }
        print("\(failures.count) failure(s) in \(ran) tests:")
        for f in failures {
            let loc = f.file.isEmpty ? "" : " [\((f.file as NSString).lastPathComponent):\(f.line)]"
            print("  \(f.test): \(f.message)\(loc)")
        }
        exit(1)
    }
}

func expect(_ cond: @autoclosure () -> Bool, _ message: String = "expected true", file: String = #file, line: Int = #line) {
    if !cond() { Harness.shared.record(message, file: file, line: line) }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #file, line: Int = #line) {
    if a != b { Harness.shared.record("\(message.isEmpty ? "" : message + ": ")\(a) != \(b)", file: file, line: line) }
}

func expectNil<T>(_ v: T?, _ message: String = "expected nil", file: String = #file, line: Int = #line) {
    if v != nil { Harness.shared.record("\(message): got \(v!)", file: file, line: line) }
}

func expectNotNil<T>(_ v: T?, _ message: String = "expected non-nil", file: String = #file, line: Int = #line) {
    if v == nil { Harness.shared.record(message, file: file, line: line) }
}

func expectThrows(_ message: String = "expected an error", file: String = #file, line: Int = #line, _ body: () throws -> Void) {
    do { try body() } catch { return }
    Harness.shared.record(message, file: file, line: line)
}

/// Poll until `cond` holds or the deadline passes. Returns whether it held.
func waitUntil(_ seconds: Double, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if cond() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return cond()
}

func makeTempDir() -> String {
    let dir = NSTemporaryDirectory() + "smbkeeper-tests-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}
