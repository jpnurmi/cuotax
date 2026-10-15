// SPDX-License-Identifier: MIT

import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Security

struct ClaudeClient: Sendable {
  typealias TokenLoader = @Sendable () async throws -> String
  typealias Loader = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  private let token: TokenLoader?
  private let load: Loader
  private let directory: URL?
  let cacheURL: URL?

  init(
    token: TokenLoader? = nil,
    load: @escaping Loader = ClaudeClient.load,
    cacheURL: URL?,
    credentialsDirectory: URL? = nil
  ) {
    self.token = token
    self.load = load
    self.cacheURL = cacheURL
    self.directory = credentialsDirectory
  }

  init(
    token: TokenLoader? = nil,
    load: @escaping Loader = ClaudeClient.load,
    credentialsDirectory: URL? = nil
  ) {
    self.init(
      token: token, load: load, cacheURL: Self.cacheURL(directory: credentialsDirectory),
      credentialsDirectory: credentialsDirectory)
  }

  func readQuota() async throws -> Quota {
    if let cacheURL, let data = try? Data(contentsOf: cacheURL),
      let cache = try? JSONDecoder().decode(CachedUsage.self, from: data),
      cache.updatedAt.isFinite
    {
      let updatedAt = Date(timeIntervalSince1970: cache.updatedAt / 1000)
      let now = Date()
      let age = now.timeIntervalSince(updatedAt)
      if age >= 0, age < 5 * 60,
        let quota = try? Self.parseQuota(data, updatedAt: updatedAt),
        [quota.fiveHour?.resetsAt, quota.weekly?.resetsAt, quota.fable?.resetsAt]
          .compactMap(\.self).allSatisfy({ $0 > now })
      {
        return quota
      }
    }
    var accessToken = try await self.accessToken()
    for attempt in 0..<2 {
      var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
      request.timeoutInterval = 15
      request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
      request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      let (data, response) = try await load(request)
      if response.statusCode == 401 && attempt == 0 {
        let renewed = try await self.accessToken(rejected: accessToken)
        if renewed != accessToken {
          accessToken = renewed
          continue
        }
      }
      switch response.statusCode {
      case 200:
        return try Self.parseQuota(data)
      case 401, 403:
        throw Self.expiredLogin()
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
    throw Self.expiredLogin()
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
    let fable = usage.limits?.first {
      $0.kind == "weekly_scoped" && $0.scope?.model?.displayName == "Fable"
    }?.window
    guard fiveHour != nil || weekly != nil || fable != nil else {
      throw BackendError(
        message: "Claude returned no quota limits",
        diagnostic: "Subscription usage requires a Claude Code login with a Claude plan"
      )
    }
    return Quota(fiveHour: fiveHour, weekly: weekly, updatedAt: updatedAt, fable: fable)
  }

  static func parseToken(_ data: Data, now: Date = Date()) throws -> String {
    let oauth = try parseCredentials(data)["claudeAiOauth"] as! [String: Any]
    if let expiresAt = number(oauth["expiresAt"]), expiresAt <= now.timeIntervalSince1970 * 1000 {
      throw expiredLogin()
    }
    return oauth["accessToken"] as! String
  }

  static func keychainService(configDirectory: String?) -> String {
    guard let configDirectory, !configDirectory.isEmpty else { return "Claude Code-credentials" }
    let hash = SHA256.hash(data: Data(configDirectory.precomposedStringWithCanonicalMapping.utf8))
      .map { String(format: "%02x", $0) }.joined().prefix(8)
    return "Claude Code-credentials-\(hash)"
  }

  private func accessToken(rejected: String? = nil) async throws -> String {
    if let token { return try await token() }
    let load = self.load
    let directory = self.directory
    let task = Task.detached(priority: .userInitiated) {
      try await Self.loadToken(rejected: rejected, load: load, directory: directory)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private static func expiredLogin() -> BackendError {
    BackendError(
      message: "Claude login expired or unavailable",
      diagnostic: "The saved login could not be renewed; run /login in Claude Code")
  }

  private static func renewalFailed(_ diagnostic: String) -> BackendError {
    BackendError(message: "Claude login renewal failed", diagnostic: diagnostic)
  }

  private static func parseCredentials(_ data: Data) throws -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: data),
      let credentials = object as? [String: Any],
      let oauth = credentials["claudeAiOauth"] as? [String: Any],
      let token = oauth["accessToken"] as? String, !token.isEmpty
    else {
      throw BackendError(
        message: "Claude Code login not found",
        diagnostic: "Open Claude Code and run /login with a Claude account")
    }
    return credentials
  }

  private static func needsRefresh(_ oauth: [String: Any], rejected: String?) -> Bool {
    if oauth["accessToken"] as? String == rejected { return true }
    guard let expiresAt = number(oauth["expiresAt"]) else { return false }
    return expiresAt <= Date().timeIntervalSince1970 * 1000 + 60_000
  }

  private static func number(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite
    else { return nil }
    return number.doubleValue
  }

  private enum Storage: Sendable {
    case file(URL)
    case keychain(Data)

    func read() throws -> Data {
      switch self {
      case .file(let url):
        return try Data(contentsOf: url)
      case .keychain(let reference):
        let query: [String: Any] = [
          kSecValuePersistentRef as String: reference,
          kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data
        else { throw ClaudeClient.renewalFailed("Could not read the saved Keychain credentials") }
        return data
      }
    }

    func write(_ data: Data, replacing previous: Data) throws -> Bool {
      switch self {
      case .file(let url):
        let temporary = url.appendingPathExtension("\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let descriptor = temporary.path.withCString {
          Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        }
        guard descriptor >= 0 else {
          throw ClaudeClient.renewalFailed("Could not save the renewed credentials")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        guard try read() == previous else { return false }
        let status = temporary.path.withCString { source in
          url.path.withCString { Darwin.rename(source, $0) }
        }
        guard status == 0 else {
          throw ClaudeClient.renewalFailed("Could not save the renewed credentials")
        }
      case .keychain(let reference):
        guard try read() == previous else { return false }
        let query: [String: Any] = [kSecValuePersistentRef as String: reference]
        let changes: [String: Any] = [kSecValueData as String: data]
        guard SecItemUpdate(query as CFDictionary, changes as CFDictionary) == errSecSuccess else {
          throw ClaudeClient.renewalFailed("Could not save the renewed Keychain credentials")
        }
      }
      return true
    }
  }

  private static func readCredentials(directory: URL?, configDirectory: String?) throws -> (
    Data, Storage
  ) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService(configDirectory: configDirectory),
      kSecReturnData as String: true,
      kSecReturnPersistentRef as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let item = result as? [String: Any],
      let data = item[kSecValueData as String] as? Data,
      let reference = item[kSecValuePersistentRef as String] as? Data
    {
      return (data, .keychain(reference))
    }
    let root =
      directory
      ?? configDirectory.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    let url = root.appendingPathComponent(".credentials.json")
    if let data = try? Data(contentsOf: url) { return (data, .file(url)) }
    throw BackendError(
      message: "Claude Code login not found",
      diagnostic: "Log in to Claude Code and allow CuotaX to read its Keychain credentials")
  }

  private static func lockRefresh(_ root: URL) async throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let lock = root.appendingPathComponent(".oauth_refresh.lock")
    // share Claude Code's refresh lock to avoid rotating the same token twice
    for _ in 0..<5 {
      try Task.checkCancellation()
      if lock.path.withCString({ Darwin.mkdir($0, 0o700) }) == 0 { return lock }
      guard errno == EEXIST else {
        throw renewalFailed("Could not lock the credentials for renewal")
      }
      if let attributes = try? FileManager.default.attributesOfItem(atPath: lock.path),
        let modified = attributes[.modificationDate] as? Date,
        Date().timeIntervalSince(modified) >= 60
      {
        try? FileManager.default.removeItem(at: lock)
        continue
      }
      try await Task.sleep(nanoseconds: 1_000_000_000)
    }
    throw BackendError(
      message: "Claude login renewal busy", diagnostic: "Another process is renewing the login")
  }

  private static func loadToken(rejected: String?, load: Loader, directory: URL?) async throws
    -> String
  {
    let environment = ProcessInfo.processInfo.environment
    if let token = environment["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty { return token }
    let configDirectory = Self.configDirectory(directory: directory, environment: environment)
    let (data, storage) = try readCredentials(
      directory: directory, configDirectory: configDirectory)
    var oauth = try parseCredentials(data)["claudeAiOauth"] as! [String: Any]
    guard needsRefresh(oauth, rejected: rejected),
      let refreshToken = oauth["refreshToken"] as? String,
      !refreshToken.isEmpty
    else { return try parseToken(data) }
    let root =
      directory
      ?? configDirectory.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    let lock = try await lockRefresh(root)
    defer { try? FileManager.default.removeItem(at: lock) }
    let current = try storage.read()
    oauth = try parseCredentials(current)["claudeAiOauth"] as! [String: Any]
    guard needsRefresh(oauth, rejected: rejected) else { return oauth["accessToken"] as! String }
    guard let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty else {
      throw expiredLogin()
    }
    var body: [String: Any] = [
      "grant_type": "refresh_token",
      "refresh_token": refreshToken,
      "client_id": oauth["clientId"] as? String ?? environment["CLAUDE_CODE_OAUTH_CLIENT_ID"]
        ?? "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
    ]
    if let scopes = oauth["scopes"] as? [String], !scopes.isEmpty {
      body["scope"] = scopes.joined(separator: " ")
    }
    var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let result: Data
    let response: HTTPURLResponse
    do {
      (result, response) = try await load(request)
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw renewalFailed("Could not renew the saved login; CuotaX will retry automatically")
    }
    let values = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any]
    if response.statusCode == 401 || values?["error"] as? String == "invalid_grant" {
      throw expiredLogin()
    }
    guard response.statusCode == 200 else {
      throw renewalFailed("The token endpoint returned HTTP \(response.statusCode)")
    }
    guard let values, let accessToken = values["access_token"] as? String, !accessToken.isEmpty,
      let expiresIn = number(values["expires_in"]), expiresIn > 0,
      values["refresh_token"] == nil
        || (values["refresh_token"] as? String).map({ !$0.isEmpty }) == true
    else { throw renewalFailed("The token response was invalid") }
    var renewed: [String: Any] = [
      "accessToken": accessToken,
      "refreshToken": values["refresh_token"] as? String ?? refreshToken,
      "expiresAt": Date().timeIntervalSince1970 * 1000 + expiresIn * 1000,
    ]
    if let scope = values["scope"] as? String {
      renewed["scopes"] = scope.split(separator: " ").map(String.init)
    }
    if let expiresIn = number(values["refresh_token_expires_in"]), expiresIn > 0 {
      renewed["refreshTokenExpiresAt"] = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000
    }
    do {
      // finish saving rotated credentials even if the backend was disabled
      for _ in 0..<3 {
        let data = try storage.read()
        var credentials = try parseCredentials(data)
        var current = credentials["claudeAiOauth"] as! [String: Any]
        if current["accessToken"] as? String != oauth["accessToken"] as? String
          || current["refreshToken"] as? String != refreshToken
        {
          return try parseToken(data)
        }
        current.merge(renewed) { _, new in new }
        credentials["claudeAiOauth"] = current
        if try storage.write(JSONSerialization.data(withJSONObject: credentials), replacing: data) {
          return accessToken
        }
      }
    } catch {
      throw renewalFailed("Could not save the renewed credentials")
    }
    throw renewalFailed("Could not save the renewed credentials")
  }

  static func cacheURL(
    directory: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    let directory =
      configDirectory(directory: directory, environment: environment)
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    return directory.appendingPathComponent("cuotax-usage.json")
  }

  private static func configDirectory(directory: URL?, environment: [String: String]) -> String? {
    directory?.path
      ?? environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] ?? environment["CLAUDE_CONFIG_DIR"]
  }

  private static func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return (data, response)
  }

  private struct CachedUsage: Decodable {
    let updatedAt: Double
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
    let scope: Scope?

    var window: QuotaWindow? {
      quotaWindow(percent: percent, reset: resetsAt)
    }

    enum CodingKeys: String, CodingKey {
      case kind
      case percent
      case resetsAt = "resets_at"
      case scope
    }
  }

  private struct Scope: Decodable {
    let model: Model?
  }

  private struct Model: Decodable {
    let displayName: String?

    enum CodingKeys: String, CodingKey {
      case displayName = "display_name"
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
