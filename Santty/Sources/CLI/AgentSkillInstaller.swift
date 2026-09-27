import Darwin
import Foundation

struct AgentSkillInstaller {
    enum Status: Equatable {
        case missing
        case installed
        case otherApp(path: String, broken: Bool)
        case conflict
    }

    let appURL: URL

    init(appURL: URL = Bundle.main.bundleURL) { self.appURL = appURL }

    var source: URL {
        appURL.appendingPathComponent("Contents/Resources/Skills/santty")
    }

    func status(in directory: URL) -> Status {
        let link = directory.appendingPathComponent("santty")
        var info = stat()
        guard lstat(link.path, &info) == 0 else {
            return errno == ENOENT ? .missing : .conflict
        }
        guard
            let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        else {
            return .conflict
        }
        let base = URL(fileURLWithPath: directory.path, isDirectory: true)
        let target = URL(fileURLWithPath: destination, relativeTo: base).standardizedFileURL
        if target == source.standardizedFileURL { return .installed }
        // Only links to Santty's specific bundled skill location are managed.
        guard target.path.hasSuffix("/Santty.app/Contents/Resources/Skills/santty") else {
            return .conflict
        }
        return .otherApp(
            path: target.path,
            broken: !FileManager.default.fileExists(
                atPath: target.appendingPathComponent("SKILL.md").path))
    }

    func install(in directory: URL, replacingOtherApp: Bool = false) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else {
            throw CLIError("The bundled Santty skill is missing. Reinstall Santty.")
        }
        let status = status(in: directory)
        switch status {
        case .installed: return
        case .conflict:
            throw CLIError(
                "This location contains an unrelated file, directory or link. Move it before installing."
            )
        case .otherApp where !replacingOtherApp:
            throw CLIError(
                "The skill points to another Santty app. Choose Use This Version to replace its link."
            )
        default: break
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("santty")
        if status == .missing {
            try manager.createSymbolicLink(at: link, withDestinationURL: source)
        } else {
            let temporary = directory.appendingPathComponent(".santty-\(UUID().uuidString)")
            try manager.createSymbolicLink(at: temporary, withDestinationURL: source)
            defer { try? manager.removeItem(at: temporary) }
            // Recheck immediately before replacing, protecting changes since the UI read.
            guard self.status(in: directory) == status else {
                throw CLIError("The link changed. Refresh and try again.")
            }
            guard rename(temporary.path, link.path) == 0 else {
                throw CLITransport.systemError("Update skill link")
            }
        }
    }

    func remove(from directory: URL) throws {
        switch status(in: directory) {
        case .installed, .otherApp:
            // unlink removes the link itself, never its target directory.
            guard unlink(directory.appendingPathComponent("santty").path) == 0 else {
                throw CLITransport.systemError("Remove skill link")
            }
        case .missing: return
        case .conflict: throw CLIError("Only links to Santty's bundled skill can be removed here.")
        }
    }
}
