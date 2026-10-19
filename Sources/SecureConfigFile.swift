import Foundation
import Darwin

/// Descriptor-based access keeps path aliases and symlink races out of config I/O.
enum SecureConfigFile {
    static let maximumBytes = 1_048_576

    static func canonicalPath(for path: String) throws -> String {
        let parent = try openParent(of: path, create: false)
        defer { close(parent.fd) }
        return parent.canonicalPath
    }

    /// Caller owns the returned descriptor. Also used by the private log sink.
    static func openPrivateDirectory(at path: String, create: Bool) throws -> Int32 {
        try openParent(of: path + "/.directory-check", create: create).fd
    }

    static func read(from path: String) throws -> String {
        let parent = try openParent(of: path, create: false)
        defer { close(parent.fd) }
        let fd = openat(parent.fd, parent.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { throw ConfigError.fileNotFound }
            throw unsafe("Cannot safely open configuration; symbolic links are not accepted")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            throw unsafe("Configuration must be a regular, singly linked file owned by you with owner-only permissions (chmod 600)")
        }
        try PrivateFileAccess.rejectAllowACLs(on: fd)
        guard info.st_size <= off_t(maximumBytes) else { throw unsafe("Configuration exceeds 1 MiB") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else {
            throw unsafe("Configuration must be UTF-8 and at most 1 MiB")
        }
        return text
    }

    static func write(_ text: String, to path: String, replacingExisting: Bool = true) throws {
        let parent = try openParent(of: path, create: true)
        defer { close(parent.fd) }
        var info = stat()
        if fstatat(parent.fd, parent.name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard replacingExisting else { throw unsafe("Configuration already exists") }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(), info.st_nlink == 1 else {
                throw unsafe("Configuration must be a singly linked regular file owned by the current user")
            }
        } else if errno != ENOENT { throw posixError() }

        let data = Data(text.utf8)
        guard data.count <= maximumBytes else { throw unsafe("Configuration exceeds 1 MiB") }
        let temporary = ".ntfy-config-\(UUID().uuidString)"
        let fd = openat(parent.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw posixError() }
        defer { close(fd); unlinkat(parent.fd, temporary, 0) }
        // A mode-0600 file can still inherit an ACL. Strip it before writing secrets.
        try PrivateFileAccess.removeACL(on: fd)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        if replacingExisting {
            guard renameat(parent.fd, temporary, parent.fd, parent.name) == 0 else { throw posixError() }
        } else {
            guard linkat(parent.fd, temporary, parent.fd, parent.name, 0) == 0 else { throw posixError() }
            guard unlinkat(parent.fd, temporary, 0) == 0 else { throw posixError() }
        }
        guard fsync(parent.fd) == 0 else { throw posixError() }
    }

    private struct Parent {
        let fd: Int32
        let name: String
        let canonicalPath: String
    }

    private static func openParent(of path: String, create: Bool) throws -> Parent {
        guard !path.utf8.contains(0) else { throw unsafe("Invalid configuration path") }
        let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        let rawParts = absolute.split(separator: "/").map(String.init)
        guard !rawParts.contains(".."), rawParts.last != "." else {
            throw unsafe("Use a configuration path without '..' components")
        }
        let parts = rawParts.filter { $0 != "." }
        guard let name = parts.last else { throw unsafe("Configuration must name a file") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        do {
            try validateDirectory(fd)
            for (index, component) in parts.dropLast().enumerated() {
                var created = false
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(fd, component, mode_t(0o700)) == 0 else { throw posixError() }
                    created = true
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                // macOS system aliases are root-controlled; all other parent symlinks fail closed.
                if next < 0, index == 0, ["var", "tmp", "etc"].contains(component) {
                    var linkInfo = stat()
                    if fstatat(fd, component, &linkInfo, AT_SYMLINK_NOFOLLOW) == 0,
                       linkInfo.st_uid == 0, linkInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                        next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                    }
                }
                guard next >= 0 else {
                    if errno == ENOENT { throw ConfigError.fileNotFound }
                    throw unsafe("Configuration parents must be regular directories, not user-controlled symlinks")
                }
                close(fd)
                fd = next
                if created { try PrivateFileAccess.removeACL(on: fd) }
                try validateDirectory(fd)
            }
            // POSIX realpath preserves /private; Foundation's normalization does not.
            let parentPath = "/" + parts.dropLast().joined(separator: "/")
            guard let resolved = realpath(parentPath, nil) else { throw posixError() }
            defer { free(resolved) }
            let canonicalParent = String(cString: resolved)
            return Parent(fd: fd, name: name, canonicalPath: (canonicalParent == "/" ? "" : canonicalParent) + "/" + name)
        } catch {
            close(fd)
            throw error
        }
    }

    private static func validateDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        let systemTemp = info.st_uid == 0 && info.st_mode & mode_t(S_ISVTX) != 0
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid() || info.st_uid == 0,
              info.st_mode & 0o022 == 0 || systemTemp else {
            throw unsafe("Configuration directory ancestry must be owned by you or root and not group/world writable")
        }
        try PrivateFileAccess.rejectAllowACLs(on: fd, directory: true)
    }

    private static func unsafe(_ message: String) -> ConfigError { .insecureFilePermissions(message) }
    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

/// POSIX modes alone do not constrain macOS extended ACLs. Deny-only ACLs are safe.
enum PrivateFileAccess {
    static func rejectAllowACLs(on fd: Int32, directory: Bool = false) throws {
        guard let acl = acl_get_fd(fd) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { acl_free(acl) }
        guard acl_valid(acl) == 0 else { throw ConfigError.insecureFilePermissions("Cannot validate file ACL") }
        var entry: acl_entry_t?
        var selector = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(acl, selector, &entry) == 0 {
            selector = Int32(ACL_NEXT_ENTRY.rawValue)
            var tag = ACL_UNDEFINED_TAG
            guard let entry, acl_get_tag_type(entry, &tag) == 0 else {
                throw ConfigError.insecureFilePermissions("Cannot validate file ACL entry")
            }
            if tag == ACL_EXTENDED_DENY { continue }
            if tag == ACL_EXTENDED_ALLOW, directory {
                var mask: acl_permset_mask_t = 0
                guard acl_get_permset_mask_np(entry, &mask) == 0 else {
                    throw ConfigError.insecureFilePermissions("Cannot validate directory ACL permissions")
                }
                let writePermissions = [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE_CHILD, ACL_DELETE,
                                        ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER]
                    .reduce(acl_permset_mask_t(0)) { $0 | acl_permset_mask_t($1.rawValue) }
                if mask & writePermissions == 0 { continue }
            }
            throw ConfigError.insecureFilePermissions("Private storage has an extended ACL granting unsafe access")
        }
        // Darwin reports EINVAL when its valid ACL iterator reaches the end.
        guard errno == EINVAL else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    static func removeACL(on fd: Int32) throws {
        guard let acl = acl_init(0) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { acl_free(acl) }
        guard acl_set_fd(fd, acl) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
