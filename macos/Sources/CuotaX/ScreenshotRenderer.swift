// SPDX-License-Identifier: MIT

import AppKit
import Foundation

@MainActor
enum ScreenshotRenderer {
  private static let width = 740
  private static let height = 442
  private static let labelColor = NSColor(
    srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 1)
  private static let secondaryColor = NSColor(
    srgbRed: 0.66, green: 0.66, blue: 0.69, alpha: 1)
  private static let now = Date(timeIntervalSince1970: 1_787_919_780)
  private static let quota = Quota(
    fiveHour: QuotaWindow(
      usedPercent: 68,
      resetsAt: Date(timeIntervalSince1970: 1_787_928_780)
    ),
    weekly: QuotaWindow(
      usedPercent: 42,
      resetsAt: Date(timeIntervalSince1970: 1_788_279_180)
    ),
    updatedAt: now
  )

  static func write(to path: String) throws {
    guard
      let image = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ),
      let context = NSGraphicsContext(bitmapImageRep: image)
    else {
      throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    draw()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = image.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: url)
  }

  private static func draw() {
    let background = topRect(x: 0, y: 0, width: width, height: height)
    NSGradient(
      colors: [
        NSColor(srgbRed: 0.08, green: 0.1, blue: 0.15, alpha: 1),
        NSColor(srgbRed: 0.2, green: 0.22, blue: 0.28, alpha: 1),
      ])?.draw(in: background, angle: -35)

    NSColor(srgbRed: 0.05, green: 0.05, blue: 0.055, alpha: 0.96).setFill()
    topRect(x: 0, y: 0, width: width, height: 38).fill()
    drawText("CuotaX", x: 22, y: 10, size: 13, color: .white, weight: .semibold)
    drawText("Fri 28 Aug  12:23", x: 592, y: 10, size: 13, color: .white)

    let overall = quota.status(now: now)
    let color = statusColor(overall)
    let icon = quotaImage(status: overall, color: color, updateAvailable: true)
    icon.draw(in: topRect(x: 477, y: 9, width: 18, height: 18))
    drawText("68%", x: 501, y: 9, size: 14, color: color)

    let menu = topRect(x: 174, y: 42, width: 544, height: 386)
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -5)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
    shadow.set()
    NSColor(srgbRed: 0.12, green: 0.12, blue: 0.125, alpha: 0.985).setFill()
    NSBezierPath(roundedRect: menu, xRadius: 13, yRadius: 13).fill()
    NSShadow().set()

    drawWindow("5-hour", value: quota.fiveHour!, fiveHour: true, y: 74)
    drawWindow("Weekly", value: quota.weekly!, fiveHour: false, y: 126)
    separator(y: 177)
    drawText(
      "Updated \(formatTime(quota.updatedAt))",
      x: 207,
      y: 198,
      size: 15,
      color: secondaryColor
    )
    separator(y: 237)
    drawText("Refresh", x: 207, y: 258, size: 15, color: labelColor)
    drawText("⌘R", x: 668, y: 258, size: 15, color: secondaryColor)
    separator(y: 298)
    drawText("Quit CuotaX", x: 207, y: 319, size: 15, color: labelColor)
    drawText("⌘Q", x: 668, y: 319, size: 15, color: secondaryColor)
  }

  private static func drawWindow(
    _ label: String,
    value: QuotaWindow,
    fiveHour: Bool,
    y: Int
  ) {
    let status = Quota(
      fiveHour: fiveHour ? value : nil,
      weekly: fiveHour ? nil : value,
      updatedAt: now
    ).status(now: now)
    let color = statusColor(status)
    color.setFill()
    NSBezierPath(ovalIn: topRect(x: 207, y: y + 5, width: 8, height: 8)).fill()
    let comparison = normalizedPercent(value.usedPercent) <= status.onTrackPercent! ? "≤" : ">"
    let title =
      "\(label)  \(formatPercent(value.usedPercent)) (\(comparison)\(formatPercent(status.onTrackPercent))) · \(formatReset(value.resetsAt))"
    drawText(title, x: 228, y: y, size: 15, color: labelColor)
  }

  private static func separator(y: Int) {
    NSColor(srgbRed: 0.3, green: 0.3, blue: 0.32, alpha: 1).setFill()
    topRect(x: 197, y: y, width: 498, height: 1).fill()
  }

  private static func drawText(
    _ value: String,
    x: Int,
    y: Int,
    size: CGFloat,
    color: NSColor,
    weight: NSFont.Weight = .regular
  ) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: size, weight: weight),
      .foregroundColor: color,
    ]
    let string = value as NSString
    let measured = string.size(withAttributes: attributes)
    string.draw(
      at: NSPoint(x: CGFloat(x), y: CGFloat(height - y) - measured.height),
      withAttributes: attributes
    )
  }

  private static func topRect(x: Int, y: Int, width: Int, height: Int) -> NSRect {
    NSRect(
      x: CGFloat(x),
      y: CGFloat(Self.height - y - height),
      width: CGFloat(width),
      height: CGFloat(height)
    )
  }
}
