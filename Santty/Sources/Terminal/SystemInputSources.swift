import AppKit
import Carbon.HIToolbox

@MainActor
enum SystemInputSources {
    struct Source: Identifiable, Equatable {
        let id: String
        let name: String
        let languages: [String]
    }

    static var available: [Source] {
        var seen = Set<String>()
        return selectableSources.compactMap { source in
            guard let id = identifier(source), seen.insert(id).inserted else { return nil }
            return Source(id: id, name: property(source, kTISPropertyLocalizedName) ?? id,
                          languages: property(source, kTISPropertyInputSourceLanguages) ?? [])
        }
    }

    static var currentID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return identifier(source)
    }

    static func select(_ id: String, for view: NSView) -> Bool {
        guard let source = selectableSources.first(where: { identifier($0) == id }),
              let sourceID: String = property(source, kTISPropertyInputSourceID),
              let context = view.inputContext else { return false }
        context.selectedKeyboardInputSource = sourceID
        if currentID == id { return true }
        return TISSelectInputSource(source) == noErr && currentID == id
    }

    private static var selectableSources: [TISInputSource] {
        let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as NSArray
        return (sources as? [TISInputSource] ?? []).filter {
            let category: String? = property($0, kTISPropertyInputSourceCategory)
            let enabled: Bool = property($0, kTISPropertyInputSourceIsEnabled) ?? false
            let selectable: Bool = property($0, kTISPropertyInputSourceIsSelectCapable) ?? false
            return category == kTISCategoryKeyboardInputSource as String && enabled && selectable
        }
    }

    private static func identifier(_ source: TISInputSource) -> String? {
        guard let id: String = property(source, kTISPropertyInputSourceID) else { return nil }
        let mode: String? = property(source, kTISPropertyInputModeID)
        return mode.map { $0.isEmpty ? id : id + "::" + $0 } ?? id
    }

    private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return unsafeBitCast(pointer, to: AnyObject.self) as? T
    }
}
