import XCTest
@testable import ntfy_macos

final class AuditedLoggerSecurityTests: XCTestCase {
    private var directory: URL!
    private var logs: URL { directory.appendingPathComponent("logs") }
    private var logfile: URL { logs.appendingPathComponent("ntfy-macos.log") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("audited-logger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func permissions(_ url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    func testExistingDirectoriesAndLogFilesBecomeOwnerPrivate() throws {
        let backup = logs.appendingPathComponent("ntfy-macos.log.old")
        for url in [logfile, backup] {
            try "existing\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
        }
        for url in [directory!, logs] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        PrivateRotatingLogger(directory: logs).write("Local diagnostic")
        // Only the dedicated log directory is tightened; existing ancestors are validated.
        XCTAssertEqual(try permissions(directory), 0o755)
        XCTAssertEqual(try permissions(logs), 0o700)
        XCTAssertEqual(try permissions(logfile), 0o600)
        XCTAssertEqual(try permissions(backup), 0o600)
    }

    func testRotationHappensDuringWritesAndBothFilesStayBounded() throws {
        let logger = PrivateRotatingLogger(directory: logs, maxBytes: 256)
        for index in 0..<40 { logger.write("Local event \(index)") }
        let backup = logs.appendingPathComponent("ntfy-macos.log.old")
        for url in [logfile, backup] {
            XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 256)
            XCTAssertEqual(try permissions(url), 0o600)
        }
        XCTAssertTrue(try String(contentsOf: logfile, encoding: .utf8).contains("Local event 39"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: logs.path).count, 2)
    }

    func testConcurrentWritesRemainCompleteSingleLines() throws {
        let logger = PrivateRotatingLogger(directory: logs)
        DispatchQueue.concurrentPerform(iterations: 200) { index in logger.write("event-\(index)") }
        let text = try String(contentsOf: logfile, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 200)
        for index in 0..<200 {
            XCTAssertEqual(lines.filter { $0.hasSuffix("] event-\(index)") }.count, 1)
        }
    }

    func testLargeRecordsAreBoundedAndControlCharactersCannotForgeLines() throws {
        let logger = PrivateRotatingLogger(directory: logs, maxBytes: 256)
        logger.write("first\nforged\r\u{1B}" + String(repeating: "x", count: 100_000))
        let data = try Data(contentsOf: logfile)
        XCTAssertLessThanOrEqual(data.count, 256)
        XCTAssertEqual(data.filter { $0 == 10 }.count, 1)
        XCTAssertFalse(data.contains(13))
        XCTAssertFalse(data.contains(27))
    }

    func testSymlinkLogCannotOverwriteAnotherFile() throws {
        let target = directory.appendingPathComponent("sensitive")
        try "untouched".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: logfile, withDestinationURL: target)
        PrivateRotatingLogger(directory: logs).write("must not follow link")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "untouched")
    }

    func testSymlinkDirectoryIsRejected() throws {
        let destination = directory.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let link = directory.appendingPathComponent("linked-logs")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        PrivateRotatingLogger(directory: link).write("must not follow directory link")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }
}
