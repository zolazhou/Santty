import Foundation

struct TerminalProcessInspector {
    struct ProcessRecord: Equatable, Sendable {
        let processID: Int
        let parentProcessID: Int
        let processGroupID: Int
        let command: String

        var executableName: String? {
            guard let executable = command.split(separator: " ", maxSplits: 1).first else {
                return nil
            }

            let path = String(executable)
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? path : name
        }
    }

    static func currentProcessTable() -> [ProcessRecord] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ewwaxo", "pid=,ppid=,pgid=,command="]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return []
        }

        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output.split(separator: "\n").compactMap(parseProcessRecord)
    }

    private static func parseProcessRecord(_ line: Substring) -> ProcessRecord? {
        let fields = line.split(
            separator: " ",
            maxSplits: 3,
            omittingEmptySubsequences: true
        )
        guard fields.count == 4,
            let processID = Int(fields[0]),
            let parentProcessID = Int(fields[1]),
            let processGroupID = Int(fields[2])
        else {
            return nil
        }

        return ProcessRecord(
            processID: processID,
            parentProcessID: parentProcessID,
            processGroupID: processGroupID,
            command: String(fields[3])
        )
    }

}
