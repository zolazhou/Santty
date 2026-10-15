import AppKit
import Darwin
import XCTest
@testable import Santty

final class InputSourceTests: XCTestCase {
    @MainActor
    func testSystemCatalogResolvesTheActualSelectedInputSource() throws {
        let current = try XCTUnwrap(SystemInputSources.currentID)
        let source = try XCTUnwrap(SystemInputSources.available.first { $0.id == current })
        XCTAssertFalse(source.name.isEmpty)
    }

    @MainActor
    func testDefaultsAreOptInAndPersistRulesAndPaletteIndependently() throws {
        let suite = "Santty.InputSourceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sources = [
            SystemInputSources.Source(id: "com.apple.keylayout.ABC", name: "ABC", languages: ["en"]),
            SystemInputSources.Source(id: "pinyin::simplified", name: "Pinyin", languages: ["zh-Hans"]),
        ]
        var settings = InputSourceSettings.load(from: defaults, sources: sources)
        XCTAssertFalse(settings.paneRulesEnabled)
        XCTAssertFalse(settings.commandPaletteEnglish)
        XCTAssertEqual(settings.englishInputSourceID, sources[0].id)
        XCTAssertEqual(settings.rules.map(\.program), ["claude", "codex", "nvim"])
        XCTAssertEqual(settings.rules[0].inputSourceID, sources[1].id)
        XCTAssertEqual(settings.sourceID(for: settings.rules[2]), sources[0].id)
        settings.commandPaletteEnglish = true
        settings.rules.append(.init(program: "custom", inputSourceID: "custom-source"))
        InputSourceSettings.save(settings, to: defaults)
        XCTAssertEqual(InputSourceSettings.load(from: defaults, sources: []), settings)
        settings.englishInputSourceID = "another-english"
        XCTAssertEqual(settings.sourceID(for: settings.rules[2]), "another-english")
        XCTAssertEqual(settings.sourceID(for: settings.rules[0]), sources[1].id)
    }

    @MainActor
    func testNoInstalledLanguageIsNotReplacedWithAnUnrelatedInputSource() throws {
        let suite = "Santty.InputSourceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid configuration".utf8), forKey: InputSourceSettings.defaultsKey)
        let settings = InputSourceSettings.load(from: defaults, sources: [
            .init(id: "japanese", name: "Japanese", languages: ["ja"]),
        ])
        XCTAssertEqual(settings.englishInputSourceID, "")
        XCTAssertEqual(settings.rules[0].inputSourceID, "")
    }

    @MainActor
    func testOnlyExecutableAndKnownAgentEntrypointsMatch() {
        let rules = Harness.settings.rules
        func match(_ name: String, _ command: String? = nil) -> String? {
            InputSourceForeground(groupID: 10, processes: [.init(id: 10, name: name, command: command)])
                .match(rules)?.1.program
        }
        XCTAssertEqual(match("/opt/homebrew/bin/nvim"), "nvim")
        XCTAssertEqual(match("CODEX.EXE"), "codex")
        XCTAssertEqual(match("node", "node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"), "claude")
        XCTAssertEqual(match("node", "node /usr/lib/node_modules/@openai/codex/bin/codex.js --version"), "codex")
        XCTAssertNil(match("node", "node /tmp/other.js nvim codex"))
        XCTAssertNil(match("zsh", "zsh -c 'echo nvim claude codex'"))
        XCTAssertNil(match("not-nvim"))
        XCTAssertNil(match("ssh", "ssh host nvim"))
    }

    @MainActor
    func testEditorWinsOverAgentInSameForegroundGroupAndFirstRuleWinsDuplicates() {
        var rules = Harness.settings.rules
        rules.append(.init(program: "nvim", inputSourceID: "other"))
        let foreground = InputSourceForeground(groupID: 10, processes: [
            .init(id: 10, name: "nvim"), .init(id: 20, name: "codex"),
        ])
        XCTAssertEqual(foreground.match(rules)?.0.id, 10)
        XCTAssertEqual(foreground.match(rules)?.1.inputSourceID, InputSourceSettings.english)
    }

    @MainActor
    func testManualSelectionSurvivesPollingUntilProgramOrPaneChanges() async {
        let harness = Harness()
        defer { harness.coordinator.stop() }
        await harness.refresh()
        XCTAssertEqual(harness.selections, ["zh"])
        harness.current = "manual"
        await harness.refresh()
        XCTAssertEqual(harness.current, "manual")
        harness.foreground = .init(groupID: 20, processes: [.init(id: 20, name: "nvim")])
        await harness.refresh()
        XCTAssertEqual(harness.current, "en")
        harness.foreground = .init(groupID: 10, processes: [.init(id: 10, name: "codex")])
        await harness.refresh()
        XCTAssertEqual(harness.current, "zh")
        harness.current = "manual"
        harness.paneID = UUID()
        await harness.refresh()
        XCTAssertEqual(harness.current, "zh")
        harness.foreground = .init(groupID: 30, processes: [.init(id: 30, name: "zsh")])
        harness.current = "manual"
        await harness.refresh()
        XCTAssertEqual(harness.current, "manual")
    }

    @MainActor
    func testPaletteIsIndependentAndRestoresUnknownPane() async {
        let harness = Harness()
        defer { harness.coordinator.stop() }
        harness.configuration.paneRulesEnabled = false
        harness.configuration.commandPaletteEnglish = true
        harness.current = "zh"
        harness.coordinator.paletteWillOpen()
        harness.coordinator.paletteDidFocus(harness.view)
        XCTAssertEqual(harness.current, "en")
        await harness.refresh()
        XCTAssertEqual(harness.queries, 0)
        harness.current = "palette-manual"
        harness.coordinator.paletteDidFocus(harness.view)
        await harness.refresh()
        XCTAssertEqual(harness.current, "palette-manual")
        harness.coordinator.paletteDidClose()
        await harness.refresh()
        XCTAssertEqual(harness.current, "zh")
        XCTAssertEqual(harness.queries, 0)
    }

    @MainActor
    func testPaletteCloseUsesDestinationPaneRuleAndDisabledPalettePreservesManualChoice() async {
        let harness = Harness()
        defer { harness.coordinator.stop() }
        await harness.refresh()
        harness.current = "manual"
        harness.coordinator.paletteWillOpen()
        harness.coordinator.paletteDidFocus(harness.view)
        XCTAssertEqual(harness.current, "manual")
        harness.coordinator.paletteDidClose()
        await harness.refresh()
        XCTAssertEqual(harness.current, "manual")
        harness.configuration.commandPaletteEnglish = true
        harness.coordinator.paletteWillOpen()
        harness.coordinator.paletteDidFocus(harness.view)
        XCTAssertEqual(harness.current, "en")
        harness.foreground = .init(groupID: 20, processes: [.init(id: 20, name: "nvim")])
        harness.coordinator.paletteDidClose()
        await harness.refresh()
        XCTAssertEqual(harness.current, "en")
        harness.coordinator.paletteWillOpen()
        harness.coordinator.paletteDidFocus(harness.view)
        harness.foreground = .init(groupID: 10, processes: [.init(id: 10, name: "codex")])
        harness.coordinator.paletteDidClose()
        await harness.refresh()
        XCTAssertEqual(harness.current, "zh")
    }

    @MainActor
    func testCompositionDefersSwitchAndInactiveOrNonterminalFocusDoesNotQuery() async {
        let harness = Harness()
        defer { harness.coordinator.stop() }
        harness.view.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(harness.view.hasMarkedText())
        await harness.refresh()
        XCTAssertTrue(harness.selections.isEmpty)
        XCTAssertTrue(harness.view.hasMarkedText())
        harness.view.unmarkText()
        await harness.refresh()
        XCTAssertEqual(harness.selections, ["zh"])
        let queries = harness.queries
        harness.active = false
        await harness.refresh()
        XCTAssertEqual(harness.queries, queries)
        harness.active = true
        harness.hasTerminalFocus = false
        await harness.refresh()
        XCTAssertEqual(harness.queries, queries)
        harness.hasTerminalFocus = true
        harness.current = "en"
        await harness.refresh()
        XCTAssertEqual(harness.current, "zh")
    }

    @MainActor
    func testUnavailableSourceDoesNotChangeInputOrRetryEveryPoll() async {
        let harness = Harness()
        defer { harness.coordinator.stop() }
        harness.selectionSucceeds = false
        await harness.refresh()
        XCTAssertEqual(harness.current, "en")
        XCTAssertNotNil(harness.coordinator.lastError)
        await harness.refresh()
        XCTAssertEqual(harness.selections, ["zh"])
    }

    @MainActor
    func testStopCancelsDeferredPaletteRestoration() async {
        let harness = Harness()
        harness.configuration.commandPaletteEnglish = true
        harness.current = "zh"
        harness.coordinator.paletteWillOpen()
        harness.coordinator.paletteDidFocus(harness.view)
        harness.coordinator.paletteDidClose()
        harness.coordinator.stop()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(harness.selections, ["en"])
        XCTAssertEqual(harness.queries, 0)
    }

    @MainActor
    func testPendingPaletteNavigationRestoresPreviousSourceBeforeUnknownDestination() async {
        let harness = Harness()
        defer { harness.coordinator.stop() }
        await harness.refresh()
        harness.configuration.commandPaletteEnglish = true
        harness.current = "manual"
        harness.coordinator.paletteWillOpen()
        harness.coordinator.paletteDidFocus(harness.view)
        harness.hasTerminalFocus = false
        harness.coordinator.paletteDidClose()
        await harness.refresh()
        XCTAssertEqual(harness.current, "manual")
        harness.paneID = UUID()
        harness.foreground = .init(groupID: 30, processes: [.init(id: 30, name: "zsh")])
        harness.hasTerminalFocus = true
        await harness.refresh()
        XCTAssertEqual(harness.current, "manual")
    }

    @MainActor
    func testManualSelectionDuringPendingLookupWins() async throws {
        let harness = Harness()
        defer { harness.coordinator.stop() }
        var continuation: CheckedContinuation<InputSourceForeground, Never>?
        harness.coordinator.targetProvider = {
            .init(paneID: harness.paneID, view: harness.view, foreground: {
                await withCheckedContinuation { continuation = $0 }
            })
        }
        harness.coordinator.refresh()
        for _ in 0..<50 {
            if continuation != nil { break }
            await Task.yield()
        }
        let pending = try XCTUnwrap(continuation)
        harness.current = "manual"
        pending.resume(returning: harness.foreground)
        await harness.coordinator.waitForPendingQuery()
        XCTAssertTrue(harness.selections.isEmpty)
        harness.coordinator.targetProvider = { harness.target }
        await harness.refresh()
        XCTAssertEqual(harness.current, "manual")
    }

    @MainActor
    func testNativePaneQueriesItsForegroundProcessGroup() async throws {
        let group = getpgrp()
        let pane = TerminalPaneController(foregroundProcessIDProvider: { group })
        let foreground = try await pane.inputSourceForeground()
        XCTAssertEqual(foreground.groupID, Int(group))
        XCTAssertTrue(foreground.processes.contains { $0.id == ProcessInfo.processInfo.processIdentifier })
        XCTAssertTrue(foreground.processes.allSatisfy { $0.id > 0 && !$0.name.isEmpty })
    }

    @MainActor
    func testHerdrPaneUsesServerProcessInformation() async throws {
        let service = HerdrWorkspaceTests.Service()
        try await service.start("capabilities")
        defer { service.stop() }
        let runtime = try await HerdrWorkspaceClient(endpoint: service.endpoint).create()
        let pane = TerminalPaneController(herdr: try HerdrPaneBinding(endpoint: service.endpoint, pane: runtime))
        defer { pane.disconnectHerdr() }
        let foreground = try await pane.inputSourceForeground()
        XCTAssertEqual(foreground.groupID, 12345)
        XCTAssertEqual(foreground.processes.map(\.id), pane.herdrProcessInfo?.foreground_processes?.map(\.pid))
        XCTAssertFalse(foreground.processes.isEmpty)
        XCTAssertEqual(foreground.processes.first?.command, pane.herdrProcessInfo?.foreground_processes?.first?.cmdline)
    }

    @MainActor
    func testLateQueryCannotApplyToAnotherPaneAndQueriesDoNotOverlap() async throws {
        let harness = Harness()
        defer { harness.coordinator.stop() }
        var continuation: CheckedContinuation<InputSourceForeground, Never>?
        let oldID = harness.paneID
        harness.coordinator.targetProvider = {
            if harness.paneID == oldID {
                return .init(paneID: oldID, view: harness.view, foreground: {
                    harness.queries += 1
                    return await withCheckedContinuation { continuation = $0 }
                })
            }
            return harness.target
        }
        harness.coordinator.refresh()
        for _ in 0..<50 {
            if continuation != nil { break }
            await Task.yield()
        }
        let pending = try XCTUnwrap(continuation)
        harness.coordinator.refresh()
        XCTAssertEqual(harness.queries, 1)
        harness.paneID = UUID()
        harness.foreground = .init(groupID: 20, processes: [.init(id: 20, name: "nvim")])
        harness.current = "manual"
        await harness.refresh()
        XCTAssertEqual(harness.current, "en")
        pending.resume(returning: .init(groupID: 10, processes: [.init(id: 10, name: "codex")]))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(harness.selections, ["en"])
    }
}

@MainActor
private final class Harness {
    static var settings: InputSourceSettings.Configuration {
        .init(paneRulesEnabled: true, englishInputSourceID: "en", rules: [
            .init(program: "claude", inputSourceID: "zh"),
            .init(program: "codex", inputSourceID: "zh"),
            .init(program: "nvim", inputSourceID: InputSourceSettings.english),
        ])
    }
    var configuration = settings
    var current = "en"
    var selections: [String] = []
    var queries = 0
    var active = true
    var hasTerminalFocus = true
    var selectionSucceeds = true
    var paneID = UUID()
    let view = NSTextView(frame: .zero)
    var foreground = InputSourceForeground(groupID: 10, processes: [.init(id: 10, name: "codex")])
    var target: PaneInputSourceCoordinator.Target? {
        guard hasTerminalFocus else { return nil }
        return .init(paneID: paneID, view: view, foreground: { [unowned self] in
            queries += 1
            return foreground
        })
    }
    lazy var coordinator: PaneInputSourceCoordinator = {
        let coordinator = PaneInputSourceCoordinator(
            configuration: { [unowned self] in configuration },
            currentSource: { [unowned self] in current },
            selectSource: { [unowned self] id, _ in
                selections.append(id)
                if selectionSucceeds { current = id }
                return selectionSucceeds
            },
            isActive: { [unowned self] in active },
            inputView: { [unowned self] in view })
        coordinator.targetProvider = { [unowned self] in target }
        return coordinator
    }()

    func refresh() async {
        coordinator.refresh()
        await coordinator.waitForPendingQuery()
    }
}
