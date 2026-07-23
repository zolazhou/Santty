import AppKit

struct AppCommand {
    let id: String
    let title: String
    let shortcut: String?
    let isEnabled: Bool
    let perform: @MainActor () -> Void
}

struct AppCommandSnapshot: Equatable {
    let id: String
    let title: String
    let shortcut: String?
    let isEnabled: Bool
}

enum CommandPaletteFilter {
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
