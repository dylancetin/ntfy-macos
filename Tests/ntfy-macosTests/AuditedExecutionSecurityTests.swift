import XCTest
import Darwin
@testable import ntfy_macos

final class AuditedExecutionSecurityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("audited-execution-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func script(_ source: String) throws -> URL {
        let url = directory.appendingPathComponent("stub-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + source + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func assertNoShortcutFiles(file: StaticString = #filePath, line: UInt = #line) throws {
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix("ntfy-shortcut-") }, file: file, line: line)
    }

    func testShortcutTreatsExistingSensitivePathAsLiteralText() throws {
        let sensitive = directory.appendingPathComponent("private-secret.txt")
        try "DO NOT READ THIS FILE".write(to: sensitive, atomically: true, encoding: .utf8)
        let stub = try script("""
        [ "$1" = run ] && [ "$3" = -i ] || exit 2
        printf '%s' "$4" >&2
        cat "$4"
        """)
        let runner = ScriptRunner(shortcutsExecutable: stub, temporaryDirectory: directory)
        let result = runner.runShortcutSynchronously(named: "Local shortcut", withInput: sensitive.path)
        XCTAssertEqual(result.outcome, .exited)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, sensitive.path)
        XCTAssertNotEqual(result.error, sensitive.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.error))
        XCTAssertEqual(try String(contentsOf: sensitive, encoding: .utf8), "DO NOT READ THIS FILE")
        try assertNoShortcutFiles()
    }

    func testShortcutPreservesEmptyMultilineUnicodeAndMetacharacters() throws {
        let stub = try script("[ \"$#\" -eq 4 ] || exit 2\ncat \"$4\"")
        let runner = ScriptRunner(shortcutsExecutable: stub, temporaryDirectory: directory)
        for input in ["", "first\n'$(printf INJECTED)'\\\"\n日本語 🔔\u{0}last"] {
            let result = runner.runShortcutSynchronously(named: "Test", withInput: input)
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertEqual(result.output, input)
            try assertNoShortcutFiles()
        }
    }

    func testNilShortcutInputDoesNotCreateAFile() throws {
        let stub = try script("[ \"$#\" -eq 2 ]")
        let runner = ScriptRunner(shortcutsExecutable: stub, temporaryDirectory: directory)
        XCTAssertEqual(runner.runShortcutSynchronously(named: "Test", withInput: nil).exitCode, 0)
        try assertNoShortcutFiles()
    }

    func testShortcutInputPermissionsAreOwnerOnly() throws {
        let input = try ShortcutInputFile(text: "payload", temporaryDirectory: directory)
        defer { input.remove() }
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: input.url.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: input.directory.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testShortcutTimeoutKeepsInputUntilTerminationAndThenCleansIt() throws {
        let stub = try script("""
        trap '[ -f "$4" ] && printf retained; exit 0' TERM
        while :; do :; done
        """)
        let executor = BoundedProcessExecutor(timeout: 0.3, terminationGrace: 0.2)
        let runner = ScriptRunner(executor: executor, shortcutsExecutable: stub, temporaryDirectory: directory)
        let result = runner.runShortcutSynchronously(named: "Test", withInput: "literal")
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertEqual(result.output, "retained")
        try assertNoShortcutFiles()
    }

    func testShortcutLaunchFailureCleansInputAndRedactsError() throws {
        let runner = ScriptRunner(shortcutsExecutable: directory.appendingPathComponent("SECRET-missing"),
                                  temporaryDirectory: directory)
        let result = runner.runShortcutSynchronously(named: "SECRET-name", withInput: "SECRET-message")
        XCTAssertEqual(result.outcome, .launchFailed)
        XCTAssertFalse(result.error.contains("SECRET"))
        try assertNoShortcutFiles()
    }

    func testShortcutForcedKillAlsoCleansInput() throws {
        let stub = try script("trap '' TERM\nprintf '%s' \"$4\"\nwhile :; do :; done")
        let executor = BoundedProcessExecutor(timeout: 0.3, terminationGrace: 0.2)
        let runner = ScriptRunner(executor: executor, shortcutsExecutable: stub, temporaryDirectory: directory)
        let result = runner.runShortcutSynchronously(named: "Test", withInput: "literal")
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertTrue(result.output.hasSuffix("/input.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.output))
        try assertNoShortcutFiles()
    }

    func testExecutorDrainsBothPipesAndCapsRetainedOutput() throws {
        let stub = try script("""
        i=0
        while [ "$i" -lt 12000 ]; do
            printf '0123456789abcdef0123456789abcdef'
            printf 'fedcba9876543210fedcba9876543210' >&2
            i=$((i + 1))
        done
        """)
        let executor = BoundedProcessExecutor(timeout: 10, outputLimit: 1024)
        let result = executor.execute { .init(executable: stub, arguments: []) }
        XCTAssertEqual(result.outcome, .exited)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output.utf8.count, 1024)
        XCTAssertEqual(result.error.utf8.count, 1024)
    }

    func testExecutorKillsDirectChildThatIgnoresTermination() throws {
        let stub = try script("trap '' TERM\nprintf '%s' \"$$\"\nwhile :; do :; done")
        let executor = BoundedProcessExecutor(timeout: 0.3, terminationGrace: 0.2)
        let start = Date()
        let result = executor.execute { .init(executable: stub, arguments: []) }
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let pid = try XCTUnwrap(Int32(result.output))
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(executor.execute { .init(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []) }.exitCode, 0)
    }

    func testExecutorRejectsOverflowWithoutPreparingOrQueuingIt() {
        let executor = BoundedProcessExecutor(maxConcurrent: 1)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = expectation(description: "first admitted task completed")
        XCTAssertTrue(executor.submit({
            entered.signal()
            _ = release.wait(timeout: .now() + 3)
            return .init(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        }, completion: { result in
            XCTAssertEqual(result.exitCode, 0)
            done.fulfill()
        }))
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let start = Date()
        for _ in 0..<100 {
            XCTAssertEqual(executor.execute {
                XCTFail("Overflow must not even prepare a request")
                return .init(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
            }.outcome, .rejected)
            XCTAssertFalse(executor.submit({
                XCTFail("Overflow must not queue a request")
                return .init(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
            }, completion: { _ in XCTFail("Rejected jobs cannot complete later") }))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        release.signal()
        wait(for: [done], timeout: 3)
    }

    func testAllRunnerEntryPointsShareTheAdmissionBudget() {
        let executor = BoundedProcessExecutor(maxConcurrent: 1)
        let release = DispatchSemaphore(value: 0)
        let done = expectation(description: "occupied slot released")
        XCTAssertTrue(executor.submit({
            _ = release.wait(timeout: .now() + 3)
            return .init(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        }, completion: { _ in done.fulfill() }))
        let runner = ScriptRunner(executor: executor, shortcutsExecutable: URL(fileURLWithPath: "/missing"),
                                  temporaryDirectory: directory)
        // These harmless calls are all rejected before any process can launch.
        runner.runScript(at: "/usr/bin/true")
        runner.runShortcut(named: "Test", withInput: "payload")
        runner.runAppleScript(source: "return 1")
        runner.runAppleScriptFile(at: "/missing")
        XCTAssertEqual(runner.runScriptSynchronously(at: "/usr/bin/true").exitCode, -1)
        XCTAssertEqual(runner.runShortcutSynchronously(named: "Test", withInput: "payload").outcome, .rejected)
        release.signal()
        wait(for: [done], timeout: 3)
    }
}
