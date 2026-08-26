// SPDX-License-Identifier: MIT

import ServiceManagement

@MainActor
final class LoginItem {
  func registerIfNeeded() {
    let status = SMAppService.mainApp.status
    guard status != .enabled && status != .requiresApproval else { return }
    do {
      try SMAppService.mainApp.register()
    } catch {
      NSLog("CuotaX: Could not register launch at login: %@", error.localizedDescription)
    }
  }

  static func unregisterForRemoval() throws {
    let status = SMAppService.mainApp.status
    guard status == .enabled || status == .requiresApproval else { return }
    try SMAppService.mainApp.unregister()
  }
}
