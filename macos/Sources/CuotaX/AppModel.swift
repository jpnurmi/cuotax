// SPDX-License-Identifier: MIT

import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
  let provider: Provider
  @Published private(set) var quota: Quota?
  @Published private(set) var error: BackendError?
  @Published private(set) var isLoading = true

  private let client: CodexClient
  private let claudeClient: ClaudeClient
  private var refreshTask: Task<Void, Never>?
  private var refreshLoop: Task<Void, Never>?
  private var resetRefreshTask: Task<Void, Never>?
  private var queued = false
  private var active = true
  private var usageWatcher: ClaudeUsageWatcher?

  init(
    provider: Provider = .codex,
    client: CodexClient = CodexClient(),
    claudeClient: ClaudeClient = ClaudeClient()
  ) {
    self.provider = provider
    self.client = client
    self.claudeClient = claudeClient
  }

  deinit {
    refreshTask?.cancel()
    refreshLoop?.cancel()
    resetRefreshTask?.cancel()
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
        paceProgress: nil,
        remainingPercent: nil,
        window: nil
      )
  }

  func start() {
    guard active, refreshLoop == nil else { return }
    watchClaudeUsage()
    refresh()
    refreshLoop = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
        } catch {
          return
        }
        guard let self, self.refreshTask == nil else { continue }
        if self.provider == .claude { self.refreshIfStale() } else { self.refresh() }
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
  }

  func stop() {
    active = false
    refreshTask?.cancel()
    refreshLoop?.cancel()
    resetRefreshTask?.cancel()
    usageWatcher?.cancel()
    queued = false
  }

  private func watchClaudeUsage() {
    guard provider == .claude, usageWatcher == nil, let url = claudeClient.cacheURL else { return }
    usageWatcher = ClaudeUsageWatcher(url: url) { [weak self] in self?.refresh() }
  }

  func refresh() {
    guard active else { return }
    watchClaudeUsage()
    guard refreshTask == nil else {
      queued = true
      return
    }

    if quota == nil { isLoading = true }
    let provider = provider
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
        let quota = try await provider == .codex ? client.readQuota() : claudeClient.readQuota()
        guard !Task.isCancelled else { return }
        self.quota = quota
        self.error = nil
        self.scheduleResetRefresh(for: quota)
      } catch let error as BackendError {
        guard !Task.isCancelled else { return }
        self.error = error
      } catch {
        guard !Task.isCancelled else { return }
        self.error = BackendError(
          message: "\(provider.title) quota request failed",
          diagnostic: error.localizedDescription
        )
      }
    }
  }

  private func scheduleResetRefresh(for quota: Quota) {
    resetRefreshTask?.cancel()
    let expiry = provider == .claude ? quota.updatedAt.addingTimeInterval(5 * 60) : nil
    guard let reset = [quota.nextReset(), expiry].compactMap(\.self).min() else {
      resetRefreshTask = nil
      return
    }
    let delay = reset.timeIntervalSinceNow
    resetRefreshTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
      } catch {
        return
      }
      guard let self else { return }
      self.resetRefreshTask = nil
      if self.refreshTask == nil { self.refresh() }
    }
  }
}
