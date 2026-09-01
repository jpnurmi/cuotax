// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import CuotaX

@Test func resetFormatting() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = .current
  let date = try #require(
    calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 13, minute: 37))
  )

  #expect(
    formatReset(date, now: date.addingTimeInterval(-3 * 24 * 60 * 60))
      == "Tue, Sep 1 13:37 (3d)"
  )
  #expect(
    formatReset(date, now: date.addingTimeInterval(-7 * 60 * 60))
      == "Tue, Sep 1 13:37 (7h)"
  )
  #expect(
    formatReset(date, now: date.addingTimeInterval(-33 * 60))
      == "Tue, Sep 1 13:37 (33m)"
  )
  #expect(formatReset(date, now: date) == "Tue, Sep 1 13:37")
  #expect(formatReset(nil) == "reset unknown")
}

@Test func resetNotification() {
  let before = Date(timeIntervalSince1970: 1_777_000_000)
  let reset = before.addingTimeInterval(60)
  let after = reset.addingTimeInterval(60)
  let previous = Quota(
    fiveHour: QuotaWindow(usedPercent: 42, resetsAt: reset),
    weekly: QuotaWindow(usedPercent: 7, resetsAt: reset),
    updatedAt: before
  )
  let current = Quota(
    fiveHour: QuotaWindow(usedPercent: 0, resetsAt: after.addingTimeInterval(5 * 60 * 60)),
    weekly: QuotaWindow(usedPercent: 0, resetsAt: after.addingTimeInterval(7 * 24 * 60 * 60)),
    updatedAt: after
  )

  #expect(resetMessage(previous: nil, current: current) == nil)
  #expect(
    resetMessage(
      previous: previous,
      current: Quota(
        fiveHour: current.fiveHour,
        weekly: current.weekly,
        updatedAt: before.addingTimeInterval(30)
      )
    ) == nil
  )
  #expect(
    resetMessage(previous: previous, current: current)
      == "5-hour and weekly quotas reset"
  )

  let fiveHourOnly = Quota(
    fiveHour: previous.fiveHour,
    weekly: QuotaWindow(usedPercent: 7, resetsAt: after.addingTimeInterval(60)),
    updatedAt: before
  )
  #expect(
    resetMessage(previous: fiveHourOnly, current: current) == "5-hour quota reset"
  )

  let weeklyOnly = Quota(
    fiveHour: nil,
    weekly: previous.weekly,
    updatedAt: before
  )
  #expect(resetMessage(previous: weeklyOnly, current: current) == "Weekly quota reset")

  let alreadyExpired = Quota(
    fiveHour: QuotaWindow(usedPercent: 42, resetsAt: before),
    weekly: nil,
    updatedAt: before
  )
  #expect(resetMessage(previous: alreadyExpired, current: current) == nil)
  #expect(previous.nextReset(after: before) == reset)
  #expect(previous.nextReset(after: reset) == nil)
}

@Test func quotaPacing() throws {
  let now = Date(timeIntervalSince1970: 1_777_000_000)
  var quota = Quota(
    fiveHour: QuotaWindow(usedPercent: 25, resetsAt: now.addingTimeInterval(150 * 60)),
    weekly: nil,
    updatedAt: now
  )
  var status = quota.status(now: now)
  #expect(status.level == .normal)
  #expect(status.onTrackPercent == 50)
  #expect(status.remainingPercent == 75)
  #expect(status.window == "5-hour")
  #expect(status.paceLabel == "On track")
  var color = try #require(paceColor(status))
  #expect(color.green > color.red)

  quota = Quota(
    fiveHour: QuotaWindow(usedPercent: 60, resetsAt: now.addingTimeInterval(240 * 60)),
    weekly: nil,
    updatedAt: now
  )
  status = quota.status(now: now)
  #expect(status.level == .warning)
  #expect(status.onTrackPercent == 20)
  #expect(status.paceLabel == "Running high")
  color = try #require(paceColor(status))
  #expect(color.red > color.green)

  quota = Quota(
    fiveHour: QuotaWindow(usedPercent: 80, resetsAt: now.addingTimeInterval(240 * 60)),
    weekly: nil,
    updatedAt: now
  )
  status = quota.status(now: now)
  #expect(status.level == .critical)
  #expect(status.paceLabel == "At risk")
  color = try #require(paceColor(status))
  #expect(color.red > color.green)
}

@Test func weeklyPacingUsesEndOfDay() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = .current
  let now = try #require(
    calendar.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 12))
  )
  let reset = try #require(
    calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 14))
  )

  var status = Quota(
    fiveHour: nil,
    weekly: QuotaWindow(usedPercent: 6, resetsAt: reset),
    updatedAt: now
  ).status(now: now)
  #expect(status.onTrackPercent == 20.2)
  #expect(try #require(status.paceProgress) < 0.01)
  #expect(status.level == .normal)
  let color = try #require(paceColor(status))
  #expect(color.green > color.red)

  let finalDay = try #require(
    calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 12))
  )
  status = Quota(
    fiveHour: nil,
    weekly: QuotaWindow(usedPercent: 99, resetsAt: reset),
    updatedAt: finalDay
  ).status(now: finalDay)
  #expect(status.onTrackPercent == 100)

  let afterReset = try #require(
    calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 15))
  )
  status = Quota(
    fiveHour: nil,
    weekly: QuotaWindow(
      usedPercent: 5,
      resetsAt: reset.addingTimeInterval(7 * 24 * 60 * 60)
    ),
    updatedAt: afterReset
  ).status(now: afterReset)
  #expect(status.onTrackPercent == 6)
}

@Test func paceColorFollowsUsageThreshold() throws {
  func color(usage: Double, threshold: Double? = 70) throws -> PaceColor {
    try #require(
      paceColor(
        QuotaStatus(
          coverage: 1,
          level: .normal,
          onTrackPercent: threshold,
          paceProgress: nil,
          remainingPercent: 100 - usage,
          window: nil
        )
      )
    )
  }

  #expect(try color(usage: 0) == PaceColor(red: 54, green: 226, blue: 54))
  #expect(try color(usage: 40, threshold: 40) == PaceColor(red: 226, green: 140, blue: 54))
  #expect(try color(usage: 100) == PaceColor(red: 226, green: 54, blue: 54))
  #expect(try color(usage: 70, threshold: nil) == PaceColor(red: 226, green: 140, blue: 54))
  let daily = try #require(
    paceColor(
      QuotaStatus(
        coverage: 1,
        level: .normal,
        onTrackPercent: 23.2,
        paceProgress: (15 - 14.6) / (23.2 - 14.6),
        remainingPercent: 85,
        window: "weekly"
      )
    )
  )
  #expect(daily.green > daily.red)
}

@Test func quotaChoosesTimedWindow() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = .current
  let now = try #require(
    calendar.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 12))
  )
  let quota = Quota(
    fiveHour: QuotaWindow(usedPercent: 10, resetsAt: nil),
    weekly: QuotaWindow(
      usedPercent: 10,
      resetsAt: now.addingTimeInterval(3.5 * 24 * 60 * 60)
    ),
    updatedAt: now
  )
  let status = quota.status(now: now)
  #expect(status.window == "weekly")
  #expect(status.onTrackPercent == 57.1)
}

@Test func expiredQuotaUsesUntimedSeverity() throws {
  let now = Date(timeIntervalSince1970: 1_777_000_000)
  let quota = Quota(
    fiveHour: QuotaWindow(usedPercent: 100, resetsAt: now.addingTimeInterval(-1)),
    weekly: nil,
    updatedAt: now
  )

  let status = quota.status(now: now)
  #expect(status.coverage == 0)
  #expect(status.level == .critical)
  #expect(status.onTrackPercent == nil)
  let color = try #require(paceColor(status))
  #expect(color.red > color.green)
}

@Test func unavailableQuotaHasNoPaceColor() {
  let status = Quota(fiveHour: nil, weekly: nil, updatedAt: Date()).status()
  #expect(paceColor(status) == nil)
  #expect(
    paceColor(
      QuotaStatus(
        coverage: 1,
        level: .unavailable,
        onTrackPercent: nil,
        paceProgress: nil,
        remainingPercent: nil,
        window: nil
      )
    ) == nil
  )
}

@Test func nonFiniteUsageHasNoPaceColor() {
  for remainingPercent in [Double.nan, .infinity, -Double.infinity] {
    #expect(
      paceColor(
        QuotaStatus(
          coverage: 1,
          level: .normal,
          onTrackPercent: 50,
          paceProgress: nil,
          remainingPercent: remainingPercent,
          window: nil
        )
      ) == nil
    )
  }
}

@Test func quotaFormattingAndSeverity() {
  #expect(displayPercent(131) == 100)
  #expect(displayPercent(-1) == 0)
  #expect(normalizedPercent(69.96) == 70)
  #expect(formatPercent(42.5) == "42.5%")
  #expect(formatPercent(nil) == "—")
  #expect(severity(70) == .warning)
  #expect(severity(90) == .critical)
}
