// SPDX-License-Identifier: MIT

import Darwin
import Foundation

struct BackendError: LocalizedError, Sendable {
  let message: String
  let diagnostic: String

  var errorDescription: String? { message }
}

private struct RateLimitWindow: Decodable {
  let usedPercent: Double?
  let windowDurationMins: Int?
  let resetsAt: Double?
}

private struct RateLimits: Decodable {
  let primary: RateLimitWindow?
  let secondary: RateLimitWindow?
}

private struct RateLimitsByID: Decodable {
  let codex: RateLimits?
}

private struct RateLimitResult: Decodable {
  let rateLimits: RateLimits?
  let rateLimitsByLimitId: RateLimitsByID?
}

private struct RemoteError: Decodable {
  let message: String?
}

private struct ServerMessage: Decodable {
  let id: Int?
  let result: RateLimitResult?
  let error: RemoteError?
}

private final class ProcessContext: @unchecked Sendable {
  let process = Process()
  let input = Pipe()
  let output = Pipe()
  let error = Pipe()
  private let errorQueue = DispatchQueue(label: "com.jpnurmi.CuotaX.stderr")
  private let errorsCaptured = DispatchGroup()
  private let lock = NSLock()
  private var didCancel = false
  private var didStart = false
  private var didTimeOut = false
  private var errorData = Data()

  var cancelled: Bool {
    lock.withLock { didCancel }
  }

  var timedOut: Bool {
    lock.withLock { didTimeOut }
  }

  func cancel() {
    lock.withLock { didCancel = true }
    terminate()
  }

  func timeOut() {
    lock.withLock { didTimeOut = true }
    terminate()
  }

  func started() {
    let shouldTerminate = lock.withLock {
      didStart = true
      return didCancel || didTimeOut
    }
    if shouldTerminate {
      terminate()
    }
  }

  func checkCancellation() throws {
    if cancelled {
      throw CancellationError()
    }
  }

  private func terminate() {
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
    }
  }

  func captureErrors() {
    errorsCaptured.enter()
    errorQueue.async { [self] in
      let data = (try? error.fileHandleForReading.readToEnd()) ?? Data()
      lock.withLock { errorData.append(data) }
      errorsCaptured.leave()
    }
  }

  func terminateAndWait() {
    terminate()
    if lock.withLock({ didStart }) {
      process.waitUntilExit()
    }
    errorsCaptured.wait()
  }

  func diagnostic(fallback: String) -> String {
    let text = lock.withLock { String(bytes: errorData, encoding: .utf8) ?? "" }
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? fallback : text
  }
}

struct CodexClient: Sendable {
  private static let queue = DispatchQueue(
    label: "com.jpnurmi.CuotaX.CodexClient",
    qos: .userInitiated,
    attributes: .concurrent
  )

  private let executable: URL?
  private let environment: [String: String]
  private let timeout: TimeInterval

  init(
    executable: URL? = CodexClient.findExecutable(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    timeout: TimeInterval = 15
  ) {
    self.executable = executable
    self.environment = environment
    self.timeout = timeout
  }

  func readQuota() async throws -> Quota {
    let context = ProcessContext()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        Self.queue.async {
          do {
            try context.checkCancellation()
            let quota = try readQuotaSynchronously(context: context)
            try context.checkCancellation()
            continuation.resume(returning: quota)
          } catch {
            continuation.resume(
              throwing: context.cancelled ? CancellationError() : error
            )
          }
        }
      }
    } onCancel: {
      context.cancel()
    }
  }

  private func readQuotaSynchronously(context: ProcessContext) throws -> Quota {
    guard let executable else {
      throw BackendError(
        message: "Codex CLI not found",
        diagnostic: "Install codex on PATH or in a standard package-manager location"
      )
    }

    context.process.executableURL = executable
    context.process.arguments = ["app-server", "--stdio"]
    context.process.standardInput = context.input
    context.process.standardOutput = context.output
    context.process.standardError = context.error
    var environment = environment
    environment["PATH"] = Self.searchPaths(executable: executable, environment: environment)
      .joined(separator: ":")
    context.process.environment = environment
    do {
      try context.process.run()
      context.started()
      context.captureErrors()
    } catch {
      throw BackendError(
        message: "Codex quota request failed",
        diagnostic: error.localizedDescription
      )
    }

    let timeoutWork = DispatchWorkItem { context.timeOut() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

    defer {
      timeoutWork.cancel()
      try? context.input.fileHandleForWriting.close()
      context.terminateAndWait()
    }

    try context.checkCancellation()

    do {
      try context.input.fileHandleForWriting.write(contentsOf: Self.request)
    } catch {
      throw BackendError(
        message: "Codex quota request failed",
        diagnostic: error.localizedDescription
      )
    }

    var buffer = Data()
    while true {
      let data = context.output.fileHandleForReading.availableData
      if data.isEmpty {
        context.terminateAndWait()
        try context.checkCancellation()
        if context.timedOut {
          throw BackendError(
            message: "Codex quota request timed out",
            diagnostic: context.diagnostic(
              fallback: "No response within \(Int(timeout)) seconds")
          )
        }
        throw BackendError(
          message: "Codex returned no quota",
          diagnostic: context.diagnostic(
            fallback: "The app-server connection closed before replying")
        )
      }

      buffer.append(data)
      while let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer[..<newline]
        buffer.removeSubrange(...newline)
        guard !line.isEmpty else { continue }
        guard let message = try? JSONDecoder().decode(ServerMessage.self, from: line) else {
          throw BackendError(
            message: "Codex returned invalid data",
            diagnostic: "The app-server response was not JSON"
          )
        }
        guard message.id == 1 else { continue }
        if let error = message.error {
          throw BackendError(
            message: "Codex could not read quota",
            diagnostic: error.message ?? "Unknown app-server error"
          )
        }
        guard let result = message.result else {
          throw BackendError(
            message: "Codex returned no quota",
            diagnostic: "The rate-limit response was empty"
          )
        }
        return try Self.parseQuota(result)
      }
    }
  }

  private static func parseQuota(_ result: RateLimitResult, updatedAt: Date = Date()) throws
    -> Quota
  {
    guard let limits = result.rateLimitsByLimitId?.codex ?? result.rateLimits else {
      throw BackendError(
        message: "Codex returned no quota limits",
        diagnostic: "The rate-limit response did not contain Codex limits"
      )
    }

    var fiveHour: QuotaWindow?
    var weekly: QuotaWindow?
    for value in [limits.primary, limits.secondary].compactMap(\.self) {
      guard let usedPercent = value.usedPercent else { continue }
      let window = QuotaWindow(
        usedPercent: usedPercent,
        resetsAt: value.resetsAt.map { Date(timeIntervalSince1970: $0) }
      )
      if value.windowDurationMins == fiveHourWindowDurationMinutes {
        fiveHour = window
      } else if value.windowDurationMins == weeklyWindowDurationMinutes {
        weekly = window
      }
    }

    guard fiveHour != nil || weekly != nil else {
      throw BackendError(
        message: "Codex returned no quota limits",
        diagnostic: "The response contained neither a 5-hour nor a weekly limit"
      )
    }
    return Quota(fiveHour: fiveHour, weekly: weekly, updatedAt: updatedAt)
  }

  private static let request = Data(
    """
    {"id":0,"method":"initialize","params":{"clientInfo":{"name":"cuotax","title":"CuotaX","version":"1"}}}
    {"method":"initialized","params":{}}
    {"id":1,"method":"account/rateLimits/read"}

    """.utf8
  )

  private static func findExecutable() -> URL? {
    let environment = ProcessInfo.processInfo.environment
    for path in searchPaths(environment: environment) {
      let candidate = URL(fileURLWithPath: path).appendingPathComponent("codex")
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
    }
    return nil
  }

  private static func searchPaths(
    executable: URL? = nil,
    environment: [String: String]
  ) -> [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let executablePaths =
      executable.map {
        [
          $0.deletingLastPathComponent().path,
          $0.resolvingSymlinksInPath().deletingLastPathComponent().path,
        ]
      } ?? []
    let paths =
      executablePaths + (environment["PATH"] ?? "").split(separator: ":").map(String.init) + [
        "\(home)/.local/bin",
        "\(home)/.npm-global/bin",
        "\(home)/.volta/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
      ]

    return paths.reduce(into: []) { result, path in
      if !result.contains(path) {
        result.append(path)
      }
    }
  }
}
