// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import CuotaX

@Test func detectsAvailableUpdate() async {
  let checker = UpdateChecker(buildCommit: String(repeating: "a", count: 40)) { request in
    #expect(request.url?.absoluteString.hasSuffix("/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa...main") == true)
    return Data(#"{"ahead_by":2}"#.utf8)
  }

  #expect(await checker.isUpdateAvailable())
}

@Test func ignoresCurrentOrInvalidBuild() async {
  let current = UpdateChecker(buildCommit: String(repeating: "a", count: 40)) { _ in
    Data(#"{"ahead_by":0}"#.utf8)
  }
  #expect(await current.isUpdateAvailable() == false)

  let invalid = UpdateChecker(buildCommit: "development") { _ in
    Issue.record("Invalid commits should not make a request")
    return Data()
  }
  #expect(await invalid.isUpdateAvailable() == false)
}
