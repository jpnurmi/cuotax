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
    private readonly ClaudeClient _claudeClient = new();
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
    private readonly Dictionary<Provider, ProviderState> _providers = new();
    private readonly System.Windows.Forms.Timer _timer = new();
    private readonly System.Windows.Forms.Timer _updateTimer = new();
    private readonly CancellationTokenSource _cancellation = new();
    private readonly SynchronizationContext _uiContext;
    private BackendException? _startupError;
    private bool _started;
    private bool _updateAvailable;
    private bool _disposed;

    internal TrayApplicationContext(bool registerStartup)
    {
        _uiContext = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        _menu.Opening += MenuOpening;
        _menu.Closed += MenuClosed;
        foreach (var provider in LoadProviders())
        {
            AddProvider(provider);
        }

        _timer.Interval = (int)RefreshInterval.TotalMilliseconds;
        _timer.Tick += (_, _) =>
        {
            foreach (var state in _providers.Values)
            {
                if (state.Provider != Provider.Claude || state.Quota is null
                    || DateTimeOffset.Now - state.Quota.UpdatedAt >= OpenRefreshAge)
                {
                    _ = RefreshAsync(state, queue: false);
                }
            }
        };
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
            _claudeClient.Dispose();
            foreach (var state in _providers.Values)
            {
                state.Dispose();
            }
            _providers.Clear();
            _menu.Dispose();
            _menuOwner.Dispose();
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
        Refresh();
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
                Refresh();
                _ = CheckForUpdatesAsync();
            },
            null
        );
    }

    private void MenuOpening(object? sender, CancelEventArgs eventArgs)
    {
        RenderMenu();
        foreach (var state in _providers.Values)
        {
            if (state.Quota is null || DateTimeOffset.Now - state.Quota.UpdatedAt >= OpenRefreshAge)
            {
                _ = RefreshAsync(state);
            }
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

    private void Refresh()
    {
        foreach (var state in _providers.Values)
        {
            _ = RefreshAsync(state);
        }
    }

    private bool IsActive(ProviderState state) => !_disposed
        && _providers.TryGetValue(state.Provider, out var current) && current == state;

    private async Task RefreshAsync(ProviderState state, bool queue = true)
    {
        if (!IsActive(state))
        {
            return;
        }
        if (state.Provider == Provider.Claude)
        {
            _claudeClient.WatchUsage(() => _uiContext.Post(
                _ =>
                {
                    if (IsActive(state))
                    {
                        _ = RefreshAsync(state);
                    }
                },
                null
            ));
        }
        if (state.Refreshing)
        {
            state.Queued |= queue;
            return;
        }

        state.Refreshing = true;
        var provider = state.Provider;
        try
        {
            var quota = provider == Provider.Codex
                ? await _client.ReadQuotaAsync(state.Cancellation.Token)
                : await _claudeClient.ReadQuotaAsync(state.Cancellation.Token);
            if (!IsActive(state))
            {
                return;
            }
            var reset = Quota.ResetMessage(state.Quota, quota);
            state.Quota = quota;
            state.Error = null;
            ScheduleResetRefresh(state, quota);
            if (reset is not null)
            {
                state.NotifyIcon.ShowBalloonTip(5000, $"{provider} quota reset", reset, ToolTipIcon.Info);
            }
        }
        catch (BackendException error)
        {
            if (IsActive(state))
            {
                state.Error = error;
            }
        }
        catch (OperationCanceledException) when (state.Cancellation.IsCancellationRequested)
        {
            return;
        }
        catch (Exception error)
        {
            if (IsActive(state))
            {
                state.Error = new BackendException($"{provider} quota request failed", error.Message);
            }
        }
        finally
        {
            state.Refreshing = false;
            if (IsActive(state))
            {
                Render(state);
                if (state.Queued)
                {
                    state.Queued = false;
                    _ = RefreshAsync(state);
                }
            }
        }
    }

    private void ScheduleResetRefresh(ProviderState state, Quota quota)
    {
        state.ResetTimer.Stop();
        var expiry = state.Provider == Provider.Claude ? quota.UpdatedAt.AddMinutes(5) : (DateTimeOffset?)null;
        var next = new[] { quota.NextReset(), expiry }.Where(value => value is not null).Min();
        if (next is not { } reset)
        {
            return;
        }

        state.ResetTimer.Interval = Math.Max(
            1,
            (int)Math.Ceiling((reset - DateTimeOffset.Now).TotalMilliseconds)
        );
        state.ResetTimer.Start();
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

    private void Render(ProviderState? changed = null)
    {
        foreach (var state in _providers.Values)
        {
            if (changed is not null && state != changed)
            {
                continue;
            }
            var visual = state.Quota is not null
                ? TrayIconRenderer.ForQuota(state.Quota)
                : state.Error is not null || _startupError is not null
                    ? TrayIconRenderer.Error()
                    : TrayIconRenderer.LoadingState();
            var icon = TrayIconRenderer.Create(visual, _updateAvailable);
            var previous = state.Icon;
            state.Icon = icon;
            state.NotifyIcon.Icon = icon;
            state.NotifyIcon.Text = Tooltip(state);
            state.NotifyIcon.Visible = true;
            previous?.Dispose();
        }
        if (!_menu.Visible)
        {
            RenderMenu();
        }
    }

    private string Tooltip(ProviderState state)
    {
        if (state.Quota is { } quota)
        {
            var percent = QuotaFormatting.Percent(quota.HighestPercent);
            var update = _updateAvailable ? ", update available" : string.Empty;
            return Shorten(
                $"CuotaX — {state.Provider} {percent} used, {quota.Status().PaceLabel.ToLowerInvariant()}{update}"
            );
        }

        var error = state.Error ?? _startupError;
        var label = error is null ? $"CuotaX — {state.Provider} loading" : $"CuotaX {state.Provider} unavailable — {error.Message}";
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

        foreach (var provider in Enum.GetValues<Provider>())
        {
            _providers.TryGetValue(provider, out var state);
            var item = new ToolStripMenuItem(provider.ToString())
            {
                Checked = _providers.ContainsKey(provider),
                Enabled = !_providers.ContainsKey(provider) || _providers.Count > 1,
            };
            item.Click += (_, _) => ToggleProvider(provider);
            _menu.Items.Add(item);
            if (state is null)
            {
                _menu.Items.Add(new ToolStripSeparator());
                continue;
            }
            if (state.Quota is { } quota)
            {
                AddWindow("5-hour", quota.FiveHour, fiveHour: true);
                AddWindow("Weekly", quota.Weekly, fiveHour: false);
                if (quota.Fable is { } fable)
                {
                    AddWindow("Fable weekly", fable, fiveHour: false);
                }
                if (state.Error is { } error)
                {
                    AddInfo("Refresh failed · showing previous data");
                    AddInfo(error.Diagnostic);
                }
            }
            else if (state.Error is { } error)
            {
                AddInfo(error.Message);
                AddInfo(error.Diagnostic);
            }
            else
            {
                AddInfo($"Loading {provider} quota…");
            }
            _menu.Items.Add(new ToolStripSeparator());
        }
        if (_startupError is not null)
        {
            AddInfo(_startupError.Message);
            AddInfo(_startupError.Diagnostic);
            _menu.Items.Add(new ToolStripSeparator());
        }

        var updated = _providers.Values.Select(state => state.Quota?.UpdatedAt).Max();
        var refresh = new ToolStripMenuItem(
            updated is { } time ? $"Refresh ({QuotaFormatting.Time(time)})" : "Refresh"
        );
        refresh.Click += (_, _) => Refresh();
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
            $"{label}  {QuotaFormatting.Percent(window.UsedPercent)}{reference} · {QuotaFormatting.Reset(window.ResetsAt, includeDate: !fiveHour)}"
        );
    }

    private void AddInfo(string text)
    {
        _menu.Items.Add(new ToolStripMenuItem(text) { Enabled = false });
    }

    private void AddProvider(Provider provider)
    {
        var state = new ProviderState(provider);
        state.NotifyIcon.ContextMenuStrip = _menu;
        state.NotifyIcon.MouseClick += NotifyIconMouseClick;
        state.ResetTimer.Tick += (_, _) =>
        {
            state.ResetTimer.Stop();
            _ = RefreshAsync(state, queue: false);
        };
        _providers.Add(provider, state);
    }

    private void ToggleProvider(Provider provider)
    {
        if (_providers.ContainsKey(provider))
        {
            if (_providers.Count == 1)
            {
                return;
            }
            _providers.Remove(provider, out var state);
            state!.Dispose();
            if (provider == Provider.Claude)
            {
                _claudeClient.StopWatching();
            }
        }
        else
        {
            AddProvider(provider);
            _ = RefreshAsync(_providers[provider]);
        }
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(@"Software\CuotaX");
            key.SetValue("Providers", Enum.GetValues<Provider>().Where(_providers.ContainsKey)
                .Select(value => value.ToString()).ToArray(), RegistryValueKind.MultiString);
        }
        catch (Exception error)
        {
            _startupError = new BackendException("Could not save provider", error.Message);
        }
        Render();
    }

    private static HashSet<Provider> LoadProviders()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\CuotaX");
            if (key?.GetValue("Providers") is string[] values)
            {
                var providers = values.Select(value => Enum.TryParse<Provider>(value, out var provider)
                    && Enum.IsDefined(provider) ? provider : (Provider?)null)
                    .Where(value => value is not null).Select(value => value!.Value).ToHashSet();
                if (providers.Count > 0)
                {
                    return providers;
                }
            }
            return Enum.TryParse<Provider>(key?.GetValue("Provider") as string, out var provider)
                && Enum.IsDefined(provider) ? [provider] : [Provider.Codex];
        }
        catch
        {
            return [Provider.Codex];
        }
    }

    private sealed class ProviderState(Provider provider) : IDisposable
    {
        internal Provider Provider { get; } = provider;
        internal NotifyIcon NotifyIcon { get; } = new();
        internal System.Windows.Forms.Timer ResetTimer { get; } = new();
        internal CancellationTokenSource Cancellation { get; } = new();
        internal Icon? Icon { get; set; }
        internal Quota? Quota { get; set; }
        internal BackendException? Error { get; set; }
        internal bool Refreshing { get; set; }
        internal bool Queued { get; set; }

        public void Dispose()
        {
            Cancellation.Cancel();
            ResetTimer.Dispose();
            NotifyIcon.Visible = false;
            NotifyIcon.Dispose();
            Icon?.Dispose();
            Cancellation.Dispose();
        }
    }

    private static string Shorten(string value) => value.Length <= 127 ? value : value[..127];

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(nint window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(nint window, uint message, nint wParam, nint lParam);
}
