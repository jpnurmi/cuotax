// SPDX-License-Identifier: MIT

import Foundation

struct QuotaWindow: Equatable, Sendable {
  let usedPercent: Double
  let resetsAt: Date?
}

struct Quota: Equatable, Sendable {
  let fiveHour: QuotaWindow?
  let weekly: QuotaWindow?
  let updatedAt: Date

  var highestPercent: Double? {
    [fiveHour, weekly].compactMap(\.self).map(\.usedPercent).max()
  }
}

enum QuotaLevel: Sendable {
  case normal
  case warning
  case critical
  case unavailable
}

struct QuotaStatus: Sendable {
  let coverage: Double?
  let level: QuotaLevel
  let onTrackPercent: Double?
  let remainingPercent: Double?
  let window: String?

  var paceLabel: String {
    switch level {
    case .normal: "On track"
    case .warning: "Running high"
    case .critical: "At risk"
    case .unavailable: "Pace unavailable"
    }
  }
}

extension Quota {
  func status(now: Date = Date()) -> QuotaStatus {
    let statuses = [
      windowStatus(fiveHour, name: "5-hour", durationMinutes: 300, now: now),
      windowStatus(weekly, name: "weekly", durationMinutes: 7 * 24 * 60, now: now),
    ].compactMap(\.self)

    guard !statuses.isEmpty else {
      return QuotaStatus(
        coverage: nil,
        level: .unavailable,
        onTrackPercent: nil,
        remainingPercent: nil,
        window: nil
      )
    }

    let timed = statuses.filter { $0.onTrackPercent != nil }
    return (timed.isEmpty ? statuses : timed).min { $0.coverage < $1.coverage }!.status
  }
}

private struct RankedStatus {
  let coverage: Double
  let status: QuotaStatus

  var onTrackPercent: Double? { status.onTrackPercent }
}

private func windowStatus(
  _ value: QuotaWindow?,
  name: String,
  durationMinutes: Double,
  now: Date
) -> RankedStatus? {
  guard let value else { return nil }

  let usedPercent = displayPercent(value.usedPercent)
  let remainingPercent = 100 - usedPercent
  guard let resetsAt = value.resetsAt else {
    return RankedStatus(
      coverage: remainingPercent / 100,
      status: QuotaStatus(
        coverage: remainingPercent / 100,
        level: severity(usedPercent),
        onTrackPercent: nil,
        remainingPercent: remainingPercent,
        window: name
      )
    )
  }

  let duration = durationMinutes * 60
  let timeRemaining = min(1, max(0, resetsAt.timeIntervalSince(now) / duration))
  let onTrackPercent = (1000 * (1 - timeRemaining)).rounded() / 10
  let coverage = timeRemaining == 0 ? .infinity : remainingPercent / 100 / timeRemaining
  let roundedUsed = (usedPercent * 10).rounded() / 10
  let level: QuotaLevel =
    if roundedUsed <= onTrackPercent {
      .normal
    } else if coverage < 0.5 {
      .critical
    } else {
      .warning
    }

  return RankedStatus(
    coverage: coverage,
    status: QuotaStatus(
      coverage: coverage,
      level: level,
      onTrackPercent: onTrackPercent,
      remainingPercent: remainingPercent,
      window: name
    )
  )
}

struct PaceColor: Equatable, Sendable {
  let red: Int
  let green: Int
  let blue: Int
}

func paceColor(_ status: QuotaStatus) -> PaceColor? {
  guard status.level != .unavailable, let value = status.coverage, !value.isNaN else {
    return nil
  }

  let coverage = min(1, max(0, value))
  let hue = 120 * (1 - sqrt(1 - coverage))
  let saturation = 0.75
  let lightness = 0.55
  let chroma = (1 - abs(2 * lightness - 1)) * saturation
  let secondary = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
  let offset = lightness - chroma / 2
  let (red, green) = hue < 60 ? (chroma, secondary) : (secondary, chroma)
  return PaceColor(
    red: Int(((red + offset) * 255).rounded()),
    green: Int(((green + offset) * 255).rounded()),
    blue: Int((offset * 255).rounded())
  )
}

func displayPercent(_ value: Double) -> Double {
  min(100, max(0, value))
}

func severity(_ value: Double) -> QuotaLevel {
  if value >= 90 { return .critical }
  if value >= 70 { return .warning }
  return .normal
}

func formatPercent(_ value: Double?) -> String {
  guard let value else { return "—" }
  let displayed = displayPercent(value)
  return displayed.rounded() == displayed
    ? String(format: "%.0f%%", displayed)
    : String(format: "%.1f%%", displayed)
}

private let timeFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "HH:mm"
  return formatter
}()

private let resetFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "yyyy-MM-dd HH:mm"
  return formatter
}()

func formatTime(_ value: Date?) -> String {
  value.map { timeFormatter.string(from: $0) } ?? "—"
}

func formatReset(_ value: Date?) -> String {
  value.map { "resets \(resetFormatter.string(from: $0))" } ?? "reset unknown"
}
