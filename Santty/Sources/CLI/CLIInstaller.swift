import Foundation

enum CLIInstaller {
    static func install(
        appURL: URL = Bundle.main.bundleURL,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        let manager = FileManager.default
        let executable = appURL.appendingPathComponent("Contents/Helpers/santty")
        guard manager.isExecutableFile(atPath: executable.path) else {
            throw CLIError("The bundled CLI is missing. Reinstall Santty.")
        }
        let directory = homeURL.appendingPathComponent(".local/bin", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("santty")
        if let destination = try? manager.destinationOfSymbolicLink(atPath: link.path) {
            if destination == executable.path { return }
            guard destination.hasSuffix(".app/Contents/Helpers/santty") else {
                throw CLIError(
                    "\(link.path) already points to another tool. Move it before installing.")
            }
            // Prepare the replacement first, then atomically replace our old symlink.
            let temporary = directory.appendingPathComponent(".santty-\(UUID().uuidString)")
            try manager.createSymbolicLink(at: temporary, withDestinationURL: executable)
            defer { try? manager.removeItem(at: temporary) }
            guard rename(temporary.path, link.path) == 0 else {
                throw CLITransport.systemError("Update CLI link")
            }
        } else {
            // createSymbolicLink fails if any existing file occupies this path.
            try manager.createSymbolicLink(at: link, withDestinationURL: executable)
        }
    }
}
