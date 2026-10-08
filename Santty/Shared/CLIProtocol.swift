import Darwin
import Foundation

struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct CLIRequest: Codable, Sendable {
    var command: String
    var paneID: UUID?
    var tail: Int?
    var startLine: Int?
    var endLine: Int?
    var query: String?
    var ignoreCase: Bool?
    var limit: Int?

    func validate() throws {
        guard ["list", "read", "search"].contains(command) else {
            throw CLIError("Unknown command: \(command)")
        }
        if command != "list" {
            guard paneID != nil else { throw CLIError("\(command) requires a pane UUID.") }
        }
        if command == "read" {
            guard (1...10_000).contains(tail ?? 200) else {
                throw CLIError("--tail must be between 1 and 10000.")
            }
            if startLine != nil || endLine != nil {
                guard tail == nil else {
                    throw CLIError("--tail cannot be combined with a line range.")
                }
                guard let startLine, let endLine, startLine > 0, endLine >= startLine,
                    endLine - startLine < 10_000
                else {
                    throw CLIError(
                        "Supply --start-line and --end-line: 1-based, inclusive, at most 10000 lines."
                    )
                }
            }
        } else if tail != nil || startLine != nil || endLine != nil {
            throw CLIError("Line ranges and --tail are only supported by read.")
        }
        if command == "search" {
            guard let query, !query.isEmpty, query.utf8.count <= 1024,
                !query.contains(where: { $0.isNewline })
            else {
                throw CLIError(
                    "Search text must be nonempty, single-line, and at most 1024 UTF-8 bytes.")
            }
            guard (1...1000).contains(limit ?? 100) else {
                throw CLIError("--limit must be between 1 and 1000.")
            }
        } else if query != nil || ignoreCase != nil || limit != nil {
            throw CLIError("Search text, --ignore-case and --limit are only supported by search.")
        }
    }
}

struct CLIPane: Codable, Sendable {
    let id: UUID
    let title: String
    var name: String? = nil
    let kind: String
    let cwd: String?
    let foregroundProcessGroupID: Int?
    var processes: [CLIProcess] = []
    let isFocused: Bool
    let isLive: Bool
    let isDetached: Bool

    private enum CodingKeys: String, CodingKey {
        case id, title, name, kind, cwd, foregroundProcessGroupID, processes
        case isFocused, isLive, isDetached
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        // Keep the name key present even for unnamed panes.
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(foregroundProcessGroupID, forKey: .foregroundProcessGroupID)
        try container.encode(processes, forKey: .processes)
        try container.encode(isFocused, forKey: .isFocused)
        try container.encode(isLive, forKey: .isLive)
        try container.encode(isDetached, forKey: .isDetached)
    }
}

struct CLIProcess: Codable, Sendable {
    let pid: Int
    let command: String
}

struct CLITab: Codable, Sendable {
    let id: UUID
    let title: String
    let isSelected: Bool
    var panes: [CLIPane]
}

struct CLIResponse: Codable, Sendable {
    var version = 2
    var tabs: [CLITab]?
    var text: String?
    var truncated: Bool?
    var error: String?
    var startLine: Int?
    var endLine: Int?
    var totalLines: Int?
    var matches: [CLIMatch]?
    var totalMatches: Int?
}

struct CLIMatch: Codable, Sendable {
    let line: Int
    let text: String
    let truncated: Bool
}

enum CLITransport {
    static let maximumResponseBytes = 2 * 1024 * 1024
    static var directory: URL {
        URL(fileURLWithPath: "/tmp/santty-\(getuid())", isDirectory: true)
    }
    static var socketPath: String {
        directory.appendingPathComponent("\(getpid()).sock").path
    }

    static func prepareDirectory() throws {
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            throw systemError("Create socket directory")
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
            info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
            info.st_mode & 0o777 == 0o700
        else { throw CLIError("Unsafe socket directory: \(directory.path)") }
    }

    static func withAddress<T>(
        _ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        var address = sockaddr_un()
        guard !path.utf8.contains(0), path.utf8.count < MemoryLayout.size(ofValue: address.sun_path)
        else {
            throw CLIError("Invalid socket path.")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                    _ = strcpy(destination, source)
                }
            }
        }
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func configure(_ fd: CInt) {
        // BSD accept() inherits O_NONBLOCK from the listener. Client I/O uses
        // bounded blocking reads, so clear it before applying the timeouts.
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(
            fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var enabled: CInt = 1
        setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func verifyPeer(_ fd: CInt) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            throw CLIError("Socket peer must belong to the current user.")
        }
    }

    static func connect(to path: String) throws -> CInt {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw systemError("Create socket") }
        configure(fd)
        do {
            try withAddress(path) { address, length in
                guard Darwin.connect(fd, address, length) == 0 else {
                    throw CLIError(
                        "Cannot connect to Santty at \(path). Start Santty and enable CLI access in General settings."
                    )
                }
            }
            try verifyPeer(fd)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    static func readLine(_ fd: CInt, limit: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw CLIError("Connection closed or timed out before a complete response.")
            }
            let chunk = buffer.prefix(count)
            if let newline = chunk.firstIndex(of: 10) {
                data.append(contentsOf: chunk[..<newline])
                guard data.count <= limit else { throw CLIError("Message exceeds size limit.") }
                return data
            }
            data.append(contentsOf: chunk)
            guard data.count <= limit else { throw CLIError("Message exceeds size limit.") }
        }
    }

    static func write<T: Encodable>(_ value: T, to fd: CInt) throws {
        var data = try JSONEncoder().encode(value)
        data.append(10)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw systemError("Write socket") }
                offset += count
            }
        }
    }

    static func systemError(_ operation: String) -> CLIError {
        CLIError("\(operation): \(String(cString: strerror(errno)))")
    }
}
