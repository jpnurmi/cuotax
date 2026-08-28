// SPDX-License-Identifier: MIT

using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;

namespace CuotaX;

internal sealed record TrayIconVisual(string Label, Color Background, Color Foreground);

internal static class TrayIconRenderer
{
    private static readonly Color Exhausted = Color.FromArgb(185, 28, 28);
    private static readonly Color Unavailable = Color.FromArgb(82, 82, 91);
    private static readonly Color Loading = Color.FromArgb(113, 113, 122);

    internal static TrayIconVisual ForQuota(Quota quota)
    {
        var highest = quota.HighestPercent ?? 0;
        if (highest >= 100)
        {
            return new TrayIconVisual("×", Exhausted, Color.White);
        }

        var status = quota.Status();
        var pace = QuotaFormatting.Color(status) ?? new PaceColor(113, 113, 122);
        var background = Color.FromArgb(pace.Red, pace.Green, pace.Blue);
        var label = Math.Min(
            99,
            (int)Math.Round(
                QuotaFormatting.DisplayPercent(highest),
                MidpointRounding.AwayFromZero
            )
        ).ToString();
        return new TrayIconVisual(label, background, Foreground(background));
    }

    internal static TrayIconVisual Error() => new("!", Unavailable, Color.White);

    internal static TrayIconVisual LoadingState() => new("…", Loading, Color.White);

    internal static Icon Create(TrayIconVisual visual, bool updateAvailable = false)
    {
        using var bitmap = Render(visual, 32, updateAvailable);
        var handle = bitmap.GetHicon();
        try
        {
            using var icon = Icon.FromHandle(handle);
            return (Icon)icon.Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    internal static Bitmap Render(TrayIconVisual visual, int size, bool updateAvailable = false)
    {
        var bitmap = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.Transparent);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;

        var inset = Math.Max(1, size / 16f);
        var bounds = new RectangleF(inset, inset, size - 2 * inset, size - 2 * inset);
        using var path = RoundedRectangle(bounds, size * 0.22f);
        using var brush = new SolidBrush(visual.Background);
        graphics.FillPath(brush, path);

        using var border = new Pen(Color.FromArgb(55, Color.Black), Math.Max(1, size / 24f));
        graphics.DrawPath(border, path);

        var fontSize = visual.Label.Length > 1 ? size * 0.49f : size * 0.58f;
        using var font = new Font("Segoe UI", fontSize, FontStyle.Bold, GraphicsUnit.Pixel);
        using var textBrush = new SolidBrush(visual.Foreground);
        using var format = new StringFormat
        {
            Alignment = StringAlignment.Center,
            LineAlignment = StringAlignment.Center,
            FormatFlags = StringFormatFlags.NoWrap,
        };
        graphics.DrawString(visual.Label, font, textBrush, bounds, format);

        if (updateAvailable)
        {
            var badgeSize = size * 5f / 16;
            var badgeBounds = new RectangleF(0, size - badgeSize, badgeSize, badgeSize);
            using var badge = new SolidBrush(Color.FromArgb(22, 136, 248));
            graphics.FillEllipse(badge, badgeBounds);
        }
        return bitmap;
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

    private static Color Foreground(Color background)
    {
        static double Linear(byte component)
        {
            var value = component / 255d;
            return value <= 0.04045 ? value / 12.92 : Math.Pow((value + 0.055) / 1.055, 2.4);
        }

        var luminance = 0.2126 * Linear(background.R)
            + 0.7152 * Linear(background.G)
            + 0.0722 * Linear(background.B);
        return luminance > 0.42 ? Color.Black : Color.White;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(nint handle);
}
