// SPDX-License-Identifier: MIT

using System.Drawing.Drawing2D;
using System.Globalization;
using System.Reflection;
using CuotaX;

if (args is ["--fixture", var fixture, ..])
{
    await RunFixture(fixture);
    return;
}

var tests = new List<(string Name, Func<Task> Run)>
{
    ("quota pacing", TestQuotaPacing),
    ("quota formatting", TestQuotaFormatting),
    ("reset notification", TestResetNotification),
    ("tray icon states", TestTrayIconStates),
    ("update comparison", TestUpdateComparison),
    ("app-server quota", TestAppServerQuota),
    ("app-server invalid reset", TestAppServerInvalidReset),
    ("app-server error", TestAppServerError),
    ("app-server timeout", TestAppServerTimeout),
};

if (Environment.GetEnvironmentVariable("CODEX_TEST_LIVE") == "1")
{
    tests.Add(("live app-server quota", TestLiveAppServerQuota));
}

foreach (var test in tests)
{
    await test.Run();
    Console.WriteLine($"pass: {test.Name}");
}

if (Environment.GetEnvironmentVariable("CUOTAX_ICON_PREVIEW") is { } preview)
{
    SavePreview(preview);
    Console.WriteLine($"preview: {preview}");
}

static Task TestQuotaPacing()
{
    var now = DateTimeOffset.FromUnixTimeSeconds(1_777_000_000);
    var quota = new Quota(
        new QuotaWindow(25, now.AddMinutes(150)),
        null,
        now
    );
    var status = quota.Status(now);
    Equal(QuotaLevel.Normal, status.Level);
    Equal(50d, status.OnTrackPercent);
    Equal(75d, status.RemainingPercent);
    Equal("5-hour", status.Window);
    Equal(
        status,
        Quota.StatusFor(quota.FiveHour, "5-hour", QuotaFormatting.FiveHourMinutes, now)
    );
    Equal(
        QuotaStatus.Unavailable,
        Quota.StatusFor(null, "5-hour", QuotaFormatting.FiveHourMinutes, now)
    );

    quota = new Quota(new QuotaWindow(80, now.AddMinutes(240)), null, now);
    status = quota.Status(now);
    Equal(QuotaLevel.Critical, status.Level);
    True(QuotaFormatting.Color(status) is { } color && color.Red > color.Green);
    return Task.CompletedTask;
}

static Task TestQuotaFormatting()
{
    Equal(100d, QuotaFormatting.DisplayPercent(131));
    Equal(0d, QuotaFormatting.DisplayPercent(-1));
    Equal(70d, QuotaFormatting.NormalizePercent(69.96));
    var previousCulture = CultureInfo.CurrentCulture;
    try
    {
        CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("sv-SE");
        Equal("42%", QuotaFormatting.Percent(42));
        Equal("42,5%", QuotaFormatting.Percent(42.5));
        var reset = new DateTimeOffset(
            new DateTime(2026, 9, 1, 13, 37, 0, DateTimeKind.Local)
        );
        Equal("Tue, Sep 1 13:37 (3d)", QuotaFormatting.Reset(reset, reset.AddDays(-3)));
        Equal("Tue, Sep 1 13:37 (7h)", QuotaFormatting.Reset(reset, reset.AddHours(-7)));
        Equal("Tue, Sep 1 13:37 (33m)", QuotaFormatting.Reset(reset, reset.AddMinutes(-33)));
        Equal("Tue, Sep 1 13:37", QuotaFormatting.Reset(reset, reset));
        Equal("reset unknown", QuotaFormatting.Reset(null));
    }
    finally
    {
        CultureInfo.CurrentCulture = previousCulture;
    }
    Equal(QuotaLevel.Warning, QuotaFormatting.Severity(70));
    Equal(QuotaLevel.Critical, QuotaFormatting.Severity(90));
    Equal(
        new PaceColor(54, 226, 54),
        QuotaFormatting.Color(new QuotaStatus(1, QuotaLevel.Normal, 40, 100, null))
    );
    Equal(
        new PaceColor(226, 140, 54),
        QuotaFormatting.Color(new QuotaStatus(1, QuotaLevel.Warning, 40, 60, null))
    );
    Equal(
        new PaceColor(226, 54, 54),
        QuotaFormatting.Color(new QuotaStatus(0, QuotaLevel.Critical, 40, 0, null))
    );
    Equal(
        new PaceColor(226, 140, 54),
        QuotaFormatting.Color(new QuotaStatus(1, QuotaLevel.Warning, null, 30, null))
    );
    foreach (var remainingPercent in new[] { double.NaN, double.PositiveInfinity, double.NegativeInfinity })
    {
        Equal<PaceColor?>(
            null,
            QuotaFormatting.Color(new QuotaStatus(1, QuotaLevel.Normal, 50, remainingPercent, null))
        );
    }
    return Task.CompletedTask;
}

static Task TestResetNotification()
{
    var before = DateTimeOffset.FromUnixTimeSeconds(1_777_000_000);
    var reset = before.AddMinutes(1);
    var after = reset.AddMinutes(1);
    var previous = new Quota(
        new QuotaWindow(42, reset),
        new QuotaWindow(7, reset),
        before
    );
    var current = new Quota(
        new QuotaWindow(0, after.AddHours(5)),
        new QuotaWindow(0, after.AddDays(7)),
        after
    );

    Equal<string?>(null, Quota.ResetMessage(null, current));
    Equal<string?>(
        null,
        Quota.ResetMessage(previous, current with { UpdatedAt = before.AddSeconds(30) })
    );
    Equal("5-hour and weekly quotas reset", Quota.ResetMessage(previous, current));
    Equal(
        "5-hour quota reset",
        Quota.ResetMessage(previous with { Weekly = null }, current)
    );
    Equal(
        "Weekly quota reset",
        Quota.ResetMessage(previous with { FiveHour = null }, current)
    );
    Equal<string?>(
        null,
        Quota.ResetMessage(
            new Quota(new QuotaWindow(42, before), null, before),
            current
        )
    );
    return Task.CompletedTask;
}

static Task TestTrayIconStates()
{
    var now = DateTimeOffset.FromUnixTimeSeconds(1_777_000_000);
    var quota = new Quota(new QuotaWindow(42, now.AddHours(2)), null, now);
    var normal = TrayIconRenderer.ForQuota(quota, now);
    Equal("42", normal.Label);
    var pace = QuotaFormatting.Color(quota.Status(now))!.Value;
    Equal(Color.FromArgb(pace.Red, pace.Green, pace.Blue), normal.Background);

    var nearlyFull = TrayIconRenderer.ForQuota(
        new Quota(new QuotaWindow(99.6, now.AddMinutes(1)), null, now),
        now
    );
    Equal("99", nearlyFull.Label);

    var midpoint = TrayIconRenderer.ForQuota(
        new Quota(new QuotaWindow(42.5, now.AddHours(2)), null, now),
        now
    );
    Equal("43", midpoint.Label);

    var exhausted = TrayIconRenderer.ForQuota(
        new Quota(new QuotaWindow(100, now.AddMinutes(1)), null, now),
        now
    );
    Equal("×", exhausted.Label);
    True(exhausted.Background.R > exhausted.Background.G);
    Equal("!", TrayIconRenderer.Error().Label);

    using var icon = TrayIconRenderer.Create(normal);
    True(icon.Handle != nint.Zero);
    using var update = TrayIconRenderer.Render(normal, 32, updateAvailable: true);
    var badge = update.GetPixel(5, 27);
    True(badge.B > badge.R && badge.B > badge.G);
    return Task.CompletedTask;
}

static Task TestUpdateComparison()
{
    True(UpdateChecker.HasUpdate("{\"ahead_by\":2}"));
    True(!UpdateChecker.HasUpdate("{\"ahead_by\":0}"));
    True(!UpdateChecker.HasUpdate("{\"ahead_by\":\"2\"}"));
    True(!UpdateChecker.HasUpdate("not json"));
    return Task.CompletedTask;
}

static async Task TestAppServerQuota()
{
    var quota = await Client("success").ReadQuotaAsync();
    Equal(42d, quota.FiveHour?.UsedPercent);
    Equal(7d, quota.Weekly?.UsedPercent);
}

static async Task TestAppServerError()
{
    try
    {
        _ = await Client("failure").ReadQuotaAsync();
        throw new Exception("Expected app-server failure");
    }
    catch (BackendException error)
    {
        Equal("Codex returned no quota", error.Message);
        Equal("fixture app-server failed", error.Diagnostic);
    }
}

static async Task TestAppServerInvalidReset()
{
    var quota = await Client("invalid-reset").ReadQuotaAsync();
    Equal(42d, quota.FiveHour?.UsedPercent);
    Equal(null, quota.FiveHour?.ResetsAt);
}

static async Task TestAppServerTimeout()
{
    try
    {
        _ = await Client("hang", TimeSpan.FromMilliseconds(100)).ReadQuotaAsync();
        throw new Exception("Expected app-server timeout");
    }
    catch (BackendException error)
    {
        Equal("Codex quota request timed out", error.Message);
    }
}

static async Task TestLiveAppServerQuota()
{
    var quota = await new CodexClient().ReadQuotaAsync();
    True(quota.FiveHour is not null || quota.Weekly is not null);
}

static CodexClient Client(string fixture, TimeSpan? timeout = null)
{
    var assembly = Assembly.GetExecutingAssembly().Location;
    var appHost = Path.ChangeExtension(assembly, ".exe");
    return new CodexClient(new CodexCommand(appHost, new[] { "--fixture", fixture }), timeout);
}

static async Task RunFixture(string fixture)
{
    for (var index = 0; index < 3; index++)
    {
        await Console.In.ReadLineAsync();
    }

    if (fixture == "success")
    {
        Console.WriteLine(
            """
            {"id":1,"result":{"rateLimits":{"primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":1777000000},"secondary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":1778000000}}}}
            """
        );
    }
    else if (fixture == "failure")
    {
        Console.Error.WriteLine("fixture app-server failed");
    }
    else if (fixture == "invalid-reset")
    {
        Console.WriteLine(
            """
            {"id":1,"result":{"rateLimits":{"primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":253402300800}}}}
            """
        );
    }
    else if (fixture == "hang")
    {
        await Task.Delay(TimeSpan.FromMinutes(1));
    }
}

static void SavePreview(string path)
{
    var now = DateTimeOffset.Now;
    var visuals = new[]
    {
        TrayIconRenderer.ForQuota(new Quota(new QuotaWindow(7, now.AddHours(4)), null, now)),
        TrayIconRenderer.ForQuota(new Quota(new QuotaWindow(42, now.AddHours(4)), null, now)),
        TrayIconRenderer.ForQuota(new Quota(new QuotaWindow(82, now.AddHours(4)), null, now)),
        TrayIconRenderer.ForQuota(new Quota(new QuotaWindow(100, now.AddHours(4)), null, now)),
        TrayIconRenderer.Error(),
    };
    const int cellSize = 192;
    var sizes = new[] { 16, 32 };
    using var preview = new Bitmap(visuals.Length * cellSize, sizes.Length * cellSize);
    using var graphics = Graphics.FromImage(preview);
    graphics.Clear(Color.FromArgb(32, 32, 32));
    graphics.InterpolationMode = InterpolationMode.NearestNeighbor;
    for (var row = 0; row < sizes.Length; row++)
    {
        for (var index = 0; index < visuals.Length; index++)
        {
            using var icon = TrayIconRenderer.Render(visuals[index], sizes[row]);
            graphics.DrawImage(
                icon,
                new Rectangle(index * cellSize, row * cellSize, cellSize, cellSize)
            );
        }
    }

    Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
    preview.Save(path, System.Drawing.Imaging.ImageFormat.Png);
}

static void Equal<T>(T expected, T actual)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new Exception($"Expected {expected}, got {actual}");
    }
}

static void True(bool value)
{
    if (!value)
    {
        throw new Exception("Expected true");
    }
}
