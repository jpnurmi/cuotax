// SPDX-License-Identifier: MIT

using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace CuotaX;

internal static class ScreenshotRenderer
{
    private const int Width = 740;
    private const int Height = 532;
    private static readonly DateTimeOffset Now = new(2026, 8, 28, 12, 23, 0, TimeSpan.Zero);
    private static readonly Quota Fixture = new(
        new QuotaWindow(68, new DateTimeOffset(2026, 8, 28, 14, 53, 0, TimeSpan.Zero)),
        new QuotaWindow(42, new DateTimeOffset(2026, 9, 1, 16, 13, 0, TimeSpan.Zero)),
        Now
    );
    private static readonly Quota ClaudeFixture = new(
        new QuotaWindow(26, new DateTimeOffset(2026, 8, 28, 15, 23, 0, TimeSpan.Zero)),
        new QuotaWindow(6, new DateTimeOffset(2026, 9, 2, 12, 23, 0, TimeSpan.Zero)),
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
        using var font = new Font("Segoe UI", 16, FontStyle.Regular, GraphicsUnit.Pixel);
        using var menu = new TrayMenu { Font = font };
        menu.Items.Add(new ToolStripMenuItem("Codex") { Checked = true });
        menu.AddWindow("5-hour", Fixture.FiveHour, fiveHour: true, Now);
        menu.AddWindow("Weekly", Fixture.Weekly, fiveHour: false, Now);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Claude") { Checked = true });
        menu.AddWindow("5-hour", ClaudeFixture.FiveHour, fiveHour: true, Now);
        menu.AddWindow("Weekly", ClaudeFixture.Weekly, fiveHour: false, Now);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem($"Refresh ({QuotaFormatting.Time(Fixture.UpdatedAt)})"));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Quit CuotaX"));
        foreach (ToolStripItem item in menu.Items)
        {
            if (item is ToolStripMenuItem)
            {
                item.Padding = new Padding(0, 13, 0, 13);
            }
        }
        menu.AutoSize = false;
        menu.Size = new Size(535, 434);
        using var image = new Bitmap(menu.Width, menu.Height, PixelFormat.Format32bppArgb);
        menu.DrawToBitmap(image, new Rectangle(Point.Empty, menu.Size));

        var bounds = new Rectangle(165, 35, menu.Width, menu.Height);
        const int radius = 10;
        using (var shadowPath = RoundedRectangle(
            new RectangleF(bounds.X + 4, bounds.Y + 5, bounds.Width, bounds.Height),
            radius
        ))
        using (var shadow = new SolidBrush(Color.FromArgb(72, 0, 0, 0)))
        {
            graphics.FillPath(shadow, shadowPath);
        }
        using (var path = RoundedRectangle(bounds, radius))
        using (var texture = new TextureBrush(image, WrapMode.Clamp))
        {
            texture.TranslateTransform(bounds.X, bounds.Y);
            graphics.FillPath(texture, path);
        }
    }

    private static void DrawTaskbar(Graphics graphics)
    {
        using (var taskbar = new SolidBrush(Color.FromArgb(225, 20, 23, 31)))
        {
            graphics.FillRectangle(taskbar, 0, 480, Width, 52);
        }
        using var windowsFont = new Font("Segoe UI Symbol", 22, FontStyle.Regular, GraphicsUnit.Pixel);
        using var white = new SolidBrush(Color.White);
        graphics.DrawString("⊞", windowsFont, white, 24, 491);

        var visuals = new[]
        {
            TrayIconRenderer.ForQuota(Fixture, Now, weeklyOnly: true),
            TrayIconRenderer.ForQuota(ClaudeFixture, Now, weeklyOnly: true),
        };
        using var icon = TrayIconRenderer.Render(visuals, 32, updateAvailable: false);
        graphics.DrawImage(icon, new Rectangle(616, 490, 32, 32));
        using var clockFont = new Font("Segoe UI", 12, FontStyle.Regular, GraphicsUnit.Pixel);
        graphics.DrawString("12:23 PM", clockFont, white, 657, 489);
        graphics.DrawString("8/28/2026", clockFont, white, 657, 506);
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
