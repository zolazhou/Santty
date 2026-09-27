import Darwin
import Foundation

@MainActor
final class AgentForegroundProcessRegistry {
    static let shared = AgentForegroundProcessRegistry()

    private var providers: [PaneID: @MainActor () -> Int?] = [:]

    private init() {}

    func register(paneID: PaneID, foregroundProcessID: @escaping @MainActor () -> Int?) {
        providers[paneID] = foregroundProcessID
    }

    func unregister(paneID: PaneID) {
        providers.removeValue(forKey: paneID)
    }

    func snapshot() -> [PaneID: Int] {
        providers.compactMapValues { foregroundProcessID in
            foregroundProcessID()
        }
    }
}

struct AgentForegroundProcessObservation: Equatable {
    let paneID: PaneID
    let processID: Int
    let agent: AgentKind?
}

struct AgentForegroundProcessInspector {
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

    private let processTableProvider: () -> [ProcessRecord]

    init(processTableProvider: @escaping () -> [ProcessRecord] = Self.currentProcessTable) {
        self.processTableProvider = processTableProvider
    }

    func observe(paneForegroundProcessIDs: [PaneID: Int]) -> [AgentForegroundProcessObservation] {
        let processTable = processTableProvider()
        return paneForegroundProcessIDs.compactMap { paneID, processID in
            Self.observe(
                paneID: paneID,
                foregroundProcessGroupID: processID,
                processTable: processTable
            )
        }
    }

    static func observe(
        paneID: PaneID,
        foregroundProcessGroupID: Int,
        processTable: [ProcessRecord]
    ) -> AgentForegroundProcessObservation? {
        guard foregroundProcessGroupID > 0 else {
            return nil
        }

        if let agentProcess = agentProcess(
            inForegroundProcessGroupID: foregroundProcessGroupID,
            processTable: processTable
        ) {
            return AgentForegroundProcessObservation(
                paneID: paneID,
                processID: agentProcess.processID,
                agent: agentKind(forProcessRecord: agentProcess)
            )
        }

        return AgentForegroundProcessObservation(
            paneID: paneID,
            processID: foregroundProcessGroupID,
            agent: agentKind(forProcessID: foregroundProcessGroupID)
        )
    }

    static func agentKind(forProcessID processID: Int) -> AgentKind? {
        guard let executableName = executableName(forProcessID: processID) else {
            return nil
        }

        return agentKind(forExecutableName: executableName)
    }

    static func agentKind(forExecutableName executableName: String) -> AgentKind? {
        switch executableName {
        case "codex":
            return .codex
        case "claude", "claude-code":
            return .claude
        default:
            return nil
        }
    }

    private static func agentProcess(
        inForegroundProcessGroupID processGroupID: Int,
        processTable: [ProcessRecord]
    ) -> ProcessRecord? {
        processTable
            .filter { $0.processGroupID == processGroupID && agentKind(forProcessRecord: $0) != nil }
            .sorted { lhs, rhs in
                if lhs.processID == processGroupID {
                    return true
                }
                if rhs.processID == processGroupID {
                    return false
                }
                return lhs.processID < rhs.processID
            }
            .first
    }

    private static func agentKind(forProcessRecord process: ProcessRecord) -> AgentKind? {
        guard let executableName = process.executableName else {
            return nil
        }

        return agentKind(forExecutableName: executableName)
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

    private static func executableName(forProcessID processID: Int) -> String? {
        let bufferCount = Int(MAXCOMLEN) + 1
        var buffer = [CChar](repeating: 0, count: bufferCount)
        let byteCount = buffer.withUnsafeMutableBufferPointer { bufferPointer in
            proc_name(pid_t(processID), bufferPointer.baseAddress, UInt32(bufferCount))
        }
        guard byteCount > 0 else {
            return nil
        }

        return buffer.withUnsafeBufferPointer { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else {
                return nil
            }

            let bytes = UnsafeRawBufferPointer(
                start: baseAddress,
                count: Int(byteCount)
            )
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
