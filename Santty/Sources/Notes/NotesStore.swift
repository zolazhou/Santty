import Foundation
import Observation

@MainActor
@Observable
final class NotesStore {
    let fileURL: URL
    let documentID = UUID().uuidString
    private(set) var text = ""
    private(set) var isLoaded = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasReadError = false
    private(set) var isSavingSuspended = false
    private(set) var hasExternalChange = false
    private var activeSaveCount = 0

    var canEdit: Bool { isLoaded && !hasReadError }
    var isSaving: Bool { activeSaveCount > 0 }
    var hasUnsavedChanges: Bool { text != savedText }

    @ObservationIgnored private let fileAccess: FileAccess
    @ObservationIgnored private var savedText = ""
    @ObservationIgnored private var savedContents: String?
    @ObservationIgnored var canReload: (() -> Bool)?
    @ObservationIgnored private var monitor: NotesFileMonitor?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var lastSavedRevision = -1
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    static var defaultFileURL: URL {
        #if DEBUG
        let directory = "Santty-Dev"
        #else
        let directory = "Santty"
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("Notes", isDirectory: true)
            .appendingPathComponent("note.md")
    }

    init(fileURL: URL = NotesStore.defaultFileURL) {
        self.fileURL = fileURL
        fileAccess = FileAccess(fileURL: fileURL)
    }

    func load() async {
        guard !isLoading, !isLoaded || hasReadError else { return }
        if isLoaded && hasUnsavedChanges {
            await reloadFromDisk()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let contents = try await fileAccess.read()
            text = contents ?? ""
            savedText = text
            savedContents = contents
            hasReadError = false
            errorMessage = nil
        } catch {
            hasReadError = true
            errorMessage = "Could not read notes: \(error.localizedDescription)"
        }
        isLoaded = true
        if monitor == nil {
            monitor = NotesFileMonitor(url: fileURL) { [weak self] in self?.scheduleReload() }
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            do {
                while let self, isSaving || isSavingSuspended || canReload?() == false {
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                await self?.reloadFromDisk()
            } catch {}
        }
    }

    func reloadFromDisk() async {
        guard isLoaded, !isLoading, !isSaving, !isSavingSuspended, canReload?() != false else { return }
        let loadedRevision = revision
        do {
            let contents = try await fileAccess.read()
            guard loadedRevision == revision, !isSaving, !isSavingSuspended,
                canReload?() != false else { scheduleReload(); return }
            if contents == savedContents {
                if hasReadError {
                    hasReadError = false
                    errorMessage = hasExternalChange ? SaveError.externalChange.localizedDescription : nil
                    scheduleSave()
                }
                return
            }
            if hasUnsavedChanges || (contents == nil && savedContents != nil) {
                markExternalChange()
                return
            }
            revision += 1
            text = contents ?? ""
            savedText = text
            savedContents = contents
            hasReadError = false
            hasExternalChange = false
            errorMessage = nil
        } catch {
            hasReadError = true
            errorMessage = "Could not read notes: \(error.localizedDescription)"
        }
    }

    func resolveExternalChange(keepLocal: Bool) async {
        guard hasExternalChange, !isSaving, !isSavingSuspended, canReload?() != false else { return }
        do {
            let contents = try await fileAccess.read()
            guard !isSavingSuspended, canReload?() != false else { return }
            savedContents = contents
            savedText = contents ?? ""
            if !keepLocal { text = savedText; revision += 1 }
            hasExternalChange = false
            hasReadError = false
            errorMessage = nil
            if keepLocal { try await flush() }
        } catch { errorMessage = error.localizedDescription }
    }

    private func markExternalChange() {
        pendingSave?.cancel()
        hasExternalChange = true
        errorMessage = SaveError.externalChange.localizedDescription
    }

    func updateText(_ value: String) {
        guard canEdit, text != value else { return }
        text = value
        revision += 1
        scheduleSave()
    }

    func setSavingSuspended(_ value: Bool) {
        isSavingSuspended = value
        if value {
            pendingSave?.cancel()
        } else {
            scheduleSave()
        }
    }

    func flush() async throws {
        pendingSave?.cancel()
        guard !hasExternalChange else { throw SaveError.externalChange }
        if hasReadError && hasUnsavedChanges { throw SaveError.unreadableFile }
        guard canEdit, hasUnsavedChanges || isSaving else { return }
        guard !isSavingSuspended else { throw SaveError.writingToolsActive }
        activeSaveCount += 1
        defer { activeSaveCount -= 1 }
        repeat {
            guard !isSavingSuspended else { throw SaveError.writingToolsActive }
            let contents = text
            let savedRevision = revision
            do {
                let didWrite = try await fileAccess.write(
                    contents, expected: savedContents, expectedRevision: lastSavedRevision,
                    revision: savedRevision)
                if didWrite, savedRevision >= lastSavedRevision {
                    lastSavedRevision = savedRevision
                    savedText = contents
                    savedContents = contents
                    errorMessage = nil
                }
            } catch {
                if savedRevision < lastSavedRevision { continue }
                if let error = error as? SaveError, error == .externalChange { markExternalChange() }
                errorMessage = "Could not save notes: \(error.localizedDescription)"
                throw error
            }
        } while hasUnsavedChanges
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        guard canEdit, hasUnsavedChanges, !isSavingSuspended, !hasExternalChange else { return }
        pendingSave = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                try await self?.flush()
            } catch {
                // The visible error belongs to flush; a superseded timer needs no error.
            }
        }
    }

    enum SaveError: LocalizedError, Equatable {
        case writingToolsActive
        case externalChange
        case unreadableFile

        var errorDescription: String? {
            switch self {
            case .writingToolsActive: "Finish or cancel Writing Tools before closing Notes."
            case .unreadableFile: "The note cannot be read. Your unsaved text is retained; restore file access before closing."
            case .externalChange: "This note changed outside this editor. Use the file version or explicitly overwrite it with your text."
            }
        }
    }

    private actor FileAccess {
        let fileURL: URL
        private var lastWrittenRevision = -1
        private var lastWrittenContents: String?

        init(fileURL: URL) { self.fileURL = fileURL }

        func read() throws -> String? {
            do {
                return try String(contentsOf: fileURL, encoding: .utf8)
            } catch CocoaError.fileReadNoSuchFile {
                return nil
            }
        }

        func write(_ text: String, expected: String?, expectedRevision: Int, revision: Int) throws -> Bool {
            guard revision >= lastWrittenRevision else { return false }
            let current = try read()
            guard current == expected || current == text
                || (lastWrittenRevision > expectedRevision && current == lastWrittenContents)
            else { throw SaveError.externalChange }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: fileURL, options: .atomic)
            lastWrittenRevision = revision
            lastWrittenContents = text
            return true
        }
    }
}
