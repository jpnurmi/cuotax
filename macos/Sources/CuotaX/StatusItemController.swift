// SPDX-License-Identifier: MIT

import AppKit
import Combine

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
  private let model = AppModel()
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let menu = NSMenu()
  private var cancellables = Set<AnyCancellable>()
  private var isMenuOpen = false

  override init() {
    super.init()

    menu.delegate = self
    menu.autoenablesItems = false
    item.menu = menu
    item.button?.imagePosition = .imageLeading
    item.button?.imageHugsTitle = true
    item.button?.imageScaling = .scaleProportionallyDown

    model.objectWillChange
      .sink { [weak self] in
        DispatchQueue.main.async { self?.render() }
      }
      .store(in: &cancellables)

    LoginItem.registerIfNeeded()
    render()
    model.start()
  }

  func menuWillOpen(_ menu: NSMenu) {
    isMenuOpen = true
    model.refreshIfStale()
    renderMenu()
  }

  func menuDidClose(_ menu: NSMenu) {
    isMenuOpen = false
    renderMenu()
  }

  private func render() {
    renderButton()
    if !isMenuOpen {
      renderMenu()
    }
  }

  private func renderButton() {
    guard let button = item.button else { return }

    let color = statusColor(model.status)
    button.image = quotaImage(status: model.status, color: color)
    button.attributedTitle = NSAttributedString(
      string: model.title,
      attributes: [
        .font: NSFont.monospacedDigitSystemFont(
          ofSize: NSFont.systemFontSize,
          weight: .regular
        ),
        .foregroundColor: color,
      ]
    )
    button.toolTip = accessibilityLabel
    button.setAccessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    guard model.quota != nil else {
      return model.error.map { "CuotaX unavailable: \($0.message)" } ?? "CuotaX loading"
    }
    return "CuotaX \(model.title), \(model.status.paceLabel.lowercased())"
  }

  private func renderMenu() {
    menu.removeAllItems()

    if let quota = model.quota {
      menu.addItem(quotaItem(label: "5-hour", quota: quota.fiveHour, fiveHour: true))
      menu.addItem(quotaItem(label: "Weekly", quota: quota.weekly, fiveHour: false))
      if let error = model.error {
        menu.addItem(.separator())
        menu.addItem(infoItem("Refresh failed · showing previous data", color: .systemRed))
        menu.addItem(infoItem(error.diagnostic))
      }
      menu.addItem(.separator())
      menu.addItem(infoItem("Updated \(formatTime(quota.updatedAt))"))
    } else if let error = model.error {
      menu.addItem(infoItem(error.message, color: .systemRed))
      menu.addItem(infoItem(error.diagnostic))
    } else {
      menu.addItem(infoItem("Loading Codex quota…"))
    }

    menu.addItem(.separator())
    menu.addItem(actionItem("Refresh", action: #selector(refresh), keyEquivalent: "r"))

    menu.addItem(.separator())
    menu.addItem(actionItem("Quit CuotaX", action: #selector(quit), keyEquivalent: "q"))
  }

  private func quotaItem(label: String, quota: QuotaWindow?, fiveHour: Bool) -> NSMenuItem {
    let status = Quota(
      fiveHour: fiveHour ? quota : nil,
      weekly: fiveHour ? nil : quota,
      updatedAt: Date()
    ).status()
    let reference =
      quota.flatMap { value in
        status.onTrackPercent.map {
          " (\(normalizedPercent(value.usedPercent) <= $0 ? "≤" : ">")\(formatPercent($0)))"
        }
      } ?? ""
    let title =
      quota.map {
        "\(label)  \(formatPercent($0.usedPercent))\(reference) · \(formatReset($0.resetsAt))"
      } ?? "\(label)  —"
    let item = infoItem(title)
    item.image = paceImage(color: statusColor(status))
    item.setAccessibilityLabel(
      quota.map {
        let pacing =
          status.onTrackPercent.map { "\(formatPercent($0)) is on track" }
          ?? "pacing unavailable"
        return "\(label): \(formatPercent($0.usedPercent)) used; \(pacing)"
      } ?? "\(label): unavailable"
    )
    return item
  }

  private func infoItem(_ title: String, color: NSColor = .secondaryLabelColor) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.attributedTitle = NSAttributedString(
      string: title,
      attributes: [.foregroundColor: color]
    )
    return item
  }

  private func actionItem(
    _ title: String,
    action: Selector,
    keyEquivalent: String = ""
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = self
    return item
  }

  @objc private func refresh() {
    model.refresh()
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }
}

private func statusColor(_ status: QuotaStatus) -> NSColor {
  guard let color = paceColor(status) else { return .secondaryLabelColor }
  return NSColor(
    srgbRed: Double(color.red) / 255,
    green: Double(color.green) / 255,
    blue: Double(color.blue) / 255,
    alpha: 1
  )
}

private func quotaImage(status: QuotaStatus, color: NSColor) -> NSImage {
  let size = NSSize(width: 18, height: 18)
  let image = NSImage(size: size, flipped: false) { _ in
    let center = NSPoint(x: size.width / 2, y: size.height / 2)
    let radius = 7.1

    color.withAlphaComponent(0.25).setStroke()
    let track = NSBezierPath(ovalIn: NSRect(x: 1.9, y: 1.9, width: 14.2, height: 14.2))
    track.lineWidth = 1.8
    track.stroke()

    if let remaining = status.remainingPercent {
      color.setStroke()
      let progress = NSBezierPath()
      progress.appendArc(
        withCenter: center,
        radius: radius,
        startAngle: 90,
        endAngle: 90 - 360 * displayPercent(remaining) / 100,
        clockwise: true
      )
      progress.lineWidth = 1.8
      progress.lineCapStyle = .round
      progress.stroke()
    }

    color.setStroke()
    let glyph = NSBezierPath()
    glyph.move(to: NSPoint(x: 6.2, y: 11.4))
    glyph.line(to: NSPoint(x: 8.6, y: 9))
    glyph.line(to: NSPoint(x: 6.2, y: 6.6))
    glyph.move(to: NSPoint(x: 9.4, y: 6.6))
    glyph.line(to: NSPoint(x: 12.2, y: 6.6))
    glyph.lineWidth = 1.4
    glyph.lineCapStyle = .round
    glyph.lineJoinStyle = .round
    glyph.stroke()
    return true
  }
  image.isTemplate = false
  return image
}

private func paceImage(color: NSColor) -> NSImage {
  let size = NSSize(width: 8, height: 8)
  let image = NSImage(size: size, flipped: false) { _ in
    color.setFill()
    NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
    return true
  }
  image.isTemplate = false
  return image
}
