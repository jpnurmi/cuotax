// SPDX-License-Identifier: MIT

import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var quota: Quota?
  @Published private(set) var error: BackendError?
  @Published private(set) var isLoading = true
  @Published private(set) var updateAvailable = false

  private let client: CodexClient
  private let updateChecker: UpdateChecker
  private var refreshTask: Task<Void, Never>?
  private var updateTask: Task<Void, Never>?
  private var refreshLoop: Task<Void, Never>?
  private var updateLoop: Task<Void, Never>?
  private var queued = false

  init(client: CodexClient = CodexClient(), updateChecker: UpdateChecker = UpdateChecker()) {
    self.client = client
    self.updateChecker = updateChecker
  }

  deinit {
    refreshTask?.cancel()
    updateTask?.cancel()
    refreshLoop?.cancel()
    updateLoop?.cancel()
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
    checkForUpdates()
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
    updateLoop = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: 24 * 60 * 60 * 1_000_000_000)
        } catch {
          return
        }
        self?.checkForUpdates()
      }
    }
  }

  func refreshIfStale() {
    if quota == nil || Date().timeIntervalSince(quota!.updatedAt) >= 60 {
      refresh()
    }
  }

  func refreshAfterWake() {
    refresh()
    checkForUpdates()
  }

  func refresh() {
    guard refreshTask == nil else {
      queued = true
      return
    }

    if quota == nil { isLoading = true }
    refreshTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.isLoading = false
        self.refreshTask = nil
        if self.queued {
          self.queued = false
          self.refresh()
        }
      }

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
    }
  }

  private func checkForUpdates() {
    guard updateTask == nil else { return }
    updateTask = Task { [weak self, updateChecker] in
      let available = await updateChecker.isUpdateAvailable()
      guard !Task.isCancelled else { return }
      if available { self?.updateAvailable = true }
      self?.updateTask = nil
    }
  }
}
