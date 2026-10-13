import AppKit

enum PaletteItemKind: String, CaseIterable {
    case workspace = "Workspace", tab = "Tab", pane = "Pane", command = "Command"
}

struct AppCommand {
    let id: String
    let title: String
    let shortcut: String?
    let isEnabled: Bool
    var kind: PaletteItemKind = .command
    var subtitle: String? = nil
    var symbol: String? = nil
    var isCurrent: Bool = false
    var isInCurrentWorkspace: Bool = false
    let perform: @MainActor () -> Void
}

struct AppCommandSnapshot: Equatable {
    let id: String
    let title: String
    let shortcut: String?
    let isEnabled: Bool
    var kind: PaletteItemKind = .command
    var subtitle: String? = nil
    var symbol: String? = nil
    var isCurrent: Bool = false
    var isInCurrentWorkspace: Bool = false
}

extension AppCommand {
    var paletteSnapshot: AppCommandSnapshot {
        .init(id: id, title: title, shortcut: shortcut, isEnabled: isEnabled, kind: kind,
              subtitle: subtitle, symbol: symbol, isCurrent: isCurrent, isInCurrentWorkspace: isInCurrentWorkspace)
    }
}

enum CommandPaletteFilter {
    static func results(_ items: [AppCommand], query: String, kind: PaletteItemKind?) -> [AppCommand] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.enumerated().compactMap { index, item -> (Int, Int, AppCommand)? in
            guard item.isEnabled, kind == nil || kind == item.kind else { return nil }
            if query.isEmpty {
                guard kind != nil || item.kind == .workspace || item.kind == .command
                    || (item.kind == .tab && item.isInCurrentWorkspace) else { return nil }
                return (0, index, item)
            }
            let fields = [item.title, item.subtitle ?? ""].joined(separator: " ").lowercased()
            guard query.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy({
                matches(query: String($0), title: fields)
            }) else { return nil }
            let title = item.title.lowercased(), normalized = query.lowercased()
            let rank = title == normalized ? 0 : title.hasPrefix(normalized) ? 1 : title.contains(normalized) ? 2 : 3
            return (rank * 2 + (item.isInCurrentWorkspace ? 0 : 1), index, item)
        }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    static func matches(query: String, title: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else {
            return true
        }

        let normalizedTitle = title.lowercased()
        if normalizedTitle.contains(normalizedQuery) {
            return true
        }

        var titleIndex = normalizedTitle.startIndex
        for queryCharacter in normalizedQuery {
            guard let matchIndex = normalizedTitle[titleIndex...].firstIndex(of: queryCharacter) else {
                return false
            }

            titleIndex = normalizedTitle.index(after: matchIndex)
        }

        return true
    }
}
