// SPDX-License-Identifier: MIT

import Foundation

let fiveHourWindowDurationMinutes = 5 * 60
let weeklyWindowDurationMinutes = 7 * 24 * 60

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
      windowStatus(
        fiveHour, name: "5-hour", durationMinutes: fiveHourWindowDurationMinutes, now: now),
      windowStatus(
        weekly, name: "weekly", durationMinutes: weeklyWindowDurationMinutes, now: now),
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
  durationMinutes: Int,
  now: Date
) -> RankedStatus? {
  guard let value else { return nil }

  let usedPercent = normalizedPercent(value.usedPercent)
  let remainingPercent = 100 - usedPercent
  guard let resetsAt = value.resetsAt, resetsAt > now else {
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

  let duration = Double(durationMinutes * 60)
  let timeRemaining = min(1, max(0, resetsAt.timeIntervalSince(now) / duration))
  let onTrackPercent = (1000 * (1 - timeRemaining)).rounded() / 10
  let coverage = remainingPercent / 100 / timeRemaining
  let level: QuotaLevel =
    if usedPercent <= onTrackPercent {
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

func normalizedPercent(_ value: Double) -> Double {
  (displayPercent(value) * 10).rounded() / 10
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

func formatTime(_ value: Date?) -> String {
  value?.formatted(date: .omitted, time: .shortened) ?? "—"
}

func formatReset(_ value: Date?) -> String {
  value.map { "resets \($0.formatted(date: .numeric, time: .shortened))" }
    ?? "reset unknown"
}
