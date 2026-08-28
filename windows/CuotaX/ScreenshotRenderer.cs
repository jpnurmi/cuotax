// SPDX-License-Identifier: MIT

using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;

namespace CuotaX;

internal static class ScreenshotRenderer
{
    private const int Width = 740;
    private const int Height = 442;
    private static readonly DateTimeOffset Now = new(2026, 8, 28, 12, 23, 0, TimeSpan.Zero);
    private static readonly Quota Fixture = new(
        new QuotaWindow(68, new DateTimeOffset(2026, 8, 28, 14, 53, 0, TimeSpan.Zero)),
        new QuotaWindow(42, new DateTimeOffset(2026, 9, 1, 16, 13, 0, TimeSpan.Zero)),
        Now
    );

    internal static void Save(string path)
    {
        using var image = new Bitmap(Width, Height, PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(image);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

        using (var background = new LinearGradientBrush(
            new Rectangle(0, 0, Width, Height),
            Color.FromArgb(24, 72, 128),
            Color.FromArgb(72, 31, 111),
            32
        ))
        {
            graphics.FillRectangle(background, 0, 0, Width, Height);
        }

        using (var glow = new SolidBrush(Color.FromArgb(28, 255, 255, 255)))
        {
            graphics.FillEllipse(glow, -80, 30, 520, 520);
        }

        DrawMenu(graphics);
        DrawTaskbar(graphics);

        var fullPath = Path.GetFullPath(path);
        Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
        image.Save(fullPath, ImageFormat.Png);
    }

    private static void DrawMenu(Graphics graphics)
    {
        var bounds = new RectangleF(165, 35, 535, 344);
        using (var shadowPath = RoundedRectangle(
            new RectangleF(bounds.X + 4, bounds.Y + 5, bounds.Width, bounds.Height),
            10
        ))
        using (var shadow = new SolidBrush(Color.FromArgb(72, 0, 0, 0)))
        {
            graphics.FillPath(shadow, shadowPath);
        }
        using (var path = RoundedRectangle(bounds, 10))
        using (var menu = new SolidBrush(Color.FromArgb(246, 246, 246)))
        using (var border = new Pen(Color.FromArgb(180, 186, 190), 1))
        {
            graphics.FillPath(menu, path);
            graphics.DrawPath(border, path);
        }

        DrawWindow(graphics, "5-hour", Fixture.FiveHour!, true, 67);
        DrawWindow(graphics, "Weekly", Fixture.Weekly!, false, 113);
        Separator(graphics, 162);
        DrawText(graphics, $"Updated {Now:HH:mm}", 190, 184, Color.FromArgb(88, 88, 88));
        Separator(graphics, 224);
        DrawText(graphics, "Refresh", 190, 248, Color.FromArgb(30, 30, 30));
        Separator(graphics, 287);
        DrawText(graphics, "Quit CuotaX", 190, 311, Color.FromArgb(30, 30, 30));
    }

    private static void DrawWindow(
        Graphics graphics,
        string label,
        QuotaWindow window,
        bool fiveHour,
        float y
    )
    {
        var status = Quota.StatusFor(
            window,
            fiveHour ? "5-hour" : "weekly",
            fiveHour ? QuotaFormatting.FiveHourMinutes : QuotaFormatting.WeeklyMinutes,
            Now
        );
        var pace = QuotaFormatting.Color(status) ?? new PaceColor(113, 113, 122);
        using (var dot = new SolidBrush(Color.FromArgb(pace.Red, pace.Green, pace.Blue)))
        {
            graphics.FillEllipse(dot, 190, y + 6, 8, 8);
        }

        var comparison = window.UsedPercent <= status.OnTrackPercent ? "≤" : ">";
        var reset = window.ResetsAt!.Value.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
        var title =
            $"{label}  {QuotaFormatting.Percent(window.UsedPercent)} ({comparison}{QuotaFormatting.Percent(status.OnTrackPercent)}) · resets {reset}";
        DrawText(graphics, title, 213, y, Color.FromArgb(30, 30, 30));
    }

    private static void DrawTaskbar(Graphics graphics)
    {
        using (var taskbar = new SolidBrush(Color.FromArgb(225, 20, 23, 31)))
        {
            graphics.FillRectangle(taskbar, 0, 390, Width, 52);
        }
        using var windowsFont = new Font("Segoe UI Symbol", 22, FontStyle.Regular, GraphicsUnit.Pixel);
        using var white = new SolidBrush(Color.White);
        graphics.DrawString("⊞", windowsFont, white, 24, 401);

        var visual = TrayIconRenderer.ForQuota(Fixture);
        using var icon = TrayIconRenderer.Render(visual, 32, updateAvailable: true);
        graphics.DrawImage(icon, new Rectangle(616, 400, 32, 32));
        using var clockFont = new Font("Segoe UI", 12, FontStyle.Regular, GraphicsUnit.Pixel);
        graphics.DrawString("12:23 PM", clockFont, white, 657, 399);
        graphics.DrawString("8/28/2026", clockFont, white, 657, 416);
    }

    private static void DrawText(Graphics graphics, string value, float x, float y, Color color)
    {
        using var font = new Font("Segoe UI", 16, FontStyle.Regular, GraphicsUnit.Pixel);
        using var brush = new SolidBrush(color);
        graphics.DrawString(value, font, brush, x, y);
    }

    private static void Separator(Graphics graphics, float y)
    {
        using var pen = new Pen(Color.FromArgb(214, 214, 214), 1);
        graphics.DrawLine(pen, 180, y, 685, y);
    }

    private static GraphicsPath RoundedRectangle(RectangleF bounds, float radius)
    {
        var diameter = radius * 2;
        var path = new GraphicsPath();
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}
