// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Security

struct ClaudeClient: Sendable {
  typealias TokenLoader = @Sendable () async throws -> String
  typealias Loader = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  private let token: TokenLoader
  private let load: Loader
  let cacheURL: URL?

  init(
    token: @escaping TokenLoader = ClaudeClient.accessToken,
    load: @escaping Loader = ClaudeClient.load,
    cacheURL: URL? = ClaudeClient.cacheURL()
  ) {
    self.token = token
    self.load = load
    self.cacheURL = cacheURL
  }

  func readQuota() async throws -> Quota {
    if let cacheURL, let data = try? Data(contentsOf: cacheURL),
      let cache = try? JSONDecoder().decode(CachedUsage.self, from: data),
      cache.updatedAt.isFinite
    {
      let updatedAt = Date(timeIntervalSince1970: cache.updatedAt / 1000)
      let age = Date().timeIntervalSince(updatedAt)
      if age >= 0, age < 5 * 60,
        let quota = try? Self.parseQuota(data, updatedAt: updatedAt)
      {
        return quota
      }
    }
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    request.timeoutInterval = 15
    request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await load(request)
    switch response.statusCode {
    case 200:
      return try Self.parseQuota(data)
    case 401, 403:
      throw BackendError(
        message: "Claude login expired or unavailable",
        diagnostic: "Open Claude Code and run /login, then refresh"
      )
    case 429:
      throw BackendError(
        message: "Claude usage requests are rate limited",
        diagnostic: "Wait a few minutes before refreshing"
      )
    default:
      throw BackendError(
        message: "Claude quota request failed",
        diagnostic: "The usage endpoint returned HTTP \(response.statusCode)"
      )
    }
  }

  static func parseQuota(_ data: Data, updatedAt: Date = Date()) throws -> Quota {
    let usage: Usage
    do {
      usage = try JSONDecoder().decode(Usage.self, from: data)
    } catch {
      throw BackendError(
        message: "Claude returned invalid data",
        diagnostic: "The usage response was not valid quota JSON"
      )
    }
    let fiveHour = usage.fiveHour?.window ?? usage.limits?.first { $0.kind == "session" }?.window
    let weekly = usage.sevenDay?.window ?? usage.limits?.first { $0.kind == "weekly_all" }?.window
    guard fiveHour != nil || weekly != nil else {
      throw BackendError(
        message: "Claude returned no quota limits",
        diagnostic: "Subscription usage requires a Claude Code login with a Claude plan"
      )
    }
    return Quota(fiveHour: fiveHour, weekly: weekly, updatedAt: updatedAt)
  }

  static func parseToken(_ data: Data, now: Date = Date()) throws -> String {
    guard let credentials = try? JSONDecoder().decode(Credentials.self, from: data),
      let oauth = credentials.claudeAiOauth, !oauth.accessToken.isEmpty
    else {
      throw BackendError(
        message: "Claude Code login not found",
        diagnostic: "Open Claude Code and run /login with a Claude account"
      )
    }
    if let expiresAt = oauth.expiresAt, expiresAt <= now.timeIntervalSince1970 * 1000 {
      throw BackendError(
        message: "Claude login expired",
        diagnostic: "Open Claude Code to renew the login, then refresh"
      )
    }
    return oauth.accessToken
  }

  static func keychainService(configDirectory: String?) -> String {
    guard let configDirectory, !configDirectory.isEmpty else { return "Claude Code-credentials" }
    let hash = SHA256.hash(data: Data(configDirectory.precomposedStringWithCanonicalMapping.utf8))
      .map { String(format: "%02x", $0) }.joined().prefix(8)
    return "Claude Code-credentials-\(hash)"
  }

  private static func accessToken() async throws -> String {
    try await Task.detached(priority: .userInitiated) {
      let environment = ProcessInfo.processInfo.environment
      if let token = environment["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty { return token }
      let directory =
        environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"]
        ?? environment["CLAUDE_CONFIG_DIR"]
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService(configDirectory: directory),
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecSuccess, let data = result as? Data { return try parseToken(data) }
      let root =
        directory.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
      if let data = try? Data(contentsOf: root.appendingPathComponent(".credentials.json")) {
        return try parseToken(data)
      }
      throw BackendError(
        message: "Claude Code login not found",
        diagnostic: "Log in to Claude Code and allow CuotaX to read its Keychain credentials"
      )
    }.value
  }

  private static func cacheURL() -> URL {
    let directory =
      ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
      .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    return directory.appendingPathComponent("cuotax-usage.json")
  }

  private static func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return (data, response)
  }

  private struct Credentials: Decodable {
    let claudeAiOauth: OAuth?
  }

  private struct CachedUsage: Decodable {
    let updatedAt: Double
  }

  private struct OAuth: Decodable {
    let accessToken: String
    let expiresAt: Double?
  }

  private struct Usage: Decodable {
    let fiveHour: Window?
    let sevenDay: Window?
    let limits: [Limit]?

    enum CodingKeys: String, CodingKey {
      case fiveHour = "five_hour"
      case sevenDay = "seven_day"
      case limits
    }
  }

  private struct Window: Decodable {
    let utilization: Double?
    let resetsAt: String?

    var window: QuotaWindow? {
      quotaWindow(percent: utilization, reset: resetsAt)
    }

    enum CodingKeys: String, CodingKey {
      case utilization
      case resetsAt = "resets_at"
    }
  }

  private struct Limit: Decodable {
    let kind: String
    let percent: Double?
    let resetsAt: String?

    var window: QuotaWindow? {
      quotaWindow(percent: percent, reset: resetsAt)
    }

    enum CodingKeys: String, CodingKey {
      case kind
      case percent
      case resetsAt = "resets_at"
    }
  }

  private static func quotaWindow(percent: Double?, reset: String?) -> QuotaWindow? {
    guard let percent, percent.isFinite else { return nil }
    let formatter = ISO8601DateFormatter()
    let date = reset.flatMap { value in
      formatter.date(from: value)
        ?? {
          formatter.formatOptions.insert(.withFractionalSeconds)
          return formatter.date(from: value)
        }()
    }
    return QuotaWindow(usedPercent: percent, resetsAt: date)
  }
}
