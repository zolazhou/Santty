import AppKit

let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
let isRunningSwiftUIPreviews =
    ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

private final class MinimalAppDelegate: NSObject, NSApplicationDelegate {}

MainActor.assumeIsolated {
    let shouldUseMinimalAppDelegate = isRunningTests || isRunningSwiftUIPreviews
    let delegate: NSApplicationDelegate =
        shouldUseMinimalAppDelegate ? MinimalAppDelegate() : AppDelegate()
    let app = NSApplication.shared
    app.setActivationPolicy(isRunningSwiftUIPreviews ? .prohibited : .regular)
    app.delegate = delegate
    app.run()
}
