import Foundation
import Darwin

enum HerdrProcess {
    struct Output: Sendable { let status: Int32; let stdout: Data; let stderr: Data }

    // Call only on a worker: both pipes are drained so stderr cannot block stdout.
    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 20,
                    limit: Int = 1024 * 1024) throws -> Output {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = errors
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        }
        try output.fileHandleForWriting.close(); try errors.fileHandleForWriting.close()
        let descriptors = [output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor]
        for fd in descriptors { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = [Data(), Data()], ended = [false, false], bytes = [UInt8](repeating: 0, count: 16384)
        while !ended.allSatisfy({ $0 }) || process.isRunning {
            for index in descriptors.indices where !ended[index] {
                let count = Darwin.read(descriptors[index], &bytes, bytes.count)
                if count > 0 {
                    data[index].append(contentsOf: bytes.prefix(count))
                    guard data[index].count <= limit else { throw CLIError("Herdr command output exceeded its limit") }
                } else if count == 0 { ended[index] = true }
                else if ![EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { throw CLIError("Cannot read Herdr command output") }
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CLIError("Herdr command timed out") }
            usleep(5000)
        }
        return .init(status: process.terminationStatus, stdout: data[0], stderr: data[1])
    }
}
