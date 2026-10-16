// SPDX-License-Identifier: MIT

using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;

namespace CuotaX;

internal sealed record TrayIconVisual(string Label, Color Background, Color Foreground);

internal static class TrayIconRenderer
{
    private static readonly Color Exhausted = Color.FromArgb(185, 28, 28);
    private static readonly Color Unavailable = Color.FromArgb(82, 82, 91);
    private static readonly Color Loading = Color.FromArgb(113, 113, 122);

    internal static TrayIconVisual ForQuota(Quota quota, DateTimeOffset? now = null, bool weeklyOnly = false)
    {
        var highest = quota.HighestPercent ?? 0;
        if (highest >= 100)
        {
            return new TrayIconVisual("×", Exhausted, Color.White);
        }

        var status = quota.Status(now);
        var pace = QuotaFormatting.Color(status) ?? new PaceColor(113, 113, 122);
        var background = Color.FromArgb(pace.Red, pace.Green, pace.Blue);
        var percent = weeklyOnly ? quota.Weekly?.UsedPercent : highest;
        var label = percent is null ? "-" : Math.Min(
            99,
            (int)Math.Round(
                QuotaFormatting.DisplayPercent(percent.Value),
                MidpointRounding.AwayFromZero
            )
        ).ToString();
        if (weeklyOnly && percent is not null)
        {
            label += "%";
        }
        return new TrayIconVisual(label, background, Foreground(background));
    }

    internal static TrayIconVisual Error() => new("!", Unavailable, Color.White);

    internal static TrayIconVisual LoadingState() => new("…", Loading, Color.White);

    internal static Icon Create(TrayIconVisual visual, bool updateAvailable = false)
        => Create([visual], updateAvailable);

    internal static Icon Create(IReadOnlyList<TrayIconVisual> visuals, bool updateAvailable = false)
    {
        using var bitmap = Render(visuals, SystemInformation.SmallIconSize.Width, updateAvailable);
        using var png = new MemoryStream();
        bitmap.Save(png, ImageFormat.Png);
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        const uint offset = 6 + 16;
        // one PNG frame in an ICO container preserves antialiased alpha
        writer.Write((ushort)0);
        writer.Write((ushort)1);
        writer.Write((ushort)1);
        writer.Write((byte)bitmap.Width);
        writer.Write((byte)bitmap.Height);
        writer.Write((byte)0);
        writer.Write((byte)0);
        writer.Write((ushort)1);
        writer.Write((ushort)32);
        writer.Write((uint)png.Length);
        writer.Write(offset);
        writer.Write(png.ToArray());
        stream.Position = 0;
        return new Icon(stream, bitmap.Size);
    }

    internal static Bitmap Render(TrayIconVisual visual, int size, bool updateAvailable = false)
        => Render([visual], size, updateAvailable);

    internal static Bitmap Render(IReadOnlyList<TrayIconVisual> visuals, int size, bool updateAvailable = false)
    {
        if (visuals.Count is < 1 or > 2)
        {
            throw new ArgumentException("A tray icon needs one or two rows", nameof(visuals));
        }
        var bitmap = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.Transparent);

        var stacked = visuals.Count > 1;
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        var inset = Math.Max(1, size / 16f);
        var bounds = stacked
            ? new RectangleF(0, 0, size, size)
            : new RectangleF(inset, inset, size - 2 * inset, size - 2 * inset);
        if (!stacked)
        {
            using var path = RoundedRectangle(bounds, size * 0.22f);
            using var brush = new SolidBrush(visuals[0].Background);
            graphics.FillPath(brush, path);
            using var border = new Pen(Color.FromArgb(55, Color.Black), Math.Max(1, size / 24f));
            graphics.DrawPath(border, path);
        }
        graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        for (var row = 0; row < visuals.Count; row++)
        {
            var visual = visuals[row];
            var rowBounds = stacked
                ? new RectangleF(bounds.X, bounds.Y + row * bounds.Height / 2, bounds.Width, bounds.Height / 2)
                : bounds;
            if (stacked)
            {
                using var glyph = new GraphicsPath();
                using var family = new FontFamily("Segoe UI");
                // a fixed reference keeps both rows and changing percentages at the same font size
                const string referenceLabel = "99%";
                glyph.AddString(referenceLabel, family, (int)FontStyle.Regular, size, PointF.Empty, StringFormat.GenericTypographic);
                var referenceBounds = glyph.GetBounds();
                using var reference = new Font(family, size, FontStyle.Regular, GraphicsUnit.Pixel);
                var width = graphics.MeasureString(referenceLabel, reference, 1000, StringFormat.GenericTypographic).Width;
                var scale = Math.Min(rowBounds.Width / width, (rowBounds.Height - size / 32f) / referenceBounds.Height);
                glyph.Reset();
                glyph.AddString(visual.Label, family, (int)FontStyle.Regular, size, PointF.Empty, StringFormat.GenericTypographic);
                var glyphBounds = glyph.GetBounds();
                var origin = new PointF(
                    rowBounds.X + (rowBounds.Width - glyphBounds.Width * scale) / 2 - glyphBounds.X * scale,
                    rowBounds.Y + (rowBounds.Height - glyphBounds.Height * scale) / 2 - glyphBounds.Y * scale
                );
                using var text = new Font(family, size * scale, FontStyle.Regular, GraphicsUnit.Pixel);
                using var brush = new SolidBrush(visual.Background);
                graphics.DrawString(visual.Label, text, brush, origin, StringFormat.GenericTypographic);
                continue;
            }

            var fontSize = visual.Label.Length > 1 ? size * 0.49f : size * 0.58f;
            using var font = new Font("Segoe UI", fontSize, FontStyle.Bold, GraphicsUnit.Pixel);
            using var textBrush = new SolidBrush(visual.Foreground);
            using var format = new StringFormat
            {
                Alignment = StringAlignment.Center,
                LineAlignment = StringAlignment.Center,
                FormatFlags = StringFormatFlags.NoWrap,
            };
            graphics.DrawString(visual.Label, font, textBrush, rowBounds, format);
        }

        if (updateAvailable)
        {
            var badgeSize = size * (stacked ? 3f : 5f) / 16;
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
}
