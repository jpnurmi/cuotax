// SPDX-License-Identifier: MIT

import AppKit
import Combine
import CoreText
import UserNotifications

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
  private let defaults: UserDefaults
  private let notifier = ResetNotifier()
  private let updateChecker = UpdateChecker()
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let menu = NSMenu()
  private var providers: Set<Provider>
  private var models: [Provider: AppModel] = [:]
  private var subscriptions: [Provider: Set<AnyCancellable>] = [:]
  private var observedQuotas: [Provider: Quota] = [:]
  private var updateAvailable = false
  private var isMenuOpen = false
  private var updateTask: Task<Void, Never>?
  private var updateLoop: Task<Void, Never>?
  private var cancellables = Set<AnyCancellable>()

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    providers = Provider.load(from: defaults)
    super.init()

    menu.delegate = self
    menu.autoenablesItems = false
    item.menu = menu
    item.button?.imagePosition = .imageLeading
    item.button?.imageHugsTitle = true
    item.button?.imageScaling = .scaleProportionallyDown

    updateModels()
    checkForUpdates()
    updateLoop = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: 24 * 60 * 60 * 1_000_000_000)
        } catch {
          return
        }
        self?.checkForUpdates()
      }
    }
    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
      .sink { [weak self] _ in
        DispatchQueue.main.async {
          guard let self else { return }
          for model in self.models.values { model.refreshAfterWake() }
          self.checkForUpdates()
        }
      }
      .store(in: &cancellables)
    LoginItem.registerIfNeeded()
  }

  deinit {
    updateTask?.cancel()
    updateLoop?.cancel()
  }

  private func toggle(_ provider: Provider) {
    if providers.contains(provider) {
      guard providers.count > 1 else { return }
      providers.remove(provider)
      subscriptions.removeValue(forKey: provider)
      models.removeValue(forKey: provider)?.stop()
      observedQuotas.removeValue(forKey: provider)
    } else {
      providers.insert(provider)
    }
    defaults.set(Provider.allCases.filter(providers.contains).map(\.rawValue), forKey: "providers")
    updateModels()
  }

  private func updateModels() {
    for provider in Provider.allCases where providers.contains(provider) && models[provider] == nil
    {
      let model = AppModel(provider: provider)
      models[provider] = model
      var cancellables = Set<AnyCancellable>()
      model.objectWillChange
        .sink { [weak self] in
          DispatchQueue.main.async { self?.render() }
        }
        .store(in: &cancellables)
      model.$quota
        .compactMap(\.self)
        .sink { [weak self, weak model] quota in
          guard let self, let model, self.models[provider] === model else { return }
          let message = resetMessage(previous: self.observedQuotas[provider], current: quota)
          self.observedQuotas[provider] = quota
          if let message { self.notifier.notify(message, provider: provider) }
        }
        .store(in: &cancellables)
      subscriptions[provider] = cancellables
      model.start()
    }
    render()
  }

  private func checkForUpdates() {
    guard updateTask == nil else { return }
    updateTask = Task { [weak self, updateChecker] in
      let available = await updateChecker.isUpdateAvailable()
      guard !Task.isCancelled else { return }
      if available {
        self?.updateAvailable = true
        self?.render()
      }
      self?.updateTask = nil
    }
  }

  func menuWillOpen(_ menu: NSMenu) {
    isMenuOpen = true
    for model in models.values { model.refreshIfStale() }
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
    let models = Provider.allCases.compactMap { self.models[$0] }
    guard
      let highest = models.max(by: {
        ($0.quota?.highestPercent ?? -1) < ($1.quota?.highestPercent ?? -1)
      })
    else { return }
    let stacked = models.count > 1
    button.imagePosition = stacked ? .imageOnly : .imageLeading
    button.image = quotaImage(
      status: highest.status,
      color: statusColor(highest.status),
      updateAvailable: updateAvailable,
      percentages: stacked ? models.map { ($0.title, statusColor($0.status)) } : []
    )
    button.attributedTitle = NSAttributedString(
      string: stacked ? "" : highest.title,
      attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        .foregroundColor: statusColor(highest.status),
      ]
    )
    let labels = models.map { model in
      if model.quota != nil {
        return "\(model.provider.title) \(model.title), \(model.status.paceLabel.lowercased())"
      }
      return model.error.map { "\(model.provider.title) unavailable: \($0.message)" }
        ?? "\(model.provider.title) loading"
    }
    let suffix = updateAvailable ? ", update available" : ""
    let label = "CuotaX " + labels.joined(separator: "; ") + suffix
    button.toolTip = label
    button.setAccessibilityLabel(label)
  }

  private func renderMenu() {
    menu.removeAllItems()

    for provider in Provider.allCases {
      let item = actionItem(provider.title, action: #selector(toggleProvider(_:)))
      item.representedObject = provider.rawValue
      item.state = providers.contains(provider) ? .on : .off
      item.isEnabled = !providers.contains(provider) || providers.count > 1
      menu.addItem(item)
      if let model = models[provider] {
        addQuotaSection(model)
      }
      menu.addItem(.separator())
    }
    menu.addItem(actionItem("Refresh", action: #selector(refresh), keyEquivalent: "r"))

    menu.addItem(.separator())
    menu.addItem(actionItem("Quit CuotaX", action: #selector(quit), keyEquivalent: "q"))
  }

  private func addQuotaSection(_ model: AppModel) {
    let start = menu.numberOfItems
    if let quota = model.quota {
      menu.addItem(quotaItem(label: "5-hour", quota: quota.fiveHour, fiveHour: true))
      menu.addItem(quotaItem(label: "Weekly", quota: quota.weekly, fiveHour: false))
      if let error = model.error {
        menu.addItem(infoItem("Refresh failed · showing previous data", color: .systemRed))
        menu.addItem(infoItem(error.diagnostic))
      }
      menu.addItem(infoItem("Updated \(formatTime(quota.updatedAt))"))
    } else if let error = model.error {
      menu.addItem(infoItem(error.message, color: .systemRed))
      menu.addItem(infoItem(error.diagnostic))
    } else {
      menu.addItem(infoItem("Loading \(model.provider.title) quota…"))
    }
    for index in start..<menu.numberOfItems { menu.item(at: index)?.indentationLevel = 1 }
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
        "\(label)  \(formatPercent($0.usedPercent))\(reference) · \(formatReset($0.resetsAt, includeDate: !fiveHour))"
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
    for model in models.values { model.refresh() }
  }

  @objc private func toggleProvider(_ item: NSMenuItem) {
    guard let value = item.representedObject as? String,
      let provider = Provider(rawValue: value)
    else { return }
    toggle(provider)
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }
}

private final class ResetNotifier: NSObject, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()

  override init() {
    super.init()
    center.delegate = self
    center.requestAuthorization(options: [.alert]) { _, _ in }
  }

  func notify(_ message: String, provider: Provider) {
    let content = UNMutableNotificationContent()
    content.title = "\(provider.title) quota reset"
    content.body = message
    center.add(
      UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    )
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner])
  }
}

func statusColor(_ status: QuotaStatus) -> NSColor {
  guard let color = paceColor(status) else { return .secondaryLabelColor }
  return NSColor(
    srgbRed: Double(color.red) / 255,
    green: Double(color.green) / 255,
    blue: Double(color.blue) / 255,
    alpha: 1
  )
}

func quotaImage(
  status: QuotaStatus, color: NSColor, updateAvailable: Bool,
  percentages: [(String, NSColor)] = []
) -> NSImage {
  let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
  let lines = percentages.map { value, color in
    CTLineCreateWithAttributedString(
      NSAttributedString(
        string: value, attributes: [.font: font, .foregroundColor: color.cgColor]
      ))
  }
  let widths = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
  let width = ceil(widths.max() ?? 0)
  let size = NSSize(width: 18 + (lines.isEmpty ? 0 : 4 + width), height: 18)
  let image = NSImage(size: size, flipped: false) { _ in
    let center = NSPoint(x: 9, y: 9)
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

    if updateAvailable {
      NSColor(srgbRed: 22 / 255, green: 136 / 255, blue: 248 / 255, alpha: 1).setFill()
      NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 5, height: 5)).fill()
    }
    if let context = NSGraphicsContext.current?.cgContext {
      context.saveGState()
      context.textMatrix = .identity
      context.setShouldSubpixelPositionFonts(true)
      context.setShouldSubpixelQuantizeFonts(false)
      for (index, line) in lines.enumerated() {
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textPosition = CGPoint(
          x: 22 + (width - widths[index]) / 2,
          y: center.y + (CGFloat(lines.count - 1) / 2 - CGFloat(index)) * 10 - bounds.midY
        )
        CTLineDraw(line, context)
      }
      context.restoreGState()
    }
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
