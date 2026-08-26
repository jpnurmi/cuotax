// SPDX-License-Identifier: MIT

import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var quota: Quota?
  @Published private(set) var error: BackendError?
  @Published private(set) var isLoading = true

  private let client: CodexClient
  private var refreshTask: Task<Void, Never>?
  private var refreshLoop: Task<Void, Never>?
  private var queued = false

  init(client: CodexClient = CodexClient()) {
    self.client = client
  }

  deinit {
    refreshTask?.cancel()
    refreshLoop?.cancel()
  }

  var title: String {
    guard let percent = quota?.highestPercent else { return error == nil ? "…" : "!" }
    return "\(Int(displayPercent(percent).rounded()))%"
  }

  var status: QuotaStatus {
    quota?.status()
      ?? QuotaStatus(
        coverage: nil,
        level: .unavailable,
        onTrackPercent: nil,
        remainingPercent: nil,
        window: nil
      )
  }

  func start() {
    guard refreshLoop == nil else { return }
    refresh()
    refreshLoop = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
        } catch {
          return
        }
        self?.refresh()
      }
    }
  }

  func refreshIfStale() {
    if quota == nil || Date().timeIntervalSince(quota!.updatedAt) >= 60 {
      refresh()
    }
  }

  func refresh() {
    guard refreshTask == nil else {
      queued = true
      return
    }

    if quota == nil { isLoading = true }
    refreshTask = Task { [weak self] in
      guard let self else { return }
      do {
        let quota = try await client.readQuota()
        guard !Task.isCancelled else { return }
        self.quota = quota
        self.error = nil
      } catch let error as BackendError {
        guard !Task.isCancelled else { return }
        self.error = error
      } catch {
        guard !Task.isCancelled else { return }
        self.error = BackendError(
          message: "Codex quota request failed",
          diagnostic: error.localizedDescription
        )
      }
      self.isLoading = false
      self.refreshTask = nil
      if self.queued {
        self.queued = false
        self.refresh()
      }
    }
  }
}
