import Foundation
import Darwin

final class WorkspaceStore: @unchecked Sendable {
    static let maximumBytes = 4 * 1024 * 1024
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Santty/Workspace", isDirectory: true).appendingPathComponent("workspace.json")
    }
    let url: URL
    let canWrite: Bool
    private let fd: CInt
    private let queue = DispatchQueue(label: "Santty.workspace.persistence")
    private var unreadable = false
    private var lastWritten: Data?
    var backupURL: URL { url.appendingPathExtension("backup") }

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var directory = stat()
        guard lstat(url.deletingLastPathComponent().path, &directory) == 0,
              directory.st_uid == getuid(), directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_mode & 0o077 == 0 else { throw CLIError("Workspace directory must be private to the current user") }
        fd = open(url.appendingPathExtension("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CLIError("Cannot open workspace lock") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd); throw CLIError("Unsafe workspace lock")
        }
        canWrite = flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    deinit { if canWrite { _ = flock(fd, LOCK_UN) }; Darwin.close(fd) }

    struct Loaded: Sendable { let workspace: SavedWorkspace?; let warning: String? }

    private func decode(_ url: URL) throws -> (SavedWorkspace, Data) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= Self.maximumBytes else { throw CLIError("Invalid or oversized workspace file") }
        let data = try Data(contentsOf: url)
        let document = try JSONDecoder().decode(SavedWorkspace.self, from: data)
        try document.validate()
        return (document, data)
    }

    func load() async throws -> Loaded {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    if !exists && !FileManager.default.fileExists(atPath: backupURL.path) {
                        continuation.resume(returning: .init(workspace: nil, warning: canWrite ? nil : "Another Santty instance owns workspace saving; this instance is read-only"))
                        return
                    }
                    do {
                        let (document, data) = try decode(url)
                        lastWritten = data
                        continuation.resume(returning: .init(workspace: document, warning: canWrite ? nil : "Another Santty instance owns workspace saving; this instance restores read-only"))
                    } catch {
                        // A future format is never replaced by an older backup from this app version.
                        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                           attributes[.type] as? FileAttributeType == .typeRegular,
                           ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= Self.maximumBytes,
                           let data = try? Data(contentsOf: url),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let version = json["version"] as? Int, !(1...SavedWorkspace.currentVersion).contains(version) { throw error }
                        let (document, _) = try decode(backupURL)
                        continuation.resume(returning: .init(workspace: document, warning: "Recovered workspace from backup; the primary file is damaged or missing"))
                    }
                } catch {
                    unreadable = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func save(_ document: SavedWorkspace) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard canWrite else { throw CLIError("Another Santty instance owns the workspace file") }
                    guard !unreadable else { throw CLIError("Workspace could not be read safely; original files are preserved") }
                    try document.validate()
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let data = try encoder.encode(document)
                    guard data.count <= Self.maximumBytes else { throw CLIError("Workspace file exceeds the size limit") }
                    if data != lastWritten {
                        if let (_, previous) = try? decode(url) {
                            try previous.write(to: backupURL, options: .atomic)
                            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
                        }
                        try data.write(to: url, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                        lastWritten = data
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
