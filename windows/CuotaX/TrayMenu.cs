// SPDX-License-Identifier: MIT

using System.ComponentModel;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace CuotaX;

internal sealed class TrayMenu : ContextMenuStrip
{
    internal TrayMenu()
    {
        Renderer = new MenuRenderer();
    }

    protected override Padding DefaultPadding
    {
        get
        {
            var padding = base.DefaultPadding;
            padding.Top = padding.Bottom = LogicalToDeviceUnits(6);
            return padding;
        }
    }

    protected override void OnOpening(CancelEventArgs eventArgs)
    {
        // refresh the palette after system theme changes
        Application.SetColorMode(SystemColorMode.System);
        base.OnOpening(eventArgs);
    }

    protected override void OnItemAdded(ToolStripItemEventArgs eventArgs)
    {
        if (eventArgs.Item is ToolStripMenuItem item)
        {
            var padding = LogicalToDeviceUnits(4);
            item.Padding = new Padding(0, padding, 0, padding);
        }
        base.OnItemAdded(eventArgs);
    }

    protected override void OnHandleCreated(EventArgs eventArgs)
    {
        base.OnHandleCreated(eventArgs);
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
        {
            const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
            const int DWMWCP_ROUNDSMALL = 3;
            var preference = DWMWCP_ROUNDSMALL;
            DwmSetWindowAttribute(Handle, DWMWA_WINDOW_CORNER_PREFERENCE, ref preference, sizeof(int));
        }
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(nint window, int attribute, ref int value, int size);

    private sealed class MenuRenderer : ToolStripSystemRenderer
    {
        protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs eventArgs)
        {
            if (SystemInformation.HighContrast)
            {
                base.OnRenderMenuItemBackground(eventArgs);
                return;
            }
            if (!eventArgs.Item.Enabled || !eventArgs.Item.Selected)
            {
                return;
            }

            var inset = eventArgs.ToolStrip?.LogicalToDeviceUnits(4) ?? 4;
            var radius = eventArgs.ToolStrip?.LogicalToDeviceUnits(4) ?? 4;
            var bounds = new Rectangle(Point.Empty, eventArgs.Item.Size);
            bounds.Inflate(-inset, -inset / 2);
            var state = eventArgs.Graphics.Save();
            eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using var brush = new SolidBrush(Color.FromArgb(24, SystemColors.MenuText));
            eventArgs.Graphics.FillRoundedRectangle(brush, bounds, new Size(radius, radius));
            eventArgs.Graphics.Restore(state);
        }

        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs eventArgs)
        {
            eventArgs.TextRectangle = new Rectangle(eventArgs.TextRectangle.X, 0,
                eventArgs.TextRectangle.Width, eventArgs.Item.Height);
            eventArgs.TextFormat = (eventArgs.TextFormat & ~TextFormatFlags.Bottom)
                | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine;

            if (SystemInformation.HighContrast)
            {
                base.OnRenderItemText(eventArgs);
                return;
            }

            TextRenderer.DrawText(eventArgs.Graphics, eventArgs.Text, eventArgs.TextFont,
                eventArgs.TextRectangle, eventArgs.Item.Enabled ? SystemColors.MenuText : SystemColors.GrayText,
                eventArgs.TextFormat);
        }

        protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs eventArgs)
        {
            if (SystemInformation.HighContrast || eventArgs.Vertical)
            {
                base.OnRenderSeparator(eventArgs);
                return;
            }

            var inset = eventArgs.ToolStrip?.LogicalToDeviceUnits(8) ?? 8;
            var y = eventArgs.Item.Height / 2;
            using var pen = new Pen(Color.FromArgb(40, SystemColors.MenuText));
            eventArgs.Graphics.DrawLine(pen, inset, y, eventArgs.Item.Width - inset, y);
        }

        protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs eventArgs)
        {
            if (SystemInformation.HighContrast)
            {
                base.OnRenderItemCheck(eventArgs);
                return;
            }

            var scale = (eventArgs.ToolStrip?.DeviceDpi ?? 96) / 96f;
            var bounds = eventArgs.ImageRectangle;
            var x = bounds.Left + bounds.Width / 2f;
            if (eventArgs.ToolStrip is { } menu)
            {
                var rightToLeft = eventArgs.Item.RightToLeft == RightToLeft.Yes;
                var gutter = rightToLeft ? menu.Padding.Right : menu.Padding.Left;
                x = (4 * scale + gutter) / 2f;
                if (rightToLeft)
                {
                    x = eventArgs.Item.Width - x;
                }
            }
            var y = bounds.Top + bounds.Height / 2f;
            var state = eventArgs.Graphics.Save();
            eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using var pen = new Pen(eventArgs.Item.Enabled ? SystemColors.MenuText : SystemColors.GrayText, 1.5f * scale)
            {
                StartCap = LineCap.Round,
                EndCap = LineCap.Round,
                LineJoin = LineJoin.Round,
            };
            eventArgs.Graphics.DrawLines(pen,
            [
                new PointF(x - 4.5f * scale, y),
                new PointF(x - 1.5f * scale, y + 3 * scale),
                new PointF(x + 4.5f * scale, y - 3.5f * scale),
            ]);
            eventArgs.Graphics.Restore(state);
        }
    }
}
