import Foundation

struct HerdrReadResult: Decodable, Sendable {
    let pane_id: String
    let workspace_id: String
    let tab_id: String
    let source: String
    let format: String
    let text: String
    let revision: UInt64
    let truncated: Bool
    var serviceIdentity: HerdrServiceIdentity? = nil
    enum CodingKeys: String, CodingKey { case pane_id, workspace_id, tab_id, source, format, text, revision, truncated }
}

struct HerdrProcessInfo: Decodable, Sendable {
    struct Process: Decodable, Sendable {
        let pid: Int
        let name: String
        var cmdline: String? = nil
        var cwd: String? = nil
    }
    let pane_id: String
    var foreground_process_group_id: Int? = nil
    var foreground_processes: [Process]? = nil
    var serviceIdentity: HerdrServiceIdentity? = nil
    enum CodingKeys: String, CodingKey { case pane_id, foreground_process_group_id, foreground_processes }
}

extension HerdrWorkspaceClient {
    func read(_ binding: HerdrPaneBinding) async throws -> HerdrReadResult {
        guard binding.terminalID != nil else { throw CLIError("Herdr runtime identity is unavailable for history queries") }
        try await verify(binding)
        let result = try await request("pane.read", params: .init(pane_id: binding.paneID, source: "recent", lines: 1000, format: "text", strip_ansi: true))
        guard result.type == "pane_read", let read = result.read,
              read.pane_id == binding.paneID, read.workspace_id == binding.workspaceID, read.tab_id == binding.tabID,
              read.serviceIdentity == binding.serviceIdentity, read.source == "recent", read.format == "text",
              read.text.utf8.count <= HerdrLineDecoder.maximumBytes else { throw CLIError("Invalid or oversized Herdr history snapshot") }
        return read
    }

    func processInfo(_ binding: HerdrPaneBinding) async throws -> HerdrProcessInfo {
        guard binding.terminalID != nil else { throw CLIError("Herdr runtime identity is unavailable for process queries") }
        try await verify(binding)
        let result = try await request("pane.process_info", params: .init(pane_id: binding.paneID))
        guard result.type == "pane_process_info", let info = result.process_info,
              info.pane_id == binding.paneID, info.serviceIdentity == binding.serviceIdentity,
              (info.foreground_processes?.count ?? 0) <= 256,
              info.foreground_process_group_id.map({ $0 > 0 && $0 <= Int(Int32.max) }) != false,
              (info.foreground_processes ?? []).allSatisfy({ $0.pid > 0 && $0.pid <= Int(Int32.max) && $0.name.utf8.count <= 4096
                  && ($0.cmdline?.utf8.count ?? 0) <= 8192 && ($0.cwd?.utf8.count ?? 0) <= 4096 })
        else { throw CLIError("Invalid Herdr process information") }
        return info
    }
}
