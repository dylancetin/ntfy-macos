import Foundation
import Darwin

/// Protocol for script execution - enables dependency injection and mocking for tests.
protocol ScriptRunnerProtocol: Sendable {
    func runScript(at path: String, withArgument argument: String?, extraEnv: [String: String]?)
    func validateScript(at path: String) -> Bool
    func runShortcut(named shortcutName: String, withInput input: String?)
    func runAppleScript(source: String)
    func runAppleScriptFile(at path: String)
}

/// One app-wide budget, with no pending-job queue. Output is drained while the child runs,
/// but only a bounded prefix of each stream is retained (and never logged).
final class BoundedProcessExecutor: @unchecked Sendable {
    static let shared = BoundedProcessExecutor()

    struct Request: Sendable {
        let executable: URL
        let arguments: [String]
        var environment: [String: String]? = nil
        var cleanup: @Sendable () -> Void = {}
    }

    struct Result: Sendable {
        enum Outcome: Sendable, Equatable { case exited, timedOut, rejected, launchFailed }
        let outcome: Outcome
        let exitCode: Int32
        var output = ""
        var error = ""
    }

    private let slots: DispatchSemaphore
    private let workers = DispatchQueue(label: "ntfy.processes", qos: .utility, attributes: .concurrent)
    private let timeout: TimeInterval
    private let terminationGrace: TimeInterval
    private let outputLimit: Int

    init(maxConcurrent: Int = 4, timeout: TimeInterval = 30, terminationGrace: TimeInterval = 1,
         outputLimit: Int = 65_536) {
        precondition(maxConcurrent > 0 && timeout > 0 && terminationGrace > 0 && outputLimit >= 0)
        slots = DispatchSemaphore(value: maxConcurrent)
        self.timeout = timeout
        self.terminationGrace = terminationGrace
        self.outputLimit = outputLimit
    }

    @discardableResult
    func submit(_ prepare: @escaping @Sendable () throws -> Request,
                completion: @escaping @Sendable (Result) -> Void) -> Bool {
        guard slots.wait(timeout: .now()) == .success else { return false }
        // Reserve before dispatching, so a burst cannot build an unbounded queue of closures.
        workers.async { _ = self.executeReserved(prepare, completion: completion) }
        return true
    }

    func execute(_ prepare: () throws -> Request) -> Result {
        guard slots.wait(timeout: .now()) == .success else {
            return Result(outcome: .rejected, exitCode: -1, error: "Execution capacity reached")
        }
        return executeReserved(prepare, completion: { _ in })
    }

    /// Cleanup and budget release require BOTH worker completion and direct-child exit.
    /// Even an unexpectedly unreapable child retains its slot and private input file.
    private final class Lifetime: @unchecked Sendable {
        let exited = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var childFinished = false
        private var workerFinished = false
        private var finished = false
        private let cleanup: @Sendable () -> Void

        init(cleanup: @escaping @Sendable () -> Void) { self.cleanup = cleanup }

        func childDidFinish() {
            finish(child: true)
            exited.signal()
        }

        func workerDidFinish() { finish(child: false) }

        private func finish(child: Bool) {
            lock.lock()
            if child { childFinished = true } else { workerFinished = true }
            let shouldClean = childFinished && workerFinished && !finished
            if shouldClean { finished = true }
            lock.unlock()
            if shouldClean { cleanup() }
        }
    }

    private func executeReserved(_ prepare: () throws -> Request, completion: (Result) -> Void) -> Result {
        // Completion (including routine logging) is also covered by the admission slot.
        func finish(_ result: Result) -> Result {
            completion(result)
            return result
        }
        let request: Request
        do { request = try prepare() } catch {
            defer { slots.signal() }
            return finish(Result(outcome: .launchFailed, exitCode: -1, error: "Failed to prepare execution"))
        }
        let lifetime = Lifetime { [slots] in
            request.cleanup()
            slots.signal()
        }
        defer { lifetime.workerDidFinish() }

        let process = Process()
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.environment = request.environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let outFD = stdout.fileHandleForReading.fileDescriptor
        let errFD = stderr.fileHandleForReading.fileDescriptor
        defer {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        }
        guard fcntl(outFD, F_SETFL, O_NONBLOCK) != -1,
              fcntl(errFD, F_SETFL, O_NONBLOCK) != -1 else {
            lifetime.childDidFinish()
            return finish(Result(outcome: .launchFailed, exitCode: -1, error: "Failed to prepare output capture"))
        }
        process.terminationHandler = { _ in lifetime.childDidFinish() }
        do { try process.run() } catch {
            lifetime.childDidFinish()
            return finish(Result(outcome: .launchFailed, exitCode: -1, error: "Failed to execute process"))
        }
        // The child owns its copies. Closing ours also allows EOF after normal termination.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        var output = Data()
        var error = Data()
        func drain(_ descriptor: Int32, into captured: inout Data) {
            var buffer = [UInt8](repeating: 0, count: 8192)
            // Bound work per iteration even when a child writes continuously.
            for _ in 0..<16 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
                if count <= 0 { break }
                let retained = min(count, max(0, outputLimit - captured.count))
                if retained > 0 { captured.append(contentsOf: buffer.prefix(retained)) }
            }
        }
        func wait(until deadline: DispatchTime) -> Bool {
            while true {
                drain(outFD, into: &output)
                drain(errFD, into: &error)
                if lifetime.exited.wait(timeout: .now()) == .success { return true }
                if DispatchTime.now() >= deadline { return false }
                if lifetime.exited.wait(timeout: min(deadline, .now() + .milliseconds(10))) == .success {
                    return true
                }
            }
        }

        let completed = wait(until: .now() + timeout)
        if !completed {
            if process.isRunning { process.terminate() }
            if !wait(until: .now() + terminationGrace) {
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                _ = wait(until: .now() + terminationGrace)
            }
        }
        drain(outFD, into: &output)
        drain(errFD, into: &error)
        // Foundation does not establish a separate process group. Only the direct child is
        // terminated; trusted scripts must not daemonize. Descendants may outlive the budget.
        // Never wait for descendant-held pipes to reach EOF.
        return finish(Result(outcome: completed ? .exited : .timedOut,
                             exitCode: completed ? process.terminationStatus : -1,
                             output: String(decoding: output, as: UTF8.self),
                             error: completed ? String(decoding: error, as: UTF8.self) : "Execution timed out"))
    }
}

/// `shortcuts -i` accepts a FILE, not literal text. Use a fresh private directory and text
/// file, and retain them until the launched process has exited, including timeout paths.
final class ShortcutInputFile: @unchecked Sendable {
    let directory: URL
    let url: URL

    init(text: String, temporaryDirectory: URL) throws {
        var template = Array(temporaryDirectory.appendingPathComponent("ntfy-shortcut-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw CocoaError(.fileWriteUnknown) }
        directory = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        url = directory.appendingPathComponent("input.txt")
        do {
            let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { Darwin.close(directoryFD) }
            var status = stat()
            guard fstat(directoryFD, &status) == 0, status.st_uid == geteuid(),
                  fchmod(directoryFD, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
            try PrivateFileAccess.removeACL(on: directoryFD)
            let descriptor = openat(directoryFD, "input.txt", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            try PrivateFileAccess.removeACL(on: descriptor)
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

final class ScriptRunner: ScriptRunnerProtocol, @unchecked Sendable {
    private let enhancedPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    private let executor: BoundedProcessExecutor
    private let shortcutsExecutable: URL
    private let temporaryDirectory: URL

    init(executor: BoundedProcessExecutor = .shared,
         shortcutsExecutable: URL = URL(fileURLWithPath: "/usr/bin/shortcuts"),
         temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.executor = executor
        self.shortcutsExecutable = shortcutsExecutable
        self.temporaryDirectory = temporaryDirectory
    }

    private func extractScriptPath(from command: String) -> String? {
        guard let first = command.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        return String(first)
    }

    private func scriptRequest(_ command: String, argument: String?, extraEnv: [String: String]?) -> BoundedProcessExecutor.Request {
        // The local configuration is trusted shell source. Notification text is one literal
        // argument: close the single quote, escape a quote, then reopen it.
        let suffix = argument.map { " '" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" } ?? ""
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = enhancedPATH
        if let extraEnv { environment.merge(extraEnv) { _, new in new } }
        return .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command + suffix], environment: environment)
    }

    private func shortcutRequest(_ name: String, input: String?) throws -> BoundedProcessExecutor.Request {
        var request = BoundedProcessExecutor.Request(executable: shortcutsExecutable, arguments: ["run", name])
        if let input {
            let file = try ShortcutInputFile(text: input, temporaryDirectory: temporaryDirectory)
            request = .init(executable: shortcutsExecutable, arguments: ["run", name, "-i", file.url.path], cleanup: { file.remove() })
        }
        return request
    }

    private func submit(_ prepare: @escaping @Sendable () throws -> BoundedProcessExecutor.Request) {
        executor.submit(prepare) { result in
            // Do not log names, commands, arguments, paths, output, or underlying error text.
            switch result.outcome {
            case .exited:
                if result.exitCode == 0 { Log.success("Action completed") }
                else { Log.error("Action failed") }
            case .timedOut: Log.error("Action timed out")
            case .launchFailed: Log.error("Action could not start")
            case .rejected: break
            }
        }
        // Overflow is intentionally silent: a remote burst must not create a log flood.
    }

    func runScript(at path: String, withArgument argument: String? = nil, extraEnv: [String: String]? = nil) {
        submit { self.scriptRequest(path, argument: argument, extraEnv: extraEnv) }
    }

    func validateScript(at path: String) -> Bool {
        guard let scriptPath = extractScriptPath(from: path) else { return false }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: scriptPath, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: scriptPath)
    }

    func runShortcut(named shortcutName: String, withInput input: String? = nil) {
        submit { try self.shortcutRequest(shortcutName, input: input) }
    }

    func runAppleScript(source: String) {
        submit { .init(executable: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", source]) }
    }

    func runAppleScriptFile(at path: String) {
        submit { .init(executable: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: [path]) }
    }

    func runShortcutSynchronously(named name: String, withInput input: String?) -> BoundedProcessExecutor.Result {
        executor.execute { try shortcutRequest(name, input: input) }
    }

    /// Bounded output is returned to the caller for testing, never written to routine logs.
    func runScriptSynchronously(at path: String, withArgument argument: String? = nil,
                                extraEnv: [String: String]? = nil) -> (exitCode: Int32, output: String, error: String) {
        guard let scriptPath = extractScriptPath(from: path),
              FileManager.default.fileExists(atPath: scriptPath) else {
            return (-1, "", "Failed to execute: Script not found")
        }
        let result = executor.execute { scriptRequest(path, argument: argument, extraEnv: extraEnv) }
        return (result.exitCode, result.output, result.error)
    }
}
