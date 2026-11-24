import AppKit
import GhosttyVt
import XCTest
@testable import Santty

/// Test conveniences over the real VT API, not a legacy emulator or transport.
@MainActor
extension NativeTerminalScrollView {
    func fitToSize() { XCTAssertNoThrow(try synchronizeViewport()) }
    func readScreenText() -> String? { try? driver.readScreenText() }
    func paste(text: String) -> Bool { (try? renderer.output?.paste(text)) == true }
    func sendKey(_ key: GhosttyKey) -> Bool { (try? renderer.output?.sendKey(key)) == true }
    var owningPaneController: TerminalPaneController? {
        var ancestor = superview
        while let current = ancestor { if let host = current as? TerminalPaneHostView { return host.paneController }; ancestor = current.superview }
        return nil
    }
}
extension GhosttyKey { static var enter: Self { GHOSTTY_KEY_ENTER } }

@MainActor
func makeUnstartedHerdrOwner(remote: HerdrRemote? = nil) throws -> NativeTerminalPaneSession {
    try .herdr(paneID:UUID(),driver:GhosttyVTDriver(),client:.shared,workingDirectory:nil,binding:nil,remote:remote,beforeRun:{})
}

/// All executable/profile/filesystem effects are confined to this owned root.
@MainActor
final class PrivatePaneFixture {
    let root: URL
    let owner: NativeTerminalPaneSession
    let pane: TerminalPaneController
    private var stopped = false
    init(id: PaneID = UUID(), arguments: [String] = ["-i"]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("santty-pane-cutover-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let driver = try GhosttyVTDriver()
        let launch = try NativeLocalPTYLaunch(paneID:id,executable:"/bin/sh",arguments:arguments,
            environment:["HOME":root.path,"XDG_CONFIG_HOME":root.path,"XDG_STATE_HOME":root.path,
                "XDG_CACHE_HOME":root.path,"XDG_DATA_HOME":root.path,"PATH":"/usr/bin:/bin","TERM":"xterm-256color","LANG":"en_US.UTF-8"],
            workingDirectory:root.path)
        owner = .local(launch:launch,driver:driver)
        pane = TerminalPaneController(id:id,workingDirectory:root.path,session:owner)
    }
    func stop() async throws {
        guard !stopped else { return }
        try await owner.close(.terminate); try FileManager.default.removeItem(at:root); stopped = true
    }
    isolated deinit {
        guard !stopped else { return }
        let owner = owner, root = root
        Task { @MainActor in
            do { try await owner.close(.terminate); try FileManager.default.removeItem(at:root) } catch { /* retain failed cleanup root */ }
        }
    }
}
