// SPDX-License-Identifier: MIT

import Foundation
import Security
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
  let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
  let client = ClaudeClient(
    token: { throw BackendError(message: "Unexpected login read", diagnostic: "") },
    cacheURL: url
  )
  for data in [
    "{\"updatedAt\":\(updatedAt.timeIntervalSince1970 * 1000),\"five_hour\":{\"utilization\":98}}",
    """
    {"updatedAt":\(updatedAt.timeIntervalSince1970 * 1000),"five_hour":{"utilization":98,"resets_at":"\(future)"},"seven_day":{"utilization":7,"resets_at":"\(future)"},"limits":[{"kind":"weekly_scoped","percent":10,"resets_at":"\(future)","scope":{"model":{"display_name":"Fable"}}}]}
    """,
  ] {
    try Data(data.utf8).write(to: url, options: .atomic)
    let quota = try await client.readQuota()
    #expect(quota.fiveHour?.usedPercent == 98)
    #expect(abs(quota.updatedAt.timeIntervalSince(updatedAt)) < 0.001)
  }
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
  let updatedAt = Date().timeIntervalSince1970 * 1000
  let reset = ISO8601DateFormatter().string(from: Date())
  for data in [
    "invalid",
    "{\"updatedAt\":\(Date().addingTimeInterval(-301).timeIntervalSince1970 * 1000),\"five_hour\":{\"utilization\":98}}",
    "{\"updatedAt\":\(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000),\"five_hour\":{\"utilization\":98}}",
    "{\"updatedAt\":\(Date().timeIntervalSince1970 * 1000)}",
    "{\"updatedAt\":\(updatedAt),\"five_hour\":{\"utilization\":98,\"resets_at\":\"\(reset)\"}}",
    "{\"updatedAt\":\(updatedAt),\"five_hour\":{\"utilization\":98},\"seven_day\":{\"utilization\":7,\"resets_at\":\"\(reset)\"}}",
    """
    {"updatedAt":\(updatedAt),"five_hour":{"utilization":98},"limits":[{"kind":"weekly_scoped","percent":10,"resets_at":"\(reset)","scope":{"model":{"display_name":"Fable"}}}]}
    """,
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

@Test func renewsClaudeLogin() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent(".credentials.json")
  try claudeCredentials.write(to: url)
  let loader = ClaudeRenewalLoader(directory: directory)
  let client = ClaudeClient(
    load: { try await loader.load($0) }, cacheURL: nil, credentialsDirectory: directory)
  #expect(try await client.readQuota().fiveHour?.usedPercent == 42)
  #expect(await loader.postCount == 1)
  var saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
  var oauth = saved["claudeAiOauth"] as! [String: Any]
  #expect(oauth["accessToken"] as? String == "renewed-1")
  #expect(oauth["refreshToken"] as? String == "rotated")
  #expect(oauth["subscriptionType"] as? String == "max")
  #expect((oauth["expiresAt"] as! Double) > Date().timeIntervalSince1970 * 1000)
  #expect((saved["other"] as! [String: Bool])["preserved"] == true)
  #expect((saved["other"] as! [String: Bool])["changed"] == true)
  #expect(try await client.readQuota().fiveHour?.usedPercent == 42)
  #expect(await loader.postCount == 1)
  await loader.rejectUsage()
  #expect(try await client.readQuota().fiveHour?.usedPercent == 42)
  #expect(await loader.postCount == 2)
  await loader.rejectUsage(switchLogin: true)
  #expect(try await client.readQuota().fiveHour?.usedPercent == 42)
  saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
  oauth = saved["claudeAiOauth"] as! [String: Any]
  #expect(oauth["refreshToken"] as? String == "another-refresh")
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: directory.path) == [".credentials.json"])
}

@Test func preservesKeychainLoginWhenRenewing() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: ClaudeClient.keychainService(configDirectory: directory.path),
    kSecAttrAccount as String: "CuotaXTest",
  ]
  var item = query
  item[kSecValueData as String] = claudeCredentials
  #expect(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
  defer { _ = SecItemDelete(query as CFDictionary) }
  let loader = ClaudeRenewalLoader()
  let client = ClaudeClient(
    load: { try await loader.load($0) }, cacheURL: nil, credentialsDirectory: directory)
  #expect(try await client.readQuota().fiveHour?.usedPercent == 42)
  var read = query
  read[kSecReturnData as String] = true
  var result: CFTypeRef?
  #expect(SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess)
  let data = try #require(result as? Data)
  let saved = try JSONSerialization.jsonObject(with: data) as! [String: Any]
  let oauth = saved["claudeAiOauth"] as! [String: Any]
  #expect(oauth["refreshToken"] as? String == "rotated")
  #expect((saved["other"] as! [String: Bool])["preserved"] == true)
  #expect(
    !FileManager.default.fileExists(
      atPath: directory.appendingPathComponent(".credentials.json").path))
}

@Test func reportsClaudeRenewalErrors() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent(".credentials.json")
  for (status, data) in [
    (400, "{\"error\":\"invalid_grant\"}"), (503, "unavailable"), (200, "null"),
    (200, "{\"access_token\":\"new\",\"expires_in\":0}"),
    (200, "{\"access_token\":\"new\",\"expires_in\":true}"),
    (200, "{\"access_token\":\"new\",\"expires_in\":3600,\"refresh_token\":null}"),
  ] {
    try claudeCredentials.write(to: url)
    let loader = ClaudeRenewalLoader(tokenStatus: status, tokenResponse: data)
    let client = ClaudeClient(
      load: { try await loader.load($0) }, cacheURL: nil, credentialsDirectory: directory)
    do {
      _ = try await client.readQuota()
      Issue.record("Expected renewal failure")
    } catch let error as BackendError {
      #expect(
        error.message
          == (status == 400 ? "Claude login expired or unavailable" : "Claude login renewal failed")
      )
    }
    #expect(try Data(contentsOf: url) == claudeCredentials)
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(".oauth_refresh.lock").path))
  }
  var credentials = try JSONSerialization.jsonObject(with: claudeCredentials) as! [String: Any]
  var oauth = credentials["claudeAiOauth"] as! [String: Any]
  oauth["expiresAt"] = Date().timeIntervalSince1970 * 1000 + 3600_000
  credentials["claudeAiOauth"] = oauth
  try JSONSerialization.data(withJSONObject: credentials).write(to: url)
  let loader = ClaudeRenewalLoader(usageStatus: 401)
  let client = ClaudeClient(
    load: { try await loader.load($0) }, cacheURL: nil, credentialsDirectory: directory)
  do {
    _ = try await client.readQuota()
    Issue.record("Expected rejected login")
  } catch let error as BackendError {
    #expect(error.message == "Claude login expired or unavailable")
  }
  #expect(await loader.postCount == 1)
  #expect(await loader.getCount == 2)
}

@Test func concurrentClaudeRenewalRunsOnce() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent(".credentials.json")
  try claudeCredentials.write(to: url)
  let loader = ClaudeRenewalLoader()
  let client = ClaudeClient(
    load: { try await loader.load($0) }, cacheURL: nil, credentialsDirectory: directory)
  async let first = client.readQuota()
  async let second = client.readQuota()
  let quotas = try await (first, second)
  #expect(quotas.0.fiveHour?.usedPercent == 42)
  #expect(quotas.1.fiveHour?.usedPercent == 42)
  #expect(await loader.postCount == 1)
  var saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
  var oauth = saved["claudeAiOauth"] as! [String: Any]
  oauth["expiresAt"] = 1
  saved["claudeAiOauth"] = oauth
  try JSONSerialization.data(withJSONObject: saved).write(to: url)
  let lock = directory.appendingPathComponent(".oauth_refresh.lock")
  try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
  try FileManager.default.setAttributes(
    [.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: lock.path)
  #expect(try await client.readQuota().fiveHour?.usedPercent == 42)
  #expect(!FileManager.default.fileExists(atPath: lock.path))
}

private let claudeCredentials = Data(
  """
  {"other":{"preserved":true},"claudeAiOauth":{"accessToken":"old","refreshToken":"refresh","expiresAt":1,"scopes":["user:profile","user:inference"],"clientId":"fixture-client","subscriptionType":"max"}}
  """.utf8
)

private actor ClaudeRenewalLoader {
  let directory: URL?
  let tokenStatus: Int
  let tokenResponse: String?
  let usageStatus: Int
  var postCount = 0
  var getCount = 0
  private var rejected = false
  private var switched = false

  init(
    directory: URL? = nil, tokenStatus: Int = 200, tokenResponse: String? = nil,
    usageStatus: Int = 200
  ) {
    self.directory = directory
    self.tokenStatus = tokenStatus
    self.tokenResponse = tokenResponse
    self.usageStatus = usageStatus
  }

  func rejectUsage(switchLogin: Bool = false) {
    rejected = true
    switched = switchLogin
  }

  func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    if request.httpMethod == "POST" {
      postCount += 1
      #expect(request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token")
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
      let body =
        try JSONSerialization.jsonObject(with: #require(request.httpBody)) as! [String: Any]
      #expect(body["grant_type"] as? String == "refresh_token")
      #expect(body["refresh_token"] as? String == (postCount == 1 ? "refresh" : "rotated"))
      #expect(body["client_id"] as? String == "fixture-client")
      #expect(body["scope"] as? String == "user:profile user:inference")
      try await Task.sleep(nanoseconds: 100_000_000)
      if let directory {
        let url = directory.appendingPathComponent(".credentials.json")
        var credentials =
          try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var other = credentials["other"] as! [String: Bool]
        other["changed"] = true
        credentials["other"] = other
        if switched {
          var oauth = credentials["claudeAiOauth"] as! [String: Any]
          oauth["accessToken"] = "another-login"
          oauth["refreshToken"] = "another-refresh"
          credentials["claudeAiOauth"] = oauth
        }
        try JSONSerialization.data(withJSONObject: credentials).write(to: url, options: .atomic)
      }
      let data =
        tokenResponse
        ?? "{\"access_token\":\"renewed-\(postCount)\",\"refresh_token\":\"rotated\",\"expires_in\":3600}"
      return (
        Data(data.utf8),
        HTTPURLResponse(
          url: request.url!, statusCode: tokenStatus, httpVersion: nil, headerFields: nil)!
      )
    }
    getCount += 1
    if rejected {
      rejected = false
      return (
        Data(),
        HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
      )
    }
    if usageStatus == 200 {
      #expect(
        request.value(forHTTPHeaderField: "Authorization")
          == "Bearer \(switched ? "another-login" : "renewed-\(postCount)")")
    }
    return (
      claudeUsage,
      HTTPURLResponse(
        url: request.url!, statusCode: usageStatus, httpVersion: nil, headerFields: nil)!
    )
  }
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

@Test func claudeCacheFollowsCredentialSelection() {
  let directory = URL(fileURLWithPath: "/tmp/claude-config")
  let secure = URL(fileURLWithPath: "/tmp/claude-secure")
  let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
  for (environment, expected) in [
    ([:], home),
    (["CLAUDE_CONFIG_DIR": ""], home),
    (["CLAUDE_CONFIG_DIR": directory.path], directory),
    (["CLAUDE_SECURESTORAGE_CONFIG_DIR": secure.path], secure),
    (
      ["CLAUDE_CONFIG_DIR": directory.path, "CLAUDE_SECURESTORAGE_CONFIG_DIR": secure.path],
      secure
    ),
    (["CLAUDE_CONFIG_DIR": directory.path, "CLAUDE_SECURESTORAGE_CONFIG_DIR": ""], home),
  ] {
    #expect(
      ClaudeClient.cacheURL(environment: environment)
        == expected.appendingPathComponent("cuotax-usage.json"))
  }
  #expect(
    ClaudeClient.cacheURL(
      directory: directory, environment: ["CLAUDE_SECURESTORAGE_CONFIG_DIR": secure.path])
      == directory.appendingPathComponent("cuotax-usage.json"))
}

@Test func claudeStatusLineCachesStayWithCredentialStores() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let first = directory.appendingPathComponent("first")
  let second = directory.appendingPathComponent("second")
  for root in [first, second] {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  let load: ClaudeClient.Loader = { request in
    (
      claudeUsage,
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
  }
  let firstClient = ClaudeClient(token: { "fixture-token" }, load: load, credentialsDirectory: first)
  let secondClient = ClaudeClient(token: { "fixture-token" }, load: load, credentialsDirectory: second)
  let firstURL = first.appendingPathComponent("cuotax-usage.json")
  let secondURL = second.appendingPathComponent("cuotax-usage.json")
  let updatedAt = Date().timeIntervalSince1970 * 1000
  try Data("{\"updatedAt\":\(updatedAt),\"five_hour\":{\"utilization\":98}}".utf8).write(to: firstURL)
  #expect(firstClient.cacheURL == firstURL)
  #expect(secondClient.cacheURL == secondURL)
  #expect(try await firstClient.readQuota().fiveHour?.usedPercent == 98)
  #expect(try await secondClient.readQuota().fiveHour?.usedPercent == 42)
  try Data("{\"updatedAt\":\(updatedAt),\"five_hour\":{\"utilization\":7}}".utf8).write(to: secondURL)
  #expect(try await firstClient.readQuota().fiveHour?.usedPercent == 98)
  #expect(try await secondClient.readQuota().fiveHour?.usedPercent == 7)
  #expect(ClaudeClient(cacheURL: nil, credentialsDirectory: first).cacheURL == nil)
}
