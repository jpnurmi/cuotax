// SPDX-License-Identifier: MIT

import Darwin
import Foundation

@MainActor
final class ClaudeUsageWatcher {
  private var source: (any DispatchSourceFileSystemObject)?
  private var modifiedAt: Date?

  init?(url: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
    let descriptor = open(url.deletingLastPathComponent().path, O_EVTONLY)
    guard descriptor >= 0 else { return nil }
    modifiedAt = Self.modificationDate(url)
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
    )
    source.setEventHandler { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        let date = Self.modificationDate(url)
        guard date != self.modifiedAt else { return }
        self.modifiedAt = date
        if date != nil { onChange() }
      }
    }
    source.setCancelHandler { close(descriptor) }
    self.source = source
    source.resume()
  }

  deinit {
    source?.cancel()
  }

  func cancel() {
    source?.cancel()
    source = nil
  }

  private static func modificationDate(_ url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }
}
