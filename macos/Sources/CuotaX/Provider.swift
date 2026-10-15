// SPDX-License-Identifier: MIT

import Foundation

enum Provider: String, CaseIterable {
  case codex
  case claude

  var title: String { self == .codex ? "Codex" : "Claude" }

  static func load(from defaults: UserDefaults) -> Set<Provider> {
    if let values = defaults.stringArray(forKey: "providers") {
      let providers = Set(values.compactMap(Provider.init(rawValue:)))
      if !providers.isEmpty { return providers }
    }
    let provider = defaults.string(forKey: "provider").flatMap(Provider.init(rawValue:)) ?? .codex
    return [provider]
  }
}
