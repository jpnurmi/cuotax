// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import CuotaX

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

  color = try #require(
    paceColor(
      QuotaStatus(
        coverage: 0.75,
        level: .warning,
        onTrackPercent: nil,
        remainingPercent: nil,
        window: nil
      )
    )
  )
  #expect(color.red == color.green)

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

@Test func quotaChoosesTimedWindow() {
  let now = Date(timeIntervalSince1970: 1_777_000_000)
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
  #expect(status.onTrackPercent == 50)
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
        remainingPercent: nil,
        window: nil
      )
    ) == nil
  )
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
