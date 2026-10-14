import Foundation

enum HerdrDiagnosticError {
    // Export categories, never arbitrary backend/stderr text that may contain user content.
    static func summary(_ message: String?) -> String? {
        guard let message else { return nil }
        let lower = message.lowercased()
        if lower.contains("unsupported") { return "Unsupported client/server version" }
        if lower.contains("identity") { return "Terminal or service identity changed" }
        if lower.contains("ghostty") && lower.contains("image") { return "Local terminal image upload failed" }
        if lower.contains("budget") || lower.contains("queue is full") { return "ClientShell resource limit exceeded" }
        if lower.contains("synchronize") { return "Scene or native presentation did not synchronize" }
        if lower.contains("timed out") || lower.contains("timeout") { return "Connection or version check timed out" }
        if lower.contains("cannot connect") { return "Existing service is unavailable" }
        if lower.contains("executable") || lower.contains("session name") || lower.contains("socket path") { return "Invalid connection settings" }
        return "Connection or operation failed; inspect the in-app error for details"
    }
}

extension HerdrConnectionState {
    var diagnosticName: String {
        switch self {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .reconnecting: "reconnecting"
        case .interactive: "control"
        case .subscribed: "subscribed"
        case .terminalEnded: "ended"
        case .failed: "failed"
        }
    }
}

struct HerdrDiagnostics: Encodable, Sendable {
    struct Latency: Encodable, Sendable, Equatable {
        let sampleCount: Int
        let lastMilliseconds: Double?
        let p50Milliseconds: Double?
        let p95Milliseconds: Double?
        let p99Milliseconds: Double?
    }
    struct SurfaceTraffic: Encodable, Sendable {
        var packets = 0
        var payloadBytes = 0
        var decodedBytes = 0
    }
    struct ClientShell: Encodable, Sendable {
        var state: String
        let generation: Int?
        let codecs: [String]
        let serverCapabilities: [String]
        let bootID: String?
        let projectionRevision: UInt64?
        let surfaceProjectionRevision: UInt64?
        let surfaceRevision: UInt64?
        let pendingSurfaceRevision: UInt64?
        let requestedColumns: UInt16
        let requestedRows: UInt16
        let actualColumns: UInt16?
        let actualRows: UInt16?
        let cellWidthPixels: UInt32
        let cellHeightPixels: UInt32
        let hostDark: Bool?
        var presentationReady: Bool
        let awaitingFence: Bool
        let navigating: Bool
        let pendingRequests: Int
        let deferredEffects: Int
        let assetCount: Int
        let encodedAssetBytes: Int
        let popupTerminalID: String?
        let requestToResponse: Latency
        let sceneOfferToHostCommit: Latency
        let navigationRequestToResponse: Latency
        let navigationResponseToMatchingScene: Latency
        let navigationMatchingSceneToHostCommit: Latency
        let navigationTotal: Latency
        let navigationAwaitingHostCommit: Bool
        let supersededNavigations: Int
        let queues: HerdrClientShellTransport.QueueUsage?
        var stages: [String: Latency] = [:]
        var surfaceTraffic: [String: SurfaceTraffic] = [:]
        var recoveryAttempts = 0
        var popupLastError: String? = nil
        var capturedAtFailure = false
        let directGraphics = false
        let endpointKeybindings = false
        let requestedSurfaceReuse = HerdrShellHello.requestSurfaceReuse
        let requestedSurfaceDelta = HerdrShellHello.requestSurfaceDelta
        let requestedSurfaceScroll = HerdrShellHello.requestSurfaceScroll
        let timingScope = "last 1024 samples per stage in this connection; stages have independent populations and overlapping scopes, do not add percentiles; encode/queue/resume sample one scene worker, scenePrepare includes viewport and encoding, paneViewport/popupViewport sample each host; payloadRead includes socket waiting; ghosttyBarrier includes worker scheduling and parsing wait, not GPU visibility; request starts at worker enqueue; superseded navigation has no total sample"
    }
    struct Pane: Encodable, Sendable {
        let id: UUID
        let backendPaneID: String
        let terminalID: String?
        let mode: HerdrTerminalMode
        let state: String
        let lastError: String?
        var transport: HerdrPaneTransport = .clientShell
    }
    let formatVersion = 1
    let santtyVersion: String
    let session: String?
    let executable: String?
    let socket: String?
    var clientVersion: String?
    var serverVersion: String?
    var protocolVersion: Int?
    let managementState: String
    let panes: [Pane]
    var lastError: String?
    var windowTransport: HerdrPaneTransport? = nil
    var clientShell: ClientShell? = nil
    var serviceLifecycle = "external-only; never started, stopped or upgraded by Santty"
    let historyCapability = "frozen recent text; at most 1000 rows / 256 KiB; no inline images or live cross-history selection"

    func json() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    mutating func inspect(_ endpoint: HerdrEndpoint) async {
        if endpoint.machine != nil { serviceLifecycle = "native SSH bridge; may start the existing remote server; upgrades and replacement require interactive Herdr setup" }
        let result = await Task.detached(priority: .utility) { () -> (String?, HerdrServerInfo?, String?) in
            do {
                try endpoint.validate()
                let version = try HerdrExecutable.version(at: endpoint.binary)
                do {
                    let server = try HerdrConnection.preflight(socketPath: endpoint.socketPath, endpoint: endpoint)
                    return (version, server, nil)
                } catch { return (version, nil, HerdrDiagnosticError.summary(error.localizedDescription)) }
            } catch { return (nil, nil, HerdrDiagnosticError.summary(error.localizedDescription)) }
        }.value
        clientVersion = result.0
        serverVersion = result.1?.version
        protocolVersion = result.1?.protocolVersion
        if let error = result.2 { lastError = error }
    }
}

struct HerdrShellLatencySamples: Sendable {
    private var values: [Double] = []
    private var next = 0

    mutating func record(seconds: TimeInterval) {
        let value = seconds * 1000
        guard value.isFinite, value >= 0 else { return }
        if values.count < 1024 { values.append(value) }
        else { values[next] = value }
        next = (next + 1) % 1024
    }

    var summary: HerdrDiagnostics.Latency {
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double? {
            guard !sorted.isEmpty else { return nil }
            return sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)]
        }
        return .init(sampleCount: values.count,
                     lastMilliseconds: values.isEmpty ? nil : values[(next + values.count - 1) % values.count],
                     p50Milliseconds: percentile(0.5), p95Milliseconds: percentile(0.95), p99Milliseconds: percentile(0.99))
    }
}
