// SPDX-License-Identifier: MIT

import AppKit
import Darwin
import SwiftUI

@main
@MainActor
struct CuotaXApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    Settings {
      EmptyView()
    }
  }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: StatusItemController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let index = CommandLine.arguments.firstIndex(of: "--screenshot"),
      CommandLine.arguments.indices.contains(index + 1)
    {
      do {
        try ScreenshotRenderer.write(to: CommandLine.arguments[index + 1])
        exit(EXIT_SUCCESS)
      } catch {
        fputs("CuotaX: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
      }
    }

    if CommandLine.arguments.contains("--unregister") {
      do {
        try LoginItem.unregisterForRemoval()
        exit(EXIT_SUCCESS)
      } catch {
        fputs("CuotaX: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
      }
    }

    statusItem = StatusItemController()
  }
}
