import Darwin
import Foundation

// Only --version is run; the caller's serial worker keeps this off the main thread.
enum HerdrExecutable {
    static func suggestedPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let paths = [home.appendingPathComponent(".local/bin/herdr").path, "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
        return paths.first {
            FileManager.default.isExecutableFile(atPath: $0)
                && (try? URL(fileURLWithPath: $0).resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        } ?? paths[0]
    }

    static func version(at binary: URL) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = binary
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        defer {
            // A second wait after normal exit adds a Foundation run-loop delay.
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            try? pipe.fileHandleForReading.close()
        }
        try pipe.fileHandleForWriting.close()
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var output = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                output.append(contentsOf: bytes.prefix(count))
                guard output.count <= 4096 else { throw CLIError("Herdr version output exceeded its limit") }
            } else if count == 0 { break }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw CLIError("Cannot read Herdr client version") }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CLIError("Herdr client version check timed out") }
            if count <= 0 { usleep(5000) }
        }
        // EOF alone is insufficient if the executable closes output then hangs.
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { usleep(5000) }
        guard !process.isRunning else { throw CLIError("Herdr client version check timed out") }
        guard process.terminationStatus == 0,
              String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "herdr 0.9.3"
        else { throw CLIError("Unsupported Herdr client. Choose Herdr 0.9.3; Santty will not install or upgrade it.") }
        return "0.9.3"
    }
}
