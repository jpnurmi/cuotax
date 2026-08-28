// SPDX-License-Identifier: MIT

using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace CuotaX;

internal sealed class TrayApplicationContext : ApplicationContext
{
    private static readonly TimeSpan RefreshInterval = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan OpenRefreshAge = TimeSpan.FromMinutes(1);
    private static readonly TimeSpan UpdateInterval = TimeSpan.FromDays(1);

    private readonly CodexClient _client = new();
    private readonly UpdateChecker _updateChecker = new();
    private readonly ContextMenuStrip _menu = new();
    private readonly Form _menuOwner = new()
    {
        FormBorderStyle = FormBorderStyle.None,
        Opacity = 0,
        ShowInTaskbar = false,
        Size = new Size(1, 1),
        StartPosition = FormStartPosition.Manual,
    };
    private readonly NotifyIcon _notifyIcon = new();
    private readonly System.Windows.Forms.Timer _timer = new();
    private readonly System.Windows.Forms.Timer _updateTimer = new();
    private readonly CancellationTokenSource _cancellation = new();
    private readonly SynchronizationContext _uiContext;
    private Icon? _icon;
    private Quota? _quota;
    private BackendException? _error;
    private BackendException? _startupError;
    private bool _refreshing;
    private bool _queued;
    private bool _started;
    private bool _updateAvailable;
    private bool _disposed;

    internal TrayApplicationContext(bool registerStartup)
    {
        _uiContext = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        _menu.Opening += MenuOpening;
        _menu.Closed += MenuClosed;
        _notifyIcon.ContextMenuStrip = _menu;
        _notifyIcon.MouseClick += NotifyIconMouseClick;
        _notifyIcon.Visible = true;

        _timer.Interval = (int)RefreshInterval.TotalMilliseconds;
        _timer.Tick += (_, _) => _ = RefreshAsync();
        _timer.Start();
        _updateTimer.Interval = (int)UpdateInterval.TotalMilliseconds;
        _updateTimer.Tick += (_, _) => _ = CheckForUpdatesAsync();
        _updateTimer.Start();
        SystemEvents.PowerModeChanged += PowerModeChanged;

        if (registerStartup)
        {
            try
            {
                StartupRegistration.Register();
            }
            catch (Exception error)
            {
                _startupError = new BackendException("Could not register startup", error.Message);
            }
        }

        Render();
        Application.Idle += Start;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _disposed = true;
            SystemEvents.PowerModeChanged -= PowerModeChanged;
            Application.Idle -= Start;
            _cancellation.Cancel();
            _timer.Dispose();
            _updateTimer.Dispose();
            _updateChecker.Dispose();
            _notifyIcon.Visible = false;
            _notifyIcon.Dispose();
            _menu.Dispose();
            _menuOwner.Dispose();
            _icon?.Dispose();
            _cancellation.Dispose();
        }

        base.Dispose(disposing);
    }

    private void Start(object? sender, EventArgs eventArgs)
    {
        if (_started)
        {
            return;
        }

        _started = true;
        Application.Idle -= Start;
        _ = RefreshAsync();
        _ = CheckForUpdatesAsync();
    }

    private void PowerModeChanged(object sender, PowerModeChangedEventArgs eventArgs)
    {
        if (eventArgs.Mode != PowerModes.Resume)
        {
            return;
        }

        _uiContext.Post(
            _ =>
            {
                if (_disposed)
                {
                    return;
                }
                _ = RefreshAsync();
                _ = CheckForUpdatesAsync();
            },
            null
        );
    }

    private void MenuOpening(object? sender, CancelEventArgs eventArgs)
    {
        RenderMenu();
        if (_quota is null || DateTimeOffset.Now - _quota.UpdatedAt >= OpenRefreshAge)
        {
            _ = RefreshAsync();
        }
    }

    private void NotifyIconMouseClick(object? sender, MouseEventArgs eventArgs)
    {
        if (eventArgs.Button == MouseButtons.Left)
        {
            _menuOwner.Location = Cursor.Position;
            _menuOwner.Show();
            SetForegroundWindow(_menuOwner.Handle);
            _menu.Show(Cursor.Position);
        }
    }

    private void MenuClosed(object? sender, ToolStripDropDownClosedEventArgs eventArgs)
    {
        if (_menuOwner.Visible)
        {
            PostMessage(_menuOwner.Handle, 0, nint.Zero, nint.Zero);
            _menuOwner.Hide();
        }
    }

    private async Task RefreshAsync()
    {
        if (_refreshing)
        {
            _queued = true;
            return;
        }

        _refreshing = true;
        try
        {
            _quota = await _client.ReadQuotaAsync(_cancellation.Token);
            _error = null;
        }
        catch (BackendException error)
        {
            _error = error;
        }
        catch (OperationCanceledException) when (_cancellation.IsCancellationRequested)
        {
            return;
        }
        catch (Exception error)
        {
            _error = new BackendException("Codex quota request failed", error.Message);
        }
        finally
        {
            _refreshing = false;
            if (!_disposed)
            {
                Render();
                if (_queued)
                {
                    _queued = false;
                    _ = RefreshAsync();
                }
            }
        }
    }

    private async Task CheckForUpdatesAsync()
    {
        try
        {
            if (await _updateChecker.IsUpdateAvailableAsync(_cancellation.Token))
            {
                if (_updateAvailable)
                {
                    return;
                }
                _updateAvailable = true;
                Render();
            }
        }
        catch (OperationCanceledException) when (_cancellation.IsCancellationRequested)
        {
        }
        catch
        {
            // Update checks are best-effort and should never disturb quota reporting.
        }
    }

    private void Render()
    {
        var visual = _quota is not null
            ? TrayIconRenderer.ForQuota(_quota)
            : _error is not null || _startupError is not null
                ? TrayIconRenderer.Error()
                : TrayIconRenderer.LoadingState();
        var icon = TrayIconRenderer.Create(visual, _updateAvailable);
        var previous = _icon;
        _icon = icon;
        _notifyIcon.Icon = icon;
        previous?.Dispose();

        _notifyIcon.Text = Tooltip();
        if (!_menu.Visible)
        {
            RenderMenu();
        }
    }

    private string Tooltip()
    {
        if (_quota is not null)
        {
            var percent = QuotaFormatting.Percent(_quota.HighestPercent);
            var update = _updateAvailable ? ", update available" : string.Empty;
            return Shorten(
                $"CuotaX — {percent} used, {_quota.Status().PaceLabel.ToLowerInvariant()}{update}"
            );
        }

        var error = _error ?? _startupError;
        var label = error is null ? "CuotaX — loading" : $"CuotaX unavailable — {error.Message}";
        return Shorten(label + (_updateAvailable ? ", update available" : string.Empty));
    }

    private void RenderMenu()
    {
        var previousItems = _menu.Items.Cast<ToolStripItem>().ToArray();
        _menu.Items.Clear();
        foreach (var item in previousItems)
        {
            item.Dispose();
        }

        if (_quota is not null)
        {
            AddWindow("5-hour", _quota.FiveHour, fiveHour: true);
            AddWindow("Weekly", _quota.Weekly, fiveHour: false);
            if (_error is not null)
            {
                _menu.Items.Add(new ToolStripSeparator());
                AddInfo("Refresh failed · showing previous data");
                AddInfo(_error.Diagnostic);
            }
            if (_startupError is not null)
            {
                _menu.Items.Add(new ToolStripSeparator());
                AddInfo(_startupError.Message);
                AddInfo(_startupError.Diagnostic);
            }
            _menu.Items.Add(new ToolStripSeparator());
            AddInfo($"Updated {QuotaFormatting.Time(_quota.UpdatedAt)}");
        }
        else if (_error is not null || _startupError is not null)
        {
            var error = _error ?? _startupError!;
            AddInfo(error.Message);
            AddInfo(error.Diagnostic);
        }
        else
        {
            AddInfo("Loading Codex quota…");
        }

        _menu.Items.Add(new ToolStripSeparator());
        var refresh = new ToolStripMenuItem("Refresh");
        refresh.Click += (_, _) => _ = RefreshAsync();
        _menu.Items.Add(refresh);

        _menu.Items.Add(new ToolStripSeparator());
        var quit = new ToolStripMenuItem("Quit CuotaX");
        quit.Click += (_, _) => ExitThread();
        _menu.Items.Add(quit);
    }

    private void AddWindow(string label, QuotaWindow? window, bool fiveHour)
    {
        if (window is null)
        {
            AddInfo($"{label}  —");
            return;
        }

        var status = Quota.StatusFor(
            window,
            fiveHour ? "5-hour" : "weekly",
            fiveHour ? QuotaFormatting.FiveHourMinutes : QuotaFormatting.WeeklyMinutes
        );
        var reference = status.OnTrackPercent is null
            ? string.Empty
            : $" ({(status.Level == QuotaLevel.Normal ? "≤" : ">")}{QuotaFormatting.Percent(status.OnTrackPercent)})";
        AddInfo(
            $"{label}  {QuotaFormatting.Percent(window.UsedPercent)}{reference} · {QuotaFormatting.Reset(window.ResetsAt)}"
        );
    }

    private void AddInfo(string text)
    {
        _menu.Items.Add(new ToolStripMenuItem(text) { Enabled = false });
    }

    private static string Shorten(string value) => value.Length <= 127 ? value : value[..127];

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(nint window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(nint window, uint message, nint wParam, nint lParam);
}
