import Foundation

@MainActor
final class HerdrClientShellSession {
    private struct Request<Params: Encodable>: Encodable {
        let id: String; let method: String; let params: Params
    }
    private struct SurfaceInterest: Encodable { let active: Bool }
    private struct Response: Decodable {
        struct Result: Decodable { let type: String; let active: Bool?; let projection_revision: UInt64? }
        struct Failure: Decodable { let code: String; let message: String }
        let id: String
        let result: Result?
        let error: Failure?
    }
    private struct Pending {
        let id: String
        let boot: String
        let message: HerdrShellClientMessage
        let completion: CheckedContinuation<Data, Error>?
        let activation: Bool
        var deactivation = false
        var navigation: (method: String, target: String)? = nil
        var response = Data()
        var sentAt: TimeInterval? = nil
    }
    private struct NavigationTiming {
        let requestID: String
        let boot: String
        let method: String
        let target: String
        let issuedAt: TimeInterval
        var responseAt: TimeInterval?
        var matchedAt: TimeInterval?
    }
    private struct HeldInput: Hashable {
        let target: String
        let popup: Bool
        let mouse: Bool
        let physical: UInt32?
        let code: UInt32
        let character: UInt32?
    }
    private struct Presentation: Equatable {
        let boot: String
        let projection: UInt64
        let surface: UInt64
        init(_ frame: HerdrShellSurface) {
            boot = frame.boot_id; projection = frame.projection_revision; surface = frame.surface_revision
        }
    }
    private struct Geometry: Equatable {
        let focusedPane: String?
        let panes: [String]
        let rectangles: [HerdrShellRect]
        let popup: String?
        let popupSize: HerdrShellSize?
        let mouseModes: [Bool]
        let pixelSizes: [UInt32]
        func hasSameViewport(as other: Self) -> Bool {
            panes == other.panes && rectangles == other.rectangles && popup == other.popup
                && popupSize == other.popupSize && mouseModes == other.mouseModes && pixelSizes == other.pixelSizes
        }
        init(_ snapshot: HerdrShellSnapshot, _ frame: HerdrShellSurface) {
            focusedPane = snapshot.focused_pane_id; panes = frame.panes.map(\.pane_id)
            rectangles = frame.panes.map(\.inner_rect); popup = frame.popup?.terminal_id
            popupSize = frame.popup.map { .init(cols: $0.frame.width, rows: $0.frame.height) }
            mouseModes = frame.panes.flatMap { [$0.mouse_reporting, $0.sgr_pixel_mouse] }
                + (frame.popup.map { [$0.mouse_reporting, $0.sgr_pixel_mouse] } ?? [])
            pixelSizes = frame.panes.flatMap { [$0.pixel_width, $0.pixel_height] }
                + (frame.popup.map { [$0.pixel_width, $0.pixel_height] } ?? [])
        }
    }

    let endpoint: HerdrEndpoint
    private let makeTransport: @Sendable (HerdrEndpoint) throws -> HerdrClientShellTransport
    private var offeredPresentation: Presentation?
    private var presented: Presentation?
    private var presentedGeometry: Geometry?
    private var pinnedPresentation: (stamp: Presentation, geometry: Geometry)?
    private var presentedFromPinnedFrame = false
    private(set) var state: HerdrConnectionState = .disconnected
    private(set) var projection = HerdrShellProjection()
    private(set) var welcome: HerdrShellWelcome?
    private(set) var serviceIdentity: HerdrServiceIdentity?
    var onState: ((HerdrConnectionState) -> Void)?
    var onMetadata: ((HerdrShellSnapshot) -> Void)?
    var onNotification: ((HerdrShellNotification) -> Void)?
    private(set) var agentCompletions: HerdrShellAgentCompletions?
    var onProjection: ((HerdrShellSnapshot, HerdrShellSurface, [HerdrShellAssetKey: Data]) -> Void)?
    var onEffect: ((HerdrShellServerMessage) -> Void)?
    var onFailure: ((any Error, Bool) -> Void)?
    private(set) var failure: (any Error)?
    private var hasPresentedSurface = false
    private var requestLatencies = HerdrShellLatencySamples()
    private var hostCommitLatencies = HerdrShellLatencySamples()
    private var stageLatencies: [String: HerdrShellLatencySamples] = [:]
    private var surfaceTraffic: [String: HerdrDiagnostics.SurfaceTraffic] = [:]
    private var offeredAt: TimeInterval?
    private var navigationTiming: NavigationTiming?
    private var navigationResponseLatencies = HerdrShellLatencySamples()
    private var navigationSceneLatencies = HerdrShellLatencySamples()
    private var navigationCommitLatencies = HerdrShellLatencySamples()
    private var navigationTotalLatencies = HerdrShellLatencySamples()
    private var supersededNavigations = 0
    private var failureDiagnostics: HerdrDiagnostics.ClientShell?
    private var deferredEffects: [(HerdrShellServerMessage, Presentation)] = []
    private var deferredEffectBytes = 0
    private var transport: HerdrClientShellTransport?
    private var readerTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var generation = 0
    private var pending: [Pending] = []
    private var heldReleases: [HeldInput: HerdrShellInput] = [:]
    private var focusMouseTarget: String?
    private var size = HerdrShellSize(cols: 80, rows: 24)
    private var cellWidth: UInt32 = 0
    private var cellHeight: UInt32 = 0
    private var hostFocused = false
    private var hostDark: Bool?
    private var sentHostDark: Bool?
    private var hostColors: HerdrShellHostColors?
    private var sentHostColors: HerdrShellHostColors?
    private var activationRevision: UInt64?
    private var activationQueued = false
    private var activatesWhenMetadataReady = true
    private var fenceToken: String?
    private var lastReceived: TimeInterval = 0
    private var startedAt: TimeInterval = 0
    private var pingSentAt: TimeInterval?
    private var pairMissingSince: TimeInterval?
    private var navigation: (requestID: String, method: String, target: String, minimumRevision: UInt64, acknowledged: Bool)?

    init(endpoint: HerdrEndpoint, makeTransport: @escaping @Sendable (HerdrEndpoint) throws -> HerdrClientShellTransport = {
        try HerdrClientShellTransport(socketPath: $0.clientSocketPath, endpoint: $0)
    }) { self.endpoint = endpoint; self.makeTransport = makeTransport }

    deinit {
        readerTask?.cancel(); timerTask?.cancel()
        transport?.stop()
    }

    func start(size: HerdrShellSize, cellWidth: UInt32, cellHeight: UInt32, focused: Bool,
               activateWhenMetadataReady: Bool = true) async throws {
        disconnect()
        guard size.cols > 0, size.rows > 0,
              !activateWhenMetadataReady || (cellWidth > 0 && cellHeight > 0) else { throw CLIError("Herdr shell viewport is not ready") }
        self.size = size; self.cellWidth = cellWidth; self.cellHeight = cellHeight; hostFocused = focused
        activatesWhenMetadataReady = activateWhenMetadataReady
        generation += 1
        let epoch = generation
        updateState(.connecting)
        do {
            let endpoint = self.endpoint
            let makeTransport = self.makeTransport
            let connection = try await Task.detached { try makeTransport(endpoint) }.value
            guard generation == epoch else { connection.stop(); throw CancellationError() }
            transport = connection
            serviceIdentity = connection.serviceIdentity
            let hello = HerdrShellHello(cell_width_px: cellWidth, cell_height_px: cellHeight, surface_size: size, pixel_mouse: cellWidth > 0 && cellHeight > 0)
            let json = String(decoding: try JSONEncoder().encode(hello), as: UTF8.self)
            try connection.send(.control("endpoint.hello.v1", json))
            startedAt = now; lastReceived = now
            readerTask = Task { [weak self] in
                do {
                    for try await packet in connection.messages {
                        connection.consume(packet)
                        guard let self, self.generation == epoch else { break }
                        self.recordStage("payloadRead", seconds: packet.payloadReadSeconds)
                        self.recordStage("wireDecode", seconds: packet.decodeSeconds)
                        if let codec = packet.surfaceCodec {
                            self.recordStage("wireDecode.\(codec)", seconds: packet.decodeSeconds)
                            self.surfaceTraffic[codec, default: .init()].packets += 1
                            self.surfaceTraffic[codec, default: .init()].payloadBytes += packet.byteCount
                            self.surfaceTraffic[codec, default: .init()].decodedBytes += packet.decodedByteCount
                        }
                        self.recordStage("mainActorQueue", seconds: self.now - packet.enqueuedAt)
                        try self.receive(packet.message)
                    }
                    if let self, self.generation == epoch { self.fail(HerdrShellConnectionLost(message: "Herdr shell disconnected")) }
                } catch {
                    if let self, self.generation == epoch { self.fail(error) }
                }
            }
            timerTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                    guard let self, self.generation == epoch else { break }
                    do { try self.tick() } catch { self.fail(error); break }
                }
            }
        } catch {
            if generation == epoch { fail(error) }
            throw error
        }
    }

    func disconnect() {
        hasPresentedSurface = false
        failure = nil
        failureDiagnostics = nil
        deferredEffects.removeAll(); deferredEffectBytes = 0
        sentHostDark = nil; sentHostColors = nil
        requestLatencies = .init(); hostCommitLatencies = .init(); offeredAt = nil
        stageLatencies.removeAll(); surfaceTraffic.removeAll()
        navigationTiming = nil; navigationResponseLatencies = .init(); navigationSceneLatencies = .init()
        navigationCommitLatencies = .init(); navigationTotalLatencies = .init(); supersededNavigations = 0
        generation += 1
        readerTask?.cancel(); readerTask = nil; timerTask?.cancel(); timerTask = nil
        for request in pending { request.completion?.resume(throwing: CLIError("Herdr request result is unknown; it was not replayed")) }
        pending.removeAll()
        heldReleases.removeAll(); focusMouseTarget = nil
        transport?.detach(); transport = nil
        projection = .init(); agentCompletions = nil; welcome = nil; serviceIdentity = nil; activationRevision = nil; activationQueued = false
        fenceToken = nil; pingSentAt = nil; pairMissingSince = nil; navigation = nil
        offeredPresentation = nil; presented = nil; presentedGeometry = nil
        pinnedPresentation = nil; presentedFromPinnedFrame = false
        updateState(.disconnected)
    }

    func resize(_ size: HerdrShellSize, cellWidth: UInt32, cellHeight: UInt32) throws {
        guard size.cols > 0, size.rows > 0, cellWidth > 0, cellHeight > 0 else { return }
        guard self.size != size || self.cellWidth != cellWidth || self.cellHeight != cellHeight else { return }
        self.size = size; self.cellWidth = cellWidth; self.cellHeight = cellHeight
        if activationQueued { try releaseHeldInput(); try transport?.send(.resize(size, cellWidth, cellHeight, true)) }
        publish()
    }

    func setFocused(_ focused: Bool) throws {
        if !focused { try releaseHeldInput() }
        hostFocused = focused
        if activationQueued { try transport?.send(.focus(focused)) }
    }

    func setAppearance(dark: Bool) throws {
        hostDark = dark
        guard activationQueued, sentHostDark != dark else { return }
        try transport?.send(.appearance(dark: dark))
        sentHostDark = dark
    }

    func setHostColors(_ colors: HerdrShellHostColors) throws {
        hostColors = colors
        guard activationQueued else { return }
        if sentHostColors?.foreground != colors.foreground {
            try transport?.send(.defaultColor(background: false, color: colors.foreground))
        }
        if sentHostColors?.background != colors.background {
            try transport?.send(.defaultColor(background: true, color: colors.background))
        }
        if !colors.palette.isEmpty, sentHostColors?.palette != colors.palette {
            try transport?.send(.paletteColors(colors.palette))
        }
        sentHostColors = colors
    }

    @discardableResult
    func input(target: String, popup: Bool = false, events: [HerdrShellInput]) -> Bool {
        guard transport != nil else { return false }
        let releaseOnly = !events.isEmpty && events.allSatisfy { event in
            switch event {
            case .key(let key):
                return key.kind == 2 && heldReleases[.init(target: target, popup: popup, mouse: false,
                    physical: key.physicalKeyID, code: key.code, character: key.character?.value)] != nil
            case .mouse(let mouse):
                guard let button = mouse.button else { return false }
                return mouse.kind == 1 && heldReleases[.init(target: target, popup: popup, mouse: true,
                    physical: nil, code: button, character: nil)] != nil
            default: return false
            }
        }
        guard releaseOnly || (state == .interactive && pending.isEmpty && navigation == nil
            && isInputReady && projection.coherentSurface?.containsInputTarget(target, popup: popup) == true) else { return false }
        do {
            var held = heldReleases
            for event in events {
                switch event {
                case .key(var key):
                    let id = HeldInput(target: target, popup: popup, mouse: false, physical: key.physicalKeyID,
                                       code: key.code, character: key.character?.value)
                    if key.kind == 1 && key.tracksRelease && held[id] == nil { return false }
                    if key.kind == 2 && key.tracksRelease && held[id] == nil { return false }
                    if key.kind == 2 { held.removeValue(forKey: id) }
                    else if key.tracksRelease { key.kind = 2; key.text = nil; key.repeatCount = 1; held[id] = .key(key) }
                case .mouse(let mouse):
                    if let button = mouse.button {
                        let id = HeldInput(target: target, popup: popup, mouse: true, physical: nil, code: button, character: nil)
                        if (mouse.kind == 1 || mouse.kind == 2) && held[id] == nil { return false }
                        if mouse.kind == 1 { held.removeValue(forKey: id) }
                        else {
                            held[id] = .mouse(.init(kind: 1, button: button, column: mouse.column, row: mouse.row,
                                pixels: mouse.pixels, geometry: mouse.geometry, modifiers: mouse.modifiers, lines: 1))
                        }
                    }
                default: break
                }
                guard held.count <= 512 else { throw CLIError("Herdr held input exceeds budget") }
            }
            try transport?.send(.input(target: target, popup: popup, events: events))
            heldReleases = held
            if let target = focusMouseTarget, !hasHeldMouse(target: target) { focusMouseTarget = nil }
            return transport != nil
        }
        catch { fail(error); return false }
    }

    func request(_ method: String, params: HerdrConnection.Request.Params = .init()) async throws -> Data {
        guard welcome?.methods?.contains(method) == true, state == .interactive, pending.count < 64,
              let snapshot = projection.snapshot else { throw CLIError("Herdr endpoint operation is unavailable: \(method)") }
        let id = UUID().uuidString
        let json = String(decoding: try JSONEncoder().encode(Request(id: id, method: method, params: params)), as: UTF8.self)
        let target: String?
        switch method { case "pane.focus": target = params.pane_id; case "tab.focus": target = params.tab_id
        case "workspace.focus": target = params.workspace_id; default: target = nil }
        return try await withCheckedThrowingContinuation { completion in
            pending.append(.init(id: id, boot: snapshot.boot_id, message: .request(boot: snapshot.boot_id, json: json),
                                 completion: completion, activation: false, navigation: target.map { (method, $0) }))
            do { try sendNext() } catch { fail(error) }
        }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func recordStage(_ stage: String, seconds: TimeInterval) {
        stageLatencies[stage, default: .init()].record(seconds: seconds)
    }

    func recordRenderTiming(_ timing: HerdrShellRenderTiming?) {
        guard let timing else { return }
        recordStage("encodeQueue", seconds: timing.queue)
        recordStage("encode", seconds: timing.encode)
        recordStage("encodeActorResume", seconds: timing.resume)
    }

    private func receive(_ message: HerdrShellServerMessage) throws {
        lastReceived = now; pingSentAt = nil
        guard welcome != nil else {
            guard case let .control(kind, data) = message, kind == "endpoint.welcome.v1" else { throw CLIError("Expected Herdr endpoint welcome") }
            let value = try JSONDecoder().decode(HerdrShellWelcome.self, from: Data(data.utf8))
            try value.validate()
            if endpoint.machine != nil, value.capabilities?.contains("health_check") != true { throw CLIError("Remote Herdr does not support health checks") }
            welcome = value; return
        }
        switch message {
        case let .control(kind, data):
            if kind == "shell.snapshot.v1" {
                let decodedAt = now
                let snapshot = try JSONDecoder().decode(HerdrShellSnapshot.self, from: Data(data.utf8))
                recordStage("snapshotDecode", seconds: now - decodedAt)
                if let previous = projection.snapshot, previous.boot_id != snapshot.boot_id {
                    throw CLIError("Herdr service restarted; reconnect to establish a new runtime identity")
                }
                if endpoint.machine != nil { serviceIdentity = .remote(endpoint: endpoint, bootID: snapshot.boot_id) }
                let appliedAt = now
                _ = try projection.receive(snapshot)
                recordStage("snapshotApply", seconds: now - appliedAt)
                if projection.snapshot == snapshot { onMetadata?(snapshot) }
                if activatesWhenMetadataReady, !activationQueued { try activate(snapshot) }
                publish()
            } else if kind == "endpoint.agent-completions.v1" {
                let evidence = try JSONDecoder().decode(HerdrShellAgentCompletions.self, from: Data(data.utf8))
                try evidence.validate()
                if let previous = agentCompletions, previous.boot_id == evidence.boot_id, previous.revision > evidence.revision { return }
                agentCompletions = evidence
                if let snapshot = projection.snapshot, snapshot.boot_id == evidence.boot_id, snapshot.revision == evidence.revision {
                    onMetadata?(snapshot)
                }
            } else if kind == "endpoint.presentation.ready.v1", data == fenceToken {
                fenceToken = nil; publish()
            }
        case let .surface(surface):
            let appliedAt = now
            _ = try projection.receive(surface)
            recordStage("surfaceApply", seconds: now - appliedAt)
            publish()
        case let .patch(patch):
            let appliedAt = now
            _ = try projection.receive(patch)
            recordStage("patchApply", seconds: now - appliedAt)
            publish()
        case let .response(boot, id, final, data): try response(boot: boot, id: id, final: final, data: data)
        case let .shutdown(reason): throw CLIError(reason ?? "Herdr server disconnected")
        // ClientShellError is an operation rejection notice; the upstream client keeps its connection.
        case .failure: onEffect?(message)
        // Semantic notifications belong to the metadata lane, including inactive endpoints.
        case .notification(let event): onNotification?(event)
        default:
            if state == .interactive, fenceToken == nil { try deliverOrDeferEffect(message) }
        }
    }

    func activate(size: HerdrShellSize, cellWidth: UInt32, cellHeight: UInt32) throws {
        guard transport != nil, welcome != nil, let snapshot = projection.snapshot,
              !activationQueued, size.cols > 0, size.rows > 0, cellWidth > 0, cellHeight > 0 else {
            throw CLIError("Herdr shell metadata or native viewport is not ready for activation")
        }
        try resize(size, cellWidth: cellWidth, cellHeight: cellHeight)
        activatesWhenMetadataReady = true
        try activate(snapshot)
    }

    func deactivate() throws {
        guard let transport, let snapshot = projection.snapshot, activationQueued else { return }
        try releaseHeldInput()
        activatesWhenMetadataReady = false; activationQueued = false; activationRevision = nil
        fenceToken = nil; pairMissingSince = nil
        offeredPresentation = nil; presented = nil; presentedGeometry = nil; pinnedPresentation = nil
        presentedFromPinnedFrame = false; hasPresentedSurface = false
        deferredEffects.removeAll(); deferredEffectBytes = 0
        let id = UUID().uuidString
        let json = String(decoding: try JSONEncoder().encode(Request(id: id, method: "client_shell.surface.set", params: SurfaceInterest(active: false))), as: UTF8.self)
        pending.append(.init(id: id, boot: snapshot.boot_id, message: .request(boot: snapshot.boot_id, json: json), completion: nil, activation: true, deactivation: true))
        try transport.send(.focus(false))
        updateState(.subscribed)
        try sendNext()
    }

    private func activate(_ snapshot: HerdrShellSnapshot) throws {
        guard !snapshot.workspaces.isEmpty, welcome?.methods?.contains("client_shell.surface.set") == true else {
            throw CLIError("Herdr has no existing workspace or compatible surface activation")
        }
        let id = UUID().uuidString
        let json = String(decoding: try JSONEncoder().encode(Request(id: id, method: "client_shell.surface.set", params: SurfaceInterest(active: true))), as: UTF8.self)
        try transport?.send(.resize(size, cellWidth, cellHeight, true))
        pending.append(.init(id: id, boot: snapshot.boot_id, message: .request(boot: snapshot.boot_id, json: json), completion: nil, activation: true))
        activationQueued = true
        try sendNext()
        try transport?.send(.focus(hostFocused))
        if let hostColors { try setHostColors(hostColors) }
        if let hostDark { try setAppearance(dark: hostDark) }
    }

    private func sendNext() throws {
        guard !pending.isEmpty, pending[0].sentAt == nil, navigation == nil else { return }
        if !pending[0].activation {
            let focus = pending[0].navigation
            let target = focus?.method == "pane.focus" ? focus?.target : nil
            let visible = target.map { projection.coherentSurface?.containsInputTarget($0, popup: false) == true } == true
            try releaseHeldInput(keepingMouseIn: visible ? target : nil)
        }
        if let selection = pending[0].navigation, let snapshot = projection.snapshot {
            let alreadySelected = selectionMatches(method: selection.method, target: selection.target, snapshot: snapshot)
            guard alreadySelected || snapshot.revision < UInt64.max else { throw CLIError("Herdr projection revision overflow") }
            navigation = (pending[0].id, selection.method, selection.target,
                          alreadySelected ? snapshot.revision : snapshot.revision + 1, false)
            if navigationTiming != nil, supersededNavigations < Int.max { supersededNavigations += 1 }
            navigationTiming = .init(requestID: pending[0].id, boot: snapshot.boot_id,
                                     method: selection.method, target: selection.target, issuedAt: now)
            updateState(.connecting)
        }
        pending[0].sentAt = now
        try transport?.send(pending[0].message)
    }

    func hasHeldMouse(target: String, popup: Bool = false, button: UInt32? = nil) -> Bool {
        heldReleases.keys.contains { $0.mouse && $0.popup == popup && $0.target == target && (button == nil || $0.code == button) }
    }

    func hasHeldKey(target: String, popup: Bool = false, physicalKeyID: UInt32) -> Bool {
        heldReleases.keys.contains { !$0.mouse && $0.popup == popup && $0.target == target && $0.physical == physicalKeyID }
    }

    private func releaseHeldInput(keepingMouseIn paneID: String? = nil) throws {
        let released = heldReleases.filter { !($0.key.mouse && !$0.key.popup && $0.key.target == paneID) }
        let grouped = Dictionary(grouping: released, by: { "\($0.key.popup ? 1 : 0):\($0.key.target)" })
        for values in grouped.values {
            let target = values[0].key
            try transport?.send(.input(target: target.target, popup: target.popup, events: values.map(\.value)))
        }
        for key in released.keys { heldReleases.removeValue(forKey: key) }
        focusMouseTarget = paneID.flatMap { hasHeldMouse(target: $0) ? $0 : nil }
    }

    private func response(boot: String, id: String, final: Bool, data: Data) throws {
        guard !pending.isEmpty, pending[0].id == id, pending[0].boot == boot else { throw CLIError("Unexpected Herdr endpoint response") }
        guard data.count <= 8 * 1024 * 1024 - pending[0].response.count else { throw CLIError("Herdr endpoint response exceeds budget") }
        pending[0].response.append(data)
        guard final else { return }
        let request = pending[0]
        let response = try JSONDecoder().decode(Response.self, from: request.response)
        guard response.id == request.id else { throw CLIError("Herdr endpoint response ID mismatch") }
        let receivedAt = now
        if let sent = request.sentAt { requestLatencies.record(seconds: receivedAt - sent) }
        if let error = response.error {
            pending.removeFirst()
            let failure = HerdrRemoteError(code: error.code, message: error.message)
            request.completion?.resume(throwing: failure)
            if navigation?.requestID == request.id { navigation = nil; navigationTiming = nil }
            if request.navigation != nil { try releaseHeldInput() }
            if request.activation { throw failure }
        } else {
            guard response.result != nil else { throw CLIError("Missing Herdr endpoint operation result") }
            if request.deactivation {
                guard response.result?.active == false else { throw CLIError("Herdr surface deactivation acknowledgement is invalid") }
            } else if request.activation {
                guard response.result?.active == true, let revision = response.result?.projection_revision else {
                    throw CLIError("Herdr surface activation acknowledgement is invalid")
                }
                activationRevision = revision
                if welcome?.capabilities?.contains("presentation_effects_fence") == true {
                    let token = UUID().uuidString; fenceToken = token
                    try transport?.send(.control("endpoint.presentation.sync.v1", token))
                }
            }
            pending.removeFirst()
            if navigation?.requestID == request.id {
                navigation?.acknowledged = true
                if let timing = navigationTiming, timing.requestID == request.id {
                    navigationTiming?.responseAt = receivedAt
                    navigationResponseLatencies.record(seconds: receivedAt - timing.issuedAt)
                }
            }
            request.completion?.resume(returning: request.response)
        }
        try sendNext(); publish()
    }

    private func publish() {
        let publishedAt = now
        defer { recordStage("publish", seconds: now - publishedAt) }
        if let navigation, navigation.acknowledged, let snapshot = projection.snapshot,
           let surface = projection.coherentSurface, projection.pendingSurface == nil,
           surface.projection_revision >= navigation.minimumRevision,
           selectionMatches(method: navigation.method, target: navigation.target, snapshot: snapshot) {
            if let timing = navigationTiming, timing.requestID == navigation.requestID, let responseAt = timing.responseAt {
                let matchedAt = now
                navigationTiming?.matchedAt = matchedAt
                navigationSceneLatencies.record(seconds: matchedAt - responseAt)
            }
            self.navigation = nil
            do { try sendNext() } catch { fail(error); return }
        }
        guard let snapshot = projection.snapshot, let surface = projection.coherentSurface, projection.pendingSurface == nil,
              let activationRevision, surface.projection_revision >= activationRevision,
              surface.frame.width == size.cols, surface.frame.height == size.rows, fenceToken == nil, navigation == nil else {
            if activationQueued { pairMissingSince = pairMissingSince ?? now; updateState(.connecting) }
            return
        }
        let stamp = Presentation(surface)
        if presented != stamp {
            pairMissingSince = pairMissingSince ?? now
            if presentedGeometry != Geometry(snapshot, surface) {
                let geometry = Geometry(snapshot, surface)
                let keep = focusMouseTarget == snapshot.focused_pane_id
                    && presentedGeometry?.hasSameViewport(as: geometry) == true ? focusMouseTarget : nil
                do { try releaseHeldInput(keepingMouseIn: keep) } catch { fail(error); return }
                updateState(.connecting)
            }
        }
        if let pin = pinnedPresentation {
            if pin.stamp.boot == stamp.boot, pin.stamp.projection == stamp.projection,
               pin.geometry == Geometry(snapshot, surface) { return }
            pinnedPresentation = nil
        }
        if offeredPresentation != stamp {
            offeredPresentation = stamp
            offeredAt = now
            onProjection?(snapshot, surface, projection.assets)
        }
        if presented == stamp {
            pairMissingSince = nil
            updateState(.interactive)
        }
    }

    var isPresentationReady: Bool {
        guard transport != nil, state == .interactive, navigation == nil, fenceToken == nil,
              let frame = projection.coherentSurface, projection.pendingSurface == nil,
              frame.frame.width == size.cols, frame.frame.height == size.rows else { return false }
        if presented == Presentation(frame) { return true }
        guard presentedFromPinnedFrame, let presented, let snapshot = projection.snapshot else { return false }
        return presented.boot == frame.boot_id && presented.projection == frame.projection_revision
            && presentedGeometry == Geometry(snapshot, frame)
    }

    var isInputReady: Bool {
        if isPresentationReady { return true }
        guard transport != nil, state == .interactive, navigation == nil, fenceToken == nil,
              let frame = projection.coherentSurface, projection.pendingSurface == nil,
              frame.frame.width == size.cols, frame.frame.height == size.rows,
              let presented, let snapshot = projection.snapshot else { return false }
        return presented.boot == frame.boot_id && presented.projection == frame.projection_revision
            && presentedGeometry == Geometry(snapshot, frame)
    }

    func beginPresentation(_ frame: HerdrShellSurface) -> Bool {
        guard canPresent(frame), offeredPresentation == Presentation(frame), let snapshot = projection.snapshot else { return false }
        pinnedPresentation = (Presentation(frame), Geometry(snapshot, frame))
        return true
    }

    func endPresentation(_ frame: HerdrShellSurface) {
        guard pinnedPresentation?.stamp == Presentation(frame) else { return }
        pinnedPresentation = nil
        publish()
    }

    func canPresent(_ frame: HerdrShellSurface) -> Bool {
        guard transport != nil, navigation == nil, fenceToken == nil, projection.pendingSurface == nil,
              let snapshot = projection.snapshot, let current = projection.coherentSurface,
              snapshot.boot_id == frame.boot_id, snapshot.revision == frame.projection_revision,
              frame.frame.width == size.cols, frame.frame.height == size.rows,
              current.frame.width == size.cols, current.frame.height == size.rows else { return false }
        if Presentation(current) == Presentation(frame) { return true }
        guard let pin = pinnedPresentation, pin.stamp == Presentation(frame),
              current.boot_id == frame.boot_id, current.projection_revision == frame.projection_revision else { return false }
        return pin.geometry == Geometry(snapshot, current)
    }

    func invalidatePresentation() throws {
        guard transport != nil else { return }
        try releaseHeldInput()
        presented = nil; presentedGeometry = nil; offeredPresentation = nil
        pinnedPresentation = nil; presentedFromPinnedFrame = false
        pairMissingSince = now
        updateState(.connecting)
        publish()
    }

    // The host calls this only after native topology and every visible Ghostty surface commit.
    @discardableResult
    func acknowledgePresentation(_ frame: HerdrShellSurface) -> Bool {
        let stamp = Presentation(frame)
        guard transport != nil, stamp == offeredPresentation, let current = projection.coherentSurface,
              canPresent(frame), projection.pendingSurface == nil, navigation == nil,
              current.frame.width == size.cols, current.frame.height == size.rows,
              let activationRevision, current.projection_revision >= activationRevision, fenceToken == nil else { return false }
        presented = stamp; presentedGeometry = projection.snapshot.map { Geometry($0, frame) }
        presentedFromPinnedFrame = pinnedPresentation?.stamp == stamp
        pairMissingSince = nil
        let committedAt = now
        if let offeredAt { hostCommitLatencies.record(seconds: committedAt - offeredAt); self.offeredAt = nil }
        if let timing = navigationTiming, let matchedAt = timing.matchedAt,
           let snapshot = projection.snapshot, snapshot.boot_id == timing.boot,
           selectionMatches(method: timing.method, target: timing.target, snapshot: snapshot) {
            navigationCommitLatencies.record(seconds: committedAt - matchedAt)
            navigationTotalLatencies.record(seconds: committedAt - timing.issuedAt)
            navigationTiming = nil
        }
        hasPresentedSurface = true
        updateState(.interactive)
        flushDeferredEffects(stamp)
        return true
    }

    private func deliverOrDeferEffect(_ message: HerdrShellServerMessage) throws {
        if isPresentationReady, let frame = projection.coherentSurface, presented == Presentation(frame) {
            onEffect?(message); return
        }
        guard projection.pendingSurface == nil, let frame = projection.coherentSurface,
              let bytes = message.presentationEffectBytes else { return }
        guard deferredEffects.count < 128, bytes <= 4 * 1024 * 1024 - deferredEffectBytes else {
            throw CLIError("Herdr presentation effect queue exceeds budget")
        }
        deferredEffects.append((message, Presentation(frame))); deferredEffectBytes += bytes
    }

    private func flushDeferredEffects(_ stamp: Presentation) {
        let effects = deferredEffects
        deferredEffects.removeAll(); deferredEffectBytes = 0
        for (message, expected) in effects {
            guard isPresentationReady, expected.boot == stamp.boot, expected.projection == stamp.projection else { continue }
            if expected.surface > stamp.surface {
                deferredEffects.append((message, expected))
                deferredEffectBytes += message.presentationEffectBytes ?? 0
                continue
            }
            onEffect?(message)
        }
    }

    private func selectionMatches(method: String, target: String, snapshot: HerdrShellSnapshot) -> Bool {
        switch method {
        case "pane.focus": snapshot.focused_pane_id == target
        case "tab.focus": snapshot.focused_tab_id == target
        case "workspace.focus": snapshot.focused_workspace_id == target
        default: false
        }
    }

    private func tick() throws {
        if welcome == nil, now - startedAt > 5 { throw CLIError("Herdr shell handshake timed out") }
        if projection.snapshot == nil, now - startedAt > 10 { throw CLIError("Herdr shell initial metadata timed out") }
        if let missing = pairMissingSince, now - missing > 10 {
            throw CLIError(projection.coherentSurface != nil
                ? "Herdr native presentation did not synchronize" : "Herdr snapshot and surface did not synchronize")
        }
        if let request = pending.first, let sent = request.sentAt, now - sent > 10 {
            throw CLIError("Herdr endpoint operation timed out; its result is unknown and it was not replayed")
        }
        if let ping = pingSentAt, now - ping > 10 { throw HerdrShellConnectionLost(message: "Herdr shell health check timed out") }
        if welcome?.capabilities?.contains("health_check") == true, pingSentAt == nil, now - lastReceived >= 5 {
            try transport?.send(.control("endpoint.health.ping.v1", "")); pingSentAt = now
        }
    }

    private func fail(_ error: any Error) {
        let recoverable = hasPresentedSurface && (error is HerdrShellConnectionLost || (error as? HerdrSSHFailure)?.needsAttention == false)
        var snapshot = currentDiagnostics
        snapshot.state = "failed"; snapshot.presentationReady = false; snapshot.capturedAtFailure = true
        disconnect()
        failure = error
        failureDiagnostics = snapshot
        updateState(.failed(error.localizedDescription))
        onFailure?(error, recoverable)
    }

    private func updateState(_ next: HerdrConnectionState) {
        guard state != next else { return }
        if next != .interactive { deferredEffects.removeAll(); deferredEffectBytes = 0 }
        state = next; onState?(next)
    }

    var diagnostics: HerdrDiagnostics.ClientShell {
        failureDiagnostics ?? currentDiagnostics
    }

    private var currentDiagnostics: HerdrDiagnostics.ClientShell {
        let capabilities: Set<String> = ["surface_interest", "health_check", "presentation_effects_fence", "surface_reuse", "surface_delta", "surface_scroll"]
        let codecs: Set<String> = ["shell.snapshot.v1", "shell.surface.v1", "shell.input.semantic.v1", "shell.blob.v1"]
        let frame = projection.coherentSurface
        return .init(state: state.diagnosticName, generation: welcome?.generation,
            codecs: welcome.map { [$0.snapshot_codec, $0.surface_codec, $0.input_codec, $0.blob_codec].filter { codecs.contains($0) } } ?? [],
            serverCapabilities: (welcome?.capabilities ?? []).filter { capabilities.contains($0) }.sorted(),
            bootID: projection.snapshot?.boot_id, projectionRevision: projection.snapshot?.revision,
            surfaceProjectionRevision: frame?.projection_revision, surfaceRevision: frame?.surface_revision,
            pendingSurfaceRevision: projection.pendingSurface?.surface_revision,
            requestedColumns: size.cols, requestedRows: size.rows, actualColumns: frame?.frame.width, actualRows: frame?.frame.height,
            cellWidthPixels: cellWidth, cellHeightPixels: cellHeight, hostDark: hostDark, presentationReady: isPresentationReady,
            awaitingFence: fenceToken != nil, navigating: navigation != nil, pendingRequests: pending.count,
            deferredEffects: deferredEffects.count,
            assetCount: projection.assets.count, encodedAssetBytes: projection.assets.values.reduce(0) { $0 + $1.count },
            popupTerminalID: frame?.popup?.terminal_id, requestToResponse: requestLatencies.summary,
            sceneOfferToHostCommit: hostCommitLatencies.summary,
            navigationRequestToResponse: navigationResponseLatencies.summary,
            navigationResponseToMatchingScene: navigationSceneLatencies.summary,
            navigationMatchingSceneToHostCommit: navigationCommitLatencies.summary,
            navigationTotal: navigationTotalLatencies.summary,
            navigationAwaitingHostCommit: navigationTiming?.matchedAt != nil,
            supersededNavigations: supersededNavigations, queues: transport?.queueUsage,
            stages: stageLatencies.mapValues(\.summary), surfaceTraffic: surfaceTraffic)
    }
}
