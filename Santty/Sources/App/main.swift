import AppKit

let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
let isRunningSwiftUIPreviews =
    ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

private final class MinimalAppDelegate: NSObject, NSApplicationDelegate {}

MainActor.assumeIsolated {
    // Driver construction also checks the cached system result and presents errors.
    _ = try? GhosttyVTSystem.prepare()
    let app = NSApplication.shared
    app.appearance = NSAppearance(named: .darkAqua)
    let shouldUseMinimalAppDelegate = isRunningTests || isRunningSwiftUIPreviews
    let delegate: NSApplicationDelegate =
        shouldUseMinimalAppDelegate ? MinimalAppDelegate() : AppDelegate()
    app.setActivationPolicy(isRunningSwiftUIPreviews ? .prohibited : .regular)
    app.delegate = delegate
    app.run()
}
