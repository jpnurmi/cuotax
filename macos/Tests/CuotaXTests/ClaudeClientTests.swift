// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import CuotaX

private let claudeUsage = Data(
  """
  {"five_hour":{"utilization":42,"resets_at":"2026-10-12T22:00:00.123Z"},"seven_day":{"utilization":7,"resets_at":"2026-10-19T22:00:00Z"}}
  """.utf8
)

@Test func readsClaudeQuota() async throws {
  let client = ClaudeClient(
    token: { "fixture-token" },
    load: { request in
      #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
      #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
      return (
        claudeUsage,
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    },
    cacheURL: nil
  )
  let quota = try await client.readQuota()
  #expect(quota.fiveHour?.usedPercent == 42)
  #expect(quota.weekly?.usedPercent == 7)
  #expect(quota.fiveHour?.resetsAt != nil)
}

@Test func readsClaudeLimitRows() throws {
  let quota = try ClaudeClient.parseQuota(
    Data(
      """
      {"limits":[{"kind":"weekly_scoped","percent":99},{"kind":"session","percent":25,"resets_at":"invalid"},{"kind":"weekly_all","percent":8}]}
      """.utf8
    ))
  #expect(quota.fiveHour?.usedPercent == 25)
  #expect(quota.fiveHour?.resetsAt == nil)
  #expect(quota.weekly?.usedPercent == 8)
  #expect(throws: BackendError.self) { try ClaudeClient.parseQuota(Data("{}".utf8)) }
  #expect(throws: BackendError.self) { try ClaudeClient.parseQuota(Data("invalid".utf8)) }
}

@Test func readsClaudeLogin() throws {
  #expect(
    try ClaudeClient.parseToken(
      Data("{\"claudeAiOauth\":{\"accessToken\":\"fixture-token\"}}".utf8)) == "fixture-token")
  #expect(throws: BackendError.self) {
    try ClaudeClient.parseToken(
      Data("{\"claudeAiOauth\":{\"accessToken\":\"expired\",\"expiresAt\":1}}".utf8))
  }
  for data in ["{}", "invalid", "{\"claudeAiOauth\":{\"accessToken\":\"\"}}"] {
    #expect(throws: BackendError.self) { try ClaudeClient.parseToken(Data(data.utf8)) }
  }
  #expect(ClaudeClient.keychainService(configDirectory: nil) == "Claude Code-credentials")
  #expect(ClaudeClient.keychainService(configDirectory: "") == "Claude Code-credentials")
  #expect(
    ClaudeClient.keychainService(configDirectory: "/tmp/claude").hasPrefix(
      "Claude Code-credentials-"))
}

@Test func prefersFreshClaudeStatusLine() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("cuotax-usage.json")
  let updatedAt = Date().addingTimeInterval(-60)
  let data = Data(
    "{\"updatedAt\":\(updatedAt.timeIntervalSince1970 * 1000),\"five_hour\":{\"utilization\":98}}"
      .utf8)
  try data.write(to: url, options: .atomic)
  let client = ClaudeClient(
    token: { throw BackendError(message: "Unexpected login read", diagnostic: "") },
    cacheURL: url
  )
  let quota = try await client.readQuota()
  #expect(quota.fiveHour?.usedPercent == 98)
  #expect(abs(quota.updatedAt.timeIntervalSince(updatedAt)) < 0.001)
}

@Test func pollsWhenClaudeStatusLineIsUnavailable() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("cuotax-usage.json")
  let client = ClaudeClient(
    token: { "fixture-token" },
    load: { request in
      (
        claudeUsage,
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    },
    cacheURL: url
  )
  #expect(try await client.readQuota().fiveHour?.usedPercent == 42)
  for data in [
    "invalid",
    "{\"updatedAt\":\(Date().addingTimeInterval(-301).timeIntervalSince1970 * 1000),\"five_hour\":{\"utilization\":98}}",
    "{\"updatedAt\":\(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000),\"five_hour\":{\"utilization\":98}}",
    "{\"updatedAt\":\(Date().timeIntervalSince1970 * 1000)}",
  ] {
    try Data(data.utf8).write(to: url, options: .atomic)
    #expect(try await client.readQuota().fiveHour?.usedPercent == 42)
  }
}

@Test func reportsClaudeRequestErrors() async throws {
  for (code, message) in [
    (401, "Claude login expired or unavailable"), (429, "Claude usage requests are rate limited"),
    (500, "Claude quota request failed"),
  ] {
    let client = ClaudeClient(
      token: { "fixture-token" },
      load: { request in
        (
          Data(),
          HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        )
      }, cacheURL: nil)
    do {
      _ = try await client.readQuota()
      Issue.record("Expected Claude request failure")
    } catch let error as BackendError {
      #expect(error.message == message)
    }
  }
}

@MainActor
@Test func providersRefreshIndependently() async throws {
  let fixture = try #require(
    Bundle.module.url(forResource: "codex", withExtension: nil, subdirectory: "Fixtures"))
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)
  let gate = QuotaGate()
  let claude = ClaudeClient(
    token: { "fixture-token" },
    load: { request in
      await gate.wait()
      return (
        Data("{\"five_hour\":{\"utilization\":98}}".utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }, cacheURL: nil)
  let codexModel = AppModel(provider: .codex, client: CodexClient(executable: fixture))
  let claudeModel = AppModel(provider: .claude, claudeClient: claude)
  defer {
    codexModel.stop()
    claudeModel.stop()
  }
  codexModel.refresh()
  claudeModel.refresh()
  for _ in 0..<200 where codexModel.isLoading { try await Task.sleep(nanoseconds: 10_000_000) }
  #expect(codexModel.quota?.fiveHour?.usedPercent == 42)
  #expect(claudeModel.isLoading)
  #expect(claudeModel.quota == nil)
  await gate.release()
  for _ in 0..<200 where claudeModel.isLoading { try await Task.sleep(nanoseconds: 10_000_000) }
  #expect(claudeModel.quota?.fiveHour?.usedPercent == 98)
  #expect(codexModel.quota?.fiveHour?.usedPercent == 42)
}

@MainActor
@Test func watchesAtomicStatusLineUpdates() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("cuotax-usage.json")
  var changes = 0
  let watcher = try #require(ClaudeUsageWatcher(url: url) { changes += 1 })
  defer { watcher.cancel() }
  for value in [42, 43] {
    try Data("\(value)".utf8).write(to: url, options: .atomic)
    for _ in 0..<100 where changes < value - 41 { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(changes == value - 41)
  }
}

@MainActor
@Test func loadsEnabledProviders() throws {
  let name = "CuotaXTests-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  #expect(Provider.load(from: defaults) == [.codex])
  defaults.set("claude", forKey: "provider")
  #expect(Provider.load(from: defaults) == [.claude])
  defaults.set(["codex", "claude"], forKey: "providers")
  #expect(Provider.load(from: defaults) == [.codex, .claude])
  defaults.set(["codex", "unknown"], forKey: "providers")
  #expect(Provider.load(from: defaults) == [.codex])
  defaults.set([], forKey: "providers")
  #expect(Provider.load(from: defaults) == [.claude])
}

@MainActor
@Test func providerFailureDoesNotAffectOtherQuota() async throws {
  let failed = AppModel(provider: .codex, client: CodexClient(executable: nil))
  let working = AppModel(
    provider: .claude,
    claudeClient: ClaudeClient(
      token: { "fixture-token" },
      load: { request in
        (
          claudeUsage,
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      }, cacheURL: nil))
  defer {
    failed.stop()
    working.stop()
  }
  failed.refresh()
  working.refresh()
  for _ in 0..<200 where failed.isLoading || working.isLoading {
    try await Task.sleep(nanoseconds: 10_000_000)
  }
  #expect(failed.error?.message == "Codex CLI not found")
  #expect(working.quota?.fiveHour?.usedPercent == 42)
  #expect(working.error == nil)
}

@MainActor
@Test func stoppedProviderIgnoresPendingQuota() async throws {
  let gate = QuotaGate()
  let model = AppModel(
    provider: .claude,
    claudeClient: ClaudeClient(
      token: { "fixture-token" },
      load: { request in
        await gate.wait()
        return (
          claudeUsage,
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      }, cacheURL: nil))
  model.refresh()
  try await Task.sleep(nanoseconds: 20_000_000)
  model.stop()
  model.refresh()
  await gate.release()
  for _ in 0..<200 where model.isLoading { try await Task.sleep(nanoseconds: 10_000_000) }
  #expect(model.quota == nil)
  #expect(model.error == nil)
}

@Test func readsFableQuota() throws {
  let quota = try ClaudeClient.parseQuota(
    Data(
      """
      {"five_hour":{"utilization":20},"seven_day":{"utilization":5},"limits":[{"kind":"weekly_scoped","percent":99,"scope":null},{"kind":"weekly_scoped","percent":80,"scope":{"model":{"display_name":"Sonnet"}}},{"kind":"weekly_scoped","percent":10,"resets_at":"2026-10-20T12:59:59.629512+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]}
      """.utf8
    ))
  #expect(quota.weekly?.usedPercent == 5)
  #expect(quota.fable?.usedPercent == 10)
  #expect(quota.fable?.resetsAt != nil)

  let only = try ClaudeClient.parseQuota(
    Data(
      """
      {"limits":[{"kind":"weekly_scoped","percent":95,"scope":{"model":{"display_name":"Fable"}}}]}
      """.utf8
    ))
  #expect(only.fiveHour == nil)
  #expect(only.weekly == nil)
  #expect(only.fable?.usedPercent == 95)
  #expect(only.fable?.resetsAt == nil)
  #expect(try ClaudeClient.parseQuota(claudeUsage).fable == nil)
}

private actor QuotaGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false

  func wait() async {
    if released { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
