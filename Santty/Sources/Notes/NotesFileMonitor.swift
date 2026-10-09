import Foundation
import Darwin

@MainActor
final class NotesFileMonitor {
  private let url: URL
  private let onChange: () -> Void
  nonisolated(unsafe) private var sources: [DispatchSourceFileSystemObject] = []
  private var pendingChange: Task<Void, Never>?

  init(url: URL, onChange: @escaping () -> Void) {
    self.url = url
    self.onChange = onChange
    watch()
  }

  deinit { sources.forEach { $0.cancel() } }

  private func watch() {
    sources.forEach { $0.cancel() }
    sources = []
    var directory = url.deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" {
      directory.deleteLastPathComponent()
    }
    // Watch both: directory events catch atomic replacement; file events catch in-place edits.
    for path in Set([directory.path, url.path]) {
      let descriptor = open(path, O_EVTONLY)
      guard descriptor >= 0 else { continue }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
        queue: .main)
      source.setCancelHandler { close(descriptor) }
      source.setEventHandler { [weak self] in
        MainActor.assumeIsolated { self?.scheduleChange() }
      }
      sources.append(source)
      source.resume()
    }
  }

  private func scheduleChange() {
    pendingChange?.cancel()
    pendingChange = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
      guard let self else { return }
      watch()
      onChange()
    }
  }
}
