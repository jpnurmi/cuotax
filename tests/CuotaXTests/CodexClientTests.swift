// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import CuotaX

@Test func readsQuotaFromAppServer() async throws {
  let fixture = try #require(
    Bundle.module.url(forResource: "codex", withExtension: nil, subdirectory: "Fixtures"))
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)
  let quota = try await CodexClient(executable: fixture).readQuota()

  #expect(quota.fiveHour?.usedPercent == 42)
  #expect(quota.weekly?.usedPercent == 7)
}

@Test func addsExecutableDirectoryToPath() async throws {
  let executable = try #require(
    Bundle.module.url(
      forResource: "codex-env", withExtension: nil, subdirectory: "Fixtures"))
  let runtime = try #require(
    Bundle.module.url(
      forResource: "cuotax-test-runtime", withExtension: nil, subdirectory: "Fixtures"))
  for fixture in [executable, runtime] {
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: fixture.path)
  }

  let quota = try await CodexClient(
    executable: executable,
    environment: [
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin",
    ]
  ).readQuota()

  #expect(quota.fiveHour?.usedPercent == 42)
  #expect(quota.weekly?.usedPercent == 7)
}

@Test func reportsAppServerErrorOutput() async throws {
  let fixture = try #require(
    Bundle.module.url(
      forResource: "codex-failure", withExtension: nil, subdirectory: "Fixtures"))
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)

  do {
    _ = try await CodexClient(executable: fixture).readQuota()
    Issue.record("Expected the app-server request to fail")
  } catch let error as BackendError {
    #expect(error.message == "Codex returned no quota")
    #expect(error.diagnostic == "fixture app-server failed")
  }
}

@Test func reportsMissingExecutable() async {
  do {
    _ = try await CodexClient(executable: nil).readQuota()
    Issue.record("Expected the missing Codex CLI to fail")
  } catch let error as BackendError {
    #expect(error.message == "Codex CLI not found")
  } catch {
    Issue.record("Expected BackendError, got \(error)")
  }
}

@Test func reportsTimeout() async throws {
  let fixture = try #require(
    Bundle.module.url(
      forResource: "codex-hang", withExtension: nil, subdirectory: "Fixtures"))
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)

  do {
    _ = try await CodexClient(executable: fixture, timeout: 0.1).readQuota()
    Issue.record("Expected the app-server request to time out")
  } catch let error as BackendError {
    #expect(error.message == "Codex quota request timed out")
    #expect(error.diagnostic.hasPrefix("No response within"))
  }
}

@Test func cancellationStopsRequest() async throws {
  let fixture = try #require(
    Bundle.module.url(
      forResource: "codex-hang", withExtension: nil, subdirectory: "Fixtures"))
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)

  let task = Task {
    try await CodexClient(executable: fixture, timeout: 5).readQuota()
  }
  try await Task.sleep(nanoseconds: 50_000_000)
  task.cancel()

  do {
    _ = try await task.value
    Issue.record("Expected the app-server request to be cancelled")
  } catch is CancellationError {
  } catch {
    Issue.record("Expected CancellationError, got \(error)")
  }
}

@Test func readsLiveQuotaWhenRequested() async throws {
  let environment = ProcessInfo.processInfo.environment
  guard environment["CODEX_TEST_LIVE"] == "1", let command = environment["CODEX_TEST_COMMAND"]
  else { return }

  var restrictedEnvironment = environment
  restrictedEnvironment["PATH"] = "/usr/bin:/bin"
  let quota = try await CodexClient(
    executable: URL(fileURLWithPath: command),
    environment: restrictedEnvironment
  ).readQuota()

  #expect(quota.fiveHour != nil || quota.weekly != nil)
}
