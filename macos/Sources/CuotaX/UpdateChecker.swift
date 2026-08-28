// SPDX-License-Identifier: MIT

import Foundation

struct UpdateChecker: Sendable {
  typealias Loader = @Sendable (URLRequest) async throws -> Data

  private static let apiURL = "https://api.github.com/repos/jpnurmi/cuotax/compare"
  private let buildCommit: String?
  private let load: Loader

  init(
    buildCommit: String? = Bundle.main.object(forInfoDictionaryKey: "CuotaXBuildCommit") as? String,
    load: @escaping Loader = UpdateChecker.load
  ) {
    self.buildCommit = buildCommit
    self.load = load
  }

  func isUpdateAvailable() async -> Bool {
    guard let buildCommit, Self.isCommit(buildCommit),
      let url = URL(string: "\(Self.apiURL)/\(buildCommit)...main")
    else { return false }

    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("CuotaX", forHTTPHeaderField: "User-Agent")
    do {
      return try Self.hasUpdate(in: await load(request))
    } catch {
      return false
    }
  }

  static func hasUpdate(in data: Data) throws -> Bool {
    try JSONDecoder().decode(Comparison.self, from: data).aheadBy > 0
  }

  private static func isCommit(_ value: String) -> Bool {
    value.count == 40 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  private static func load(_ request: URLRequest) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode)
    else { throw URLError(.badServerResponse) }
    return data
  }
}

private struct Comparison: Decodable {
  let aheadBy: Int

  enum CodingKeys: String, CodingKey {
    case aheadBy = "ahead_by"
  }
}
