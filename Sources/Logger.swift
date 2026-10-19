import Foundation
import Darwin

/// Synchronized, owner-private rotating sink. Callers must supply local diagnostics only:
/// remote notification content, URLs, credentials and process output must not be logged.
final class PrivateRotatingLogger: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let maxBytes: Int
    private let interactive: Bool
    private let formatter: DateFormatter
    private var directoryFD: Int32 = -1
    private var fileFD: Int32 = -1
    private let filename = "ntfy-macos.log"

    init(directory: URL, maxBytes: Int = 1_000_000, interactive: Bool = false) {
        self.directory = directory
        self.maxBytes = max(128, maxBytes)
        self.interactive = interactive
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    deinit {
        if fileFD >= 0 { Darwin.close(fileFD) }
        if directoryFD >= 0 { Darwin.close(directoryFD) }
    }

    func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        // One bounded line per event; control characters cannot forge additional log records.
        let bounded = String(decoding: message.utf8.prefix(4096), as: UTF8.self)
        let escaped = bounded.unicodeScalars.map { scalar -> String in
            if scalar.value < 32 || scalar.value == 127 { return " " }
            return String(scalar)
        }.joined()
        let line = "[\(formatter.string(from: Date()))] \(escaped)\n"
        var data = Data(line.utf8.prefix(maxBytes - 1))
        if data.last != 10 { data.append(10) }
        if interactive {
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
        guard prepareDirectory(), openLog() else { return }
        var status = stat()
        guard fstat(fileFD, &status) == 0 else { return }
        if status.st_size > 0 && status.st_size + off_t(data.count) > off_t(maxBytes) {
            Darwin.close(fileFD)
            fileFD = -1
            // All operations are relative to the verified private directory, never symlinks.
            guard unlinkat(directoryFD, filename + ".old", 0) == 0 || errno == ENOENT,
                  renameat(directoryFD, filename, directoryFD, filename + ".old") == 0,
                  openLog() else { return }
        }
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fileFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                offset += count
            }
        }
    }

    private func prepareDirectory() -> Bool {
        if directoryFD >= 0 { return true }
        let components = directory.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return false }
        guard let descriptor = try? SecureConfigFile.openPrivateDirectory(at: directory.path, create: true) else { return false }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_uid == geteuid(),
              fchmod(descriptor, 0o700) == 0 else { Darwin.close(descriptor); return false }
        do { try PrivateFileAccess.removeACL(on: descriptor) }
        catch { Darwin.close(descriptor); return false }
        directoryFD = descriptor
        // Correct permissions on an existing rotated log, too. Refuse symlinks/hard links.
        let backup = openat(directoryFD, filename + ".old", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if backup >= 0 {
            let valid = secureFile(backup)
            Darwin.close(backup)
            if !valid { Darwin.close(directoryFD); directoryFD = -1; return false }
        } else if errno != ENOENT {
            Darwin.close(directoryFD)
            directoryFD = -1
            return false
        }
        return true
    }

    private func secureFile(_ descriptor: Int32) -> Bool {
        var status = stat()
        guard fstat(descriptor, &status) == 0 && (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && status.st_uid == geteuid() && status.st_nlink == 1 && fchmod(descriptor, 0o600) == 0 else { return false }
        do { try PrivateFileAccess.removeACL(on: descriptor); return true }
        catch { return false }
    }

    private func openLog() -> Bool {
        if fileFD >= 0 { return true }
        let descriptor = openat(directoryFD, filename, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        guard secureFile(descriptor) else { Darwin.close(descriptor); return false }
        fileFD = descriptor
        return true
    }
}

enum Log {
    static let logDirectory = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        .appendingPathComponent(".local/share/ntfy-macos/logs").path
    static let logFilePath = (logDirectory as NSString).appendingPathComponent("ntfy-macos.log")
    private static let sink = PrivateRotatingLogger(directory: URL(fileURLWithPath: logDirectory),
                                                    interactive: isatty(STDOUT_FILENO) != 0)

    static func info(_ message: String) { sink.write(message) }
    static func error(_ message: String) { sink.write(message) }
    static func success(_ message: String) { sink.write(message) }
}
