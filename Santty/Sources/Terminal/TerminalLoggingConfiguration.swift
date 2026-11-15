import Foundation

struct NativeTerminalLogCategory: OptionSet, Sendable {
    let rawValue: UInt8
    static let lifecycle = Self(rawValue:1)
    static let metrics = Self(rawValue:2)
    static let input = Self(rawValue:4)
    static let output = Self(rawValue:8)
    static let ime = Self(rawValue:16)
    static let actions = Self(rawValue:32)
    static let render = Self(rawValue:64)
    static let standard: Self = [.lifecycle,.metrics,.actions]
    static let all = Self(rawValue:127)
}
/// Opt-in host diagnostics only. Never log terminal bytes, commands, environment
/// values, clipboard contents, links or raw connection errors.
@MainActor
enum NativeTerminalDebugLog {
    static var isEnabled = false
    static var categories: NativeTerminalLogCategory = []
    static var sink: ((String) -> Void)?
    static func enable(_ value: NativeTerminalLogCategory) { categories = value; isEnabled = !value.isEmpty }
    static func disable() { isEnabled = false; categories = [] }
    static func record(_ category: NativeTerminalLogCategory, _ message: String) {
        guard isEnabled, !categories.intersection(category).isEmpty else { return }
        sink?(message)
    }
}
@MainActor
enum TerminalLoggingConfiguration {
    static func apply(environment: [String:String] = ProcessInfo.processInfo.environment) {
        let value = environment["SANTTY_TERMINAL_DEBUG_LOG"]?.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() ?? ""
        switch value {
        case "", "0","false","off","none": NativeTerminalDebugLog.disable()
        case "1","true","on","standard": NativeTerminalDebugLog.enable(.standard)
        case "all": NativeTerminalDebugLog.enable(.all)
        default:
            let known: [String:NativeTerminalLogCategory] = ["lifecycle":.lifecycle,"metrics":.metrics,"input":.input,
                "output":.output,"ime":.ime,"actions":.actions,"render":.render]
            NativeTerminalDebugLog.enable(value.split(separator:",").reduce([]) {
                $0.union(known[$1.trimmingCharacters(in:.whitespacesAndNewlines)] ?? [])
            })
        }
    }
}
