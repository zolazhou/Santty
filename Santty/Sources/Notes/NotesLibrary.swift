import Foundation
import Observation

struct NoteSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let preview: String
    let modifiedAt: Date
}

@MainActor
@Observable
final class NotesLibrary {
    let directoryURL: URL
    private(set) var store: NotesStore
    private(set) var notes: [NoteSummary] = []
    private(set) var results: [NoteSummary] = []
    private(set) var isWorking = false
    private(set) var isSearching = false
    var errorMessage: String?
    var searchQuery = "" { didSet { scheduleSearch() } }
    var isBrowserPresented = false
    var browserSelection: String?
    var isFormattingExpanded: Bool {
        didSet { defaults.set(isFormattingExpanded, forKey: "Santty.NotesFormattingExpanded") }
    }

    var activeID: String { store.fileURL.lastPathComponent }
    var activeTitle: String { Self.title(for: activeID) }
    var visibleNotes: [NoteSummary] { searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? notes : results }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let files: NoteFiles
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var monitor: NotesFileMonitor?

    init(store: NotesStore = NotesStore(), defaults: UserDefaults = .standard) {
        self.store = store
        directoryURL = store.fileURL.deletingLastPathComponent()
        files = NoteFiles(directory: directoryURL)
        self.defaults = defaults
        isFormattingExpanded = defaults.bool(forKey: "Santty.NotesFormattingExpanded")
        monitor = NotesFileMonitor(url: directoryURL) { [weak self] in
            Task { [weak self] in await self?.refresh() }
        }
    }

    func load() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            notes = try await files.list()
            let preferred = defaults.string(forKey: "Santty.NotesLastFile")
            let selected = notes.first(where: { $0.id == preferred })?.id
                ?? notes.first(where: { $0.id == activeID })?.id ?? notes.first?.id
            if let selected, selected != activeID {
                store = NotesStore(fileURL: try await files.url(for: selected))
            }
            await store.load()
            rememberSelection()
            includeCurrentDraft()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            await store.load()
        }
    }

    func refresh() async {
        do {
            notes = try await files.list()
            includeCurrentDraft()
            scheduleSearch()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func select(_ id: String) async throws -> Bool {
        guard !isWorking, id != activeID else { return false }
        isWorking = true
        defer { isWorking = false }
        try await saveBeforeChangingDocument()
        let next = NotesStore(fileURL: try await files.existingURL(for: id))
        await next.load()
        store = next
        rememberSelection()
        await refresh()
        return true
    }

    func create() async throws {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        try await saveBeforeChangingDocument()
        let url = try await files.create()
        let next = NotesStore(fileURL: url)
        await next.load()
        store = next
        rememberSelection()
        await refresh()
    }

    func rename(_ id: String, to title: String) async throws {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        try await saveBeforeChangingDocument()
        if id == activeID { try await files.materializeDraft(id) }
        let renamed = try await files.rename(id, to: title)
        if id == activeID {
            let next = NotesStore(fileURL: renamed)
            await next.load()
            store = next
            rememberSelection()
        }
        await refresh()
    }

    func trash(_ id: String) async throws {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        try await saveBeforeChangingDocument()
        if id == activeID { try await files.materializeDraft(id) }
        try await files.trash(id)
        if id == activeID {
            let remaining = try await files.list()
            let url: URL
            if let first = remaining.first { url = try await files.url(for: first.id) }
            else { url = try await files.create() }
            let next = NotesStore(fileURL: url)
            await next.load()
            store = next
            rememberSelection()
        }
        await refresh()
    }

    func searchNow() async {
        let query = searchQuery
        isSearching = true
        defer { if query == searchQuery { isSearching = false } }
        let matches = await files.search(query, notes: notes, draftID: activeID, draft: store.text)
        guard !Task.isCancelled, query == searchQuery else { return }
        results = matches
    }

    private func saveBeforeChangingDocument() async throws {
        guard !store.isSavingSuspended else { throw NotesStore.SaveError.writingToolsActive }
        try await store.flush()
    }

    private func rememberSelection() {
        defaults.set(activeID, forKey: "Santty.NotesLastFile")
    }

    private func includeCurrentDraft() {
        guard !notes.contains(where: { $0.id == activeID }) else { return }
        notes.insert(NoteSummary(id: activeID, title: activeTitle, preview: Self.preview(store.text), modifiedAt: .now), at: 0)
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                guard let self else { return }
                await self.searchNow()
            } catch {}
        }
    }

    nonisolated static func title(for id: String) -> String {
        id == "note.md" ? "Notes" : (id as NSString).deletingPathExtension
    }

    nonisolated static func preview(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(140) ?? "")
    }

    private actor NoteFiles {
        let directory: URL
        init(directory: URL) { self.directory = directory }

        func url(for id: String) throws -> URL {
            guard !id.isEmpty, (id as NSString).lastPathComponent == id,
                !id.hasPrefix("."), id.lowercased().hasSuffix(".md") else { throw FileError.invalidName }
            let url = directory.appendingPathComponent(id)
            guard url.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.resolvingSymlinksInPath().path,
                (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil
            else { throw FileError.invalidName }
            return url
        }

        func existingURL(for id: String) throws -> URL {
            let result = try url(for: id)
            guard FileManager.default.fileExists(atPath: result.path) else { throw CocoaError(.fileReadNoSuchFile) }
            return result
        }

        func materializeDraft(_ id: String) throws {
            let destination = try url(for: id)
            guard !FileManager.default.fileExists(atPath: destination.path) else { return }
            let temporary = directory.appendingPathComponent(".\(UUID()).tmp")
            try Data().write(to: temporary, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.moveItem(at: temporary, to: destination)
        }

        func list() throws -> [NoteSummary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let entries = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            return entries.compactMap { entry in
                guard let checked = try? url(for: entry.lastPathComponent),
                    let values = try? checked.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                    values.isRegularFile == true else { return nil }
                let preview = (try? String(contentsOf: checked, encoding: .utf8)).map(NotesLibrary.preview) ?? "Unreadable Markdown"
                return NoteSummary(id: entry.lastPathComponent, title: NotesLibrary.title(for: entry.lastPathComponent),
                                   preview: preview, modifiedAt: values.contentModificationDate ?? .distantPast)
            }.sorted { $0.modifiedAt == $1.modifiedAt ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.modifiedAt > $1.modifiedAt }
        }

        func create() throws -> URL {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var suffix = 1
            while true {
                let name = suffix == 1 ? "Untitled.md" : "Untitled \(suffix).md"
                let destination = try url(for: name)
                let temporary = directory.appendingPathComponent(".\(UUID()).tmp")
                try Data().write(to: temporary, options: .atomic)
                do {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    return destination
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    guard FileManager.default.fileExists(atPath: destination.path) else { throw error }
                    suffix += 1
                }
            }
        }

        func rename(_ id: String, to rawTitle: String) throws -> URL {
            var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.lowercased().hasSuffix(".md") { title.removeLast(3) }
            guard !title.isEmpty, !title.hasPrefix("."), title.utf8.count <= 240,
                !title.contains(where: { "/\\:".contains($0) }),
                !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw FileError.invalidName }
            let source = try url(for: id)
            let destination = try url(for: title + ".md")
            if source == destination { return source }
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }

        func trash(_ id: String) throws {
            try FileManager.default.trashItem(at: url(for: id), resultingItemURL: nil)
        }

        func search(_ query: String, notes: [NoteSummary], draftID: String, draft: String) -> [NoteSummary] {
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            let words = query.split(whereSeparator: \.isWhitespace).map { String($0).folding(options: options, locale: .current) }
            var matches: [(NoteSummary, Int)] = []
            for note in notes {
                if Task.isCancelled { break }
                let source = note.id == draftID ? draft : ((try? url(for: note.id)).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
                let title = note.title.folding(options: options, locale: .current)
                let body = source.folding(options: options, locale: .current)
                guard words.allSatisfy({ title.contains($0) || body.contains($0) }) else { continue }
                let excerpt = source.split(whereSeparator: \.isNewline).first {
                    let line = String($0).folding(options: options, locale: .current)
                    return words.contains(where: line.contains)
                }.map { String($0.prefix(140)) } ?? note.preview
                matches.append((NoteSummary(id: note.id, title: note.title, preview: excerpt, modifiedAt: note.modifiedAt),
                                words.filter { title.contains($0) }.count))
            }
            return matches.sorted { $0.1 == $1.1 ? $0.0.modifiedAt > $1.0.modifiedAt : $0.1 > $1.1 }.map(\.0)
        }
    }

    enum FileError: LocalizedError {
        case invalidName
        var errorDescription: String? { "Use a nonempty note name without path separators or control characters." }
    }
}
