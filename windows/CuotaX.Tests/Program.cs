// SPDX-License-Identifier: MIT

using System.Drawing.Drawing2D;
using System.Globalization;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
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
    ("Claude usage", TestClaudeQuota),
    ("Claude login", TestClaudeLogin),
    ("Claude status-line fallback", TestClaudeHybrid),
    ("Claude request errors", TestClaudeErrors),
    ("Claude status-line watcher", TestClaudeWatcher),
    ("Claude Fable usage", TestClaudeFable),
    ("Claude login renewal", TestClaudeRenewal),
    ("Claude login recovery", TestClaudeRecovery),
    ("Claude login concurrency", TestClaudeConcurrentRenewal),
    ("stacked tray icon", TestStackedTrayIcon),
    ("native tray icon", TestNativeTrayIcon),
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

    now = new DateTimeOffset(new DateTime(2026, 8, 26, 12, 0, 0, DateTimeKind.Local));
    var reset = new DateTimeOffset(new DateTime(2026, 9, 1, 14, 0, 0, DateTimeKind.Local));
    quota = new Quota(null, new QuotaWindow(6, reset), now);
    status = quota.Status(now);
    Equal(20.2, status.OnTrackPercent);
    True(status.PaceProgress < 0.01);
    Equal(QuotaLevel.Normal, status.Level);
    True(QuotaFormatting.Color(status) is { } dailyColor && dailyColor.Green > dailyColor.Red);

    var finalDay = new DateTimeOffset(new DateTime(2026, 9, 1, 12, 0, 0, DateTimeKind.Local));
    status = new Quota(null, new QuotaWindow(99, reset), finalDay).Status(finalDay);
    Equal(100d, status.OnTrackPercent);

    var afterReset = new DateTimeOffset(new DateTime(2026, 9, 1, 15, 0, 0, DateTimeKind.Local));
    status = new Quota(null, new QuotaWindow(5, reset.AddDays(7)), afterReset).Status(afterReset);
    Equal(6d, status.OnTrackPercent);
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
        Equal("Tue 13:37 (3d)", QuotaFormatting.Reset(reset, reset.AddDays(-3)));
        var friday = new DateTimeOffset(
            new DateTime(2026, 9, 25, 9, 48, 0, DateTimeKind.Local)
        );
        var monday = new DateTimeOffset(
            new DateTime(2026, 9, 21, 16, 57, 0, DateTimeKind.Local)
        );
        Equal("Fri 09:48 (3d 16h)", QuotaFormatting.Reset(friday, monday));
        Equal("Tue 13:37 (7h)", QuotaFormatting.Reset(reset, reset.AddHours(-7)));
        Equal("Tue 13:37 (33m)", QuotaFormatting.Reset(reset, reset.AddMinutes(-33)));
        Equal("Tue 13:37", QuotaFormatting.Reset(reset, reset));
        Equal("13:37 (7h)", QuotaFormatting.Reset(reset, reset.AddHours(-7), includeDate: false));
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
        QuotaFormatting.Color(new QuotaStatus(1, QuotaLevel.Normal, 40, null, 100, null))
    );
    Equal(
        new PaceColor(226, 140, 54),
        QuotaFormatting.Color(new QuotaStatus(1, QuotaLevel.Warning, 40, null, 60, null))
    );
    Equal(
        new PaceColor(226, 54, 54),
        QuotaFormatting.Color(new QuotaStatus(0, QuotaLevel.Critical, 40, null, 0, null))
    );
    Equal(
        new PaceColor(226, 140, 54),
        QuotaFormatting.Color(new QuotaStatus(1, QuotaLevel.Warning, null, null, 30, null))
    );
    True(
        QuotaFormatting.Color(
            new QuotaStatus(
                1,
                QuotaLevel.Normal,
                23.2,
                (15 - 14.6) / (23.2 - 14.6),
                85,
                "weekly"
            )
        ) is { } dailyColor && dailyColor.Green > dailyColor.Red
    );
    foreach (var remainingPercent in new[] { double.NaN, double.PositiveInfinity, double.NegativeInfinity })
    {
        Equal<PaceColor?>(
            null,
            QuotaFormatting.Color(
                new QuotaStatus(1, QuotaLevel.Normal, 50, null, remainingPercent, null)
            )
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
    Equal<DateTimeOffset?>(reset, previous.NextReset(before));
    Equal<DateTimeOffset?>(null, previous.NextReset(reset));
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

static Task TestStackedTrayIcon()
{
    var now = DateTimeOffset.FromUnixTimeSeconds(1_777_000_000);
    var quota = new Quota(
        new QuotaWindow(82, now.AddHours(4)),
        new QuotaWindow(7, now.AddDays(5)),
        now,
        new QuotaWindow(95, now.AddDays(6))
    );
    var weekly = TrayIconRenderer.ForQuota(quota, now, weeklyOnly: true);
    Equal("7%", weekly.Label);
    Equal(TrayIconRenderer.ForQuota(quota, now).Background, weekly.Background);
    Equal("-", TrayIconRenderer.ForQuota(quota with { Weekly = null }, now, weeklyOnly: true).Label);
    var exhausted = TrayIconRenderer.ForQuota(
        quota with { FiveHour = new QuotaWindow(100, now.AddHours(4)) },
        now,
        weeklyOnly: true
    );
    Equal("×", exhausted.Label);

    var rows = new[] { weekly, TrayIconRenderer.ForQuota(quota with { Weekly = new QuotaWindow(99, now.AddDays(5)) }, now, weeklyOnly: true) };
    foreach (var size in new[] { 16, 20, 24, 32 })
    {
        using var image = TrayIconRenderer.Render(rows, size);
        for (var row = 0; row < rows.Length; row++)
        {
            var pixels = Enumerable.Range(row * size / 2, size / 2)
                .SelectMany(y => Enumerable.Range(0, size).Select(x => image.GetPixel(x, y)))
                .ToArray();
            True(pixels.Count(pixel => pixel.A == 0) > pixels.Length / 4);
            True(pixels.Any(pixel => pixel.A is > 0 and < 255));
            var color = rows[row].Background;
            True(pixels.Any(pixel => pixel.A > 0
                && Math.Abs(pixel.R - color.R) <= 4
                && Math.Abs(pixel.G - color.G) <= 4
                && Math.Abs(pixel.B - color.B) <= 4));
        }
        using var update = TrayIconRenderer.Render(rows, size, updateAvailable: true);
        var badge = update.GetPixel(size / 8, size * 7 / 8);
        True(badge.B > badge.R && badge.B > badge.G);
    }
    using var icon = TrayIconRenderer.Create(rows);
    True(icon.Handle != nint.Zero);

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
    var singles = new[]
    {
        TrayIconRenderer.ForQuota(new Quota(new QuotaWindow(7, now.AddHours(4)), null, now)),
        TrayIconRenderer.ForQuota(new Quota(new QuotaWindow(42, now.AddHours(4)), null, now)),
        TrayIconRenderer.ForQuota(new Quota(new QuotaWindow(82, now.AddHours(4)), null, now)),
        TrayIconRenderer.ForQuota(new Quota(new QuotaWindow(100, now.AddHours(4)), null, now)),
        TrayIconRenderer.Error(),
    };
    TrayIconVisual Weekly(double percent) => TrayIconRenderer.ForQuota(
        new Quota(null, new QuotaWindow(percent, now.AddDays(5)), now), now, weeklyOnly: true
    );
    var visuals = new TrayIconVisual[][]
    {
        [singles[0]],
        [singles[1]],
        [singles[2]],
        [singles[3]],
        [singles[4]],
        [Weekly(8), Weekly(7)],
        [Weekly(7), Weekly(42)],
        [Weekly(42), Weekly(82)],
        [Weekly(99), Weekly(100)],
        [Weekly(7), TrayIconRenderer.Error()],
        [TrayIconRenderer.LoadingState(), Weekly(42)],
    };
    const int cellSize = 192;
    var sizes = new[] { 16, 20, 24, 32 };
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

    using var native = new Bitmap((visuals.Length - singles.Length) * 40, 80);
    using var nativeGraphics = Graphics.FromImage(native);
    for (var row = 0; row < 2; row++)
    {
        using var background = new SolidBrush(row == 0 ? Color.FromArgb(32, 32, 32) : Color.FromArgb(240, 240, 240));
        nativeGraphics.FillRectangle(background, 0, row * 40, native.Width, 40);
        for (var index = singles.Length; index < visuals.Length; index++)
        {
            using var icon = TrayIconRenderer.Render(visuals[index], 20);
            nativeGraphics.DrawImageUnscaled(icon, (index - singles.Length) * 40 + 10, row * 40 + 10);
        }
    }
    native.Save(Path.ChangeExtension(path, ".native.png"), System.Drawing.Imaging.ImageFormat.Png);
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

static Task TestNativeTrayIcon()
{
    var now = DateTimeOffset.FromUnixTimeSeconds(1_777_000_000);
    var visual = TrayIconRenderer.ForQuota(new Quota(null, new QuotaWindow(8, now.AddDays(5)), now), now, weeklyOnly: true);
    var rows = new[] { visual, visual };
    using var icon = TrayIconRenderer.Create(rows);
    using var bitmap = TrayIconRenderer.Render(rows, icon.Width);
    foreach (var background in new[] { Color.FromArgb(27, 32, 41), Color.FromArgb(240, 240, 240) })
    {
        using var expected = new Bitmap(icon.Width, icon.Height);
        using var actual = new Bitmap(icon.Width, icon.Height);
        using (var graphics = Graphics.FromImage(expected))
        {
            graphics.Clear(background);
            graphics.DrawImageUnscaled(bitmap, 0, 0);
        }
        using (var graphics = Graphics.FromImage(actual))
        {
            graphics.Clear(background);
            graphics.DrawIconUnstretched(icon, new Rectangle(Point.Empty, icon.Size));
        }
        for (var y = 0; y < icon.Height; y++)
        {
            for (var x = 0; x < icon.Width; x++)
            {
                var source = expected.GetPixel(x, y);
                var rendered = actual.GetPixel(x, y);
                True(Math.Abs(source.R - rendered.R) <= 1
                    && Math.Abs(source.G - rendered.G) <= 1
                    && Math.Abs(source.B - rendered.B) <= 1);
            }
        }
    }
    return Task.CompletedTask;
}

static Task TestClaudeQuota()
{
    var quota = ClaudeClient.ParseQuota("""
        {"five_hour":{"utilization":42,"resets_at":"2026-10-12T22:00:00.123Z"},"seven_day":{"utilization":7,"resets_at":"invalid"}}
        """);
    Equal(42d, quota.FiveHour?.UsedPercent);
    Equal(7d, quota.Weekly?.UsedPercent);
    True(quota.FiveHour?.ResetsAt is not null);
    Equal(null, quota.Weekly?.ResetsAt);
    quota = ClaudeClient.ParseQuota("""
        {"limits":[{"kind":"weekly_scoped","percent":99},{"kind":"session","percent":25},{"kind":"weekly_all","percent":8}]}
        """);
    Equal(25d, quota.FiveHour?.UsedPercent);
    Equal(8d, quota.Weekly?.UsedPercent);
    return Task.CompletedTask;
}

static Task TestClaudeLogin()
{
    Equal("fixture", ClaudeClient.ParseToken("""{"claudeAiOauth":{"accessToken":"fixture"}}"""));
    foreach (var data in new[] { "{}", "invalid", """{"claudeAiOauth":{"accessToken":"fixture","expiresAt":1}}""" })
    {
        try
        {
            _ = ClaudeClient.ParseToken(data);
            throw new Exception("Expected login failure");
        }
        catch (BackendException)
        {
        }
    }
    return Task.CompletedTask;
}

static async Task TestClaudeHybrid()
{
    var directory = Path.Combine(Path.GetTempPath(), $"cuotax-{Guid.NewGuid()}");
    Directory.CreateDirectory(directory);
    try
    {
        var credentials = Path.Combine(directory, ".credentials.json");
        var cache = Path.Combine(directory, "cuotax-usage.json");
        await File.WriteAllTextAsync(credentials, """{"claudeAiOauth":{"accessToken":"fixture"}}""");
        var handler = new ClaudeHandler(HttpStatusCode.OK);
        using var client = new ClaudeClient(credentials, handler);
        var updatedAt = DateTimeOffset.Now.AddMinutes(-1).ToUnixTimeMilliseconds();
        await File.WriteAllTextAsync(cache, $"{{\"updatedAt\":{updatedAt},\"five_hour\":{{\"utilization\":98}}}}");
        var quota = await client.ReadQuotaAsync();
        Equal(98d, quota.FiveHour?.UsedPercent);
        Equal(updatedAt, quota.UpdatedAt.ToUnixTimeMilliseconds());
        Equal(0, handler.Requests);
        foreach (var data in new[] {
            "invalid",
            $"{{\"updatedAt\":{DateTimeOffset.Now.AddMinutes(-6).ToUnixTimeMilliseconds()},\"five_hour\":{{\"utilization\":98}}}}",
            $"{{\"updatedAt\":{DateTimeOffset.Now.AddMinutes(1).ToUnixTimeMilliseconds()},\"five_hour\":{{\"utilization\":98}}}}",
            $"{{\"updatedAt\":{DateTimeOffset.Now.ToUnixTimeMilliseconds()}}}",
        })
        {
            await File.WriteAllTextAsync(cache, data);
            Equal(42d, (await client.ReadQuotaAsync()).FiveHour?.UsedPercent);
        }
        File.Delete(cache);
        Equal(42d, (await client.ReadQuotaAsync()).FiveHour?.UsedPercent);
        Equal(5, handler.Requests);
    }
    finally
    {
        Directory.Delete(directory, recursive: true);
    }
}

static async Task TestClaudeErrors()
{
    var directory = Path.Combine(Path.GetTempPath(), $"cuotax-{Guid.NewGuid()}");
    Directory.CreateDirectory(directory);
    try
    {
        var credentials = Path.Combine(directory, ".credentials.json");
        await File.WriteAllTextAsync(credentials, """{"claudeAiOauth":{"accessToken":"fixture"}}""");
        foreach (var status in new[] { HttpStatusCode.Unauthorized, HttpStatusCode.TooManyRequests, HttpStatusCode.InternalServerError })
        {
            using var client = new ClaudeClient(credentials, new ClaudeHandler(status));
            try
            {
                _ = await client.ReadQuotaAsync();
                throw new Exception("Expected Claude request failure");
            }
            catch (BackendException error)
            {
                True(error.Message.StartsWith("Claude"));
            }
        }
    }
    finally
    {
        Directory.Delete(directory, recursive: true);
    }
}

static async Task TestClaudeWatcher()
{
    var directory = Path.Combine(Path.GetTempPath(), $"cuotax-{Guid.NewGuid()}");
    Directory.CreateDirectory(directory);
    try
    {
        using var client = new ClaudeClient(Path.Combine(directory, ".credentials.json"));
        var changed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        client.WatchUsage(() => changed.TrySetResult());
        var temporary = Path.Combine(directory, "usage.tmp");
        await File.WriteAllTextAsync(temporary, "{}");
        File.Move(temporary, Path.Combine(directory, "cuotax-usage.json"), overwrite: true);
        await changed.Task.WaitAsync(TimeSpan.FromSeconds(5));
    }
    finally
    {
        Directory.Delete(directory, recursive: true);
    }
}

static Task TestClaudeFable()
{
    var quota = ClaudeClient.ParseQuota("""
        {"five_hour":{"utilization":20},"seven_day":{"utilization":5},"limits":[{"kind":"weekly_scoped","percent":99,"scope":null},{"kind":"weekly_scoped","percent":80,"scope":{"model":{"display_name":"Sonnet"}}},{"kind":"weekly_scoped","percent":10,"resets_at":"2026-10-20T12:59:59.629512+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]}
        """);
    Equal(5d, quota.Weekly?.UsedPercent);
    Equal(10d, quota.Fable?.UsedPercent);
    True(quota.Fable?.ResetsAt is not null);
    quota = ClaudeClient.ParseQuota("""
        {"limits":[{"kind":"weekly_scoped","percent":95,"scope":{"model":{"display_name":"Fable"}}}]}
        """);
    Equal(null, quota.FiveHour);
    Equal(null, quota.Weekly);
    Equal(95d, quota.Fable?.UsedPercent);
    Equal(null, quota.Fable?.ResetsAt);
    Equal(null, ClaudeClient.ParseQuota("""{"seven_day":{"utilization":5}}""").Fable);

    var now = DateTimeOffset.FromUnixTimeSeconds(1_777_000_000);
    quota = new Quota(
        new QuotaWindow(20, now.AddHours(2)),
        new QuotaWindow(5, now.AddDays(6)),
        now,
        new QuotaWindow(95, now.AddDays(6))
    );
    Equal(95d, quota.HighestPercent);
    Equal("Fable weekly", quota.Status(now).Window);
    Equal(QuotaLevel.Critical, quota.Status(now).Level);
    var reset = now.AddMinutes(1);
    var previous = new Quota(null, null, now, new QuotaWindow(95, reset));
    var current = new Quota(null, null, reset);
    Equal<DateTimeOffset?>(reset, previous.NextReset(now));
    Equal<DateTimeOffset?>(null, previous.NextReset(reset));
    Equal("Fable weekly quota reset", Quota.ResetMessage(previous, current));
    var all = previous with { FiveHour = previous.Fable, Weekly = previous.Fable };
    Equal("5-hour, weekly and Fable weekly quotas reset", Quota.ResetMessage(all, current));
    return Task.CompletedTask;
}

static async Task TestClaudeRenewal()
{
    var directory = Path.Combine(Path.GetTempPath(), $"cuotax-{Guid.NewGuid()}");
    Directory.CreateDirectory(directory);
    var path = Path.Combine(directory, ".credentials.json");
    try
    {
        await File.WriteAllTextAsync(path, """
            {"other":{"preserved":true},"claudeAiOauth":{"accessToken":"old","refreshToken":"refresh","expiresAt":1,"scopes":["user:profile","user:inference"],"clientId":"fixture-client","subscriptionType":"max"}}
            """);
        var posts = 0;
        var rejected = false;
        var switched = false;
        var handler = new ClaudeHandler(HttpStatusCode.OK, async (request, _) =>
        {
            if (request.Method == HttpMethod.Post)
            {
                Equal("https://platform.claude.com/v1/oauth/token", request.RequestUri?.AbsoluteUri);
                Equal("application/json", request.Content?.Headers.ContentType?.MediaType);
                var body = JsonNode.Parse(await request.Content!.ReadAsStringAsync())!.AsObject();
                Equal("refresh_token", body["grant_type"]!.GetValue<string>());
                Equal(posts == 0 ? "refresh" : "rotated", body["refresh_token"]!.GetValue<string>());
                Equal("fixture-client", body["client_id"]!.GetValue<string>());
                Equal("user:profile user:inference", body["scope"]!.GetValue<string>());
                posts++;
                var current = JsonNode.Parse(await File.ReadAllTextAsync(path))!.AsObject();
                current["other"]!["changed"] = true;
                if (switched)
                {
                    current["claudeAiOauth"]!["accessToken"] = "another-login";
                    current["claudeAiOauth"]!["refreshToken"] = "another-refresh";
                }
                await File.WriteAllTextAsync(path, current.ToJsonString());
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new StringContent($$"""{"access_token":"renewed-{{posts}}","refresh_token":"rotated","expires_in":3600}"""),
                };
            }
            if (rejected)
            {
                rejected = false;
                return new HttpResponseMessage(HttpStatusCode.Unauthorized) { Content = new StringContent("{}") };
            }
            Equal(switched ? "another-login" : $"renewed-{posts}", request.Headers.Authorization?.Parameter);
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("""{"five_hour":{"utilization":42}}"""),
            };
        });
        using var client = new ClaudeClient(path, handler);
        Equal(42d, (await client.ReadQuotaAsync()).FiveHour?.UsedPercent);
        Equal(1, posts);
        var saved = JsonNode.Parse(await File.ReadAllTextAsync(path))!.AsObject();
        Equal("rotated", saved["claudeAiOauth"]!["refreshToken"]!.GetValue<string>());
        Equal("max", saved["claudeAiOauth"]!["subscriptionType"]!.GetValue<string>());
        True(saved["claudeAiOauth"]!["expiresAt"]!.GetValue<double>() > DateTimeOffset.Now.ToUnixTimeMilliseconds());
        True(saved["other"]!["preserved"]!.GetValue<bool>());
        True(saved["other"]!["changed"]!.GetValue<bool>());
        Equal(42d, (await client.ReadQuotaAsync()).FiveHour?.UsedPercent);
        Equal(1, posts);
        rejected = true;
        Equal(42d, (await client.ReadQuotaAsync()).FiveHour?.UsedPercent);
        Equal(2, posts);
        rejected = true;
        switched = true;
        Equal(42d, (await client.ReadQuotaAsync()).FiveHour?.UsedPercent);
        saved = JsonNode.Parse(await File.ReadAllTextAsync(path))!.AsObject();
        Equal("another-refresh", saved["claudeAiOauth"]!["refreshToken"]!.GetValue<string>());
        True(!Directory.Exists(Path.Combine(directory, ".oauth_refresh.lock")));
        Equal(1, Directory.GetFiles(directory).Length);
    }
    finally
    {
        Directory.Delete(directory, recursive: true);
    }
}

static async Task TestClaudeRecovery()
{
    var directory = Path.Combine(Path.GetTempPath(), $"cuotax-{Guid.NewGuid()}");
    Directory.CreateDirectory(directory);
    var path = Path.Combine(directory, ".credentials.json");
    const string credentials = """{"claudeAiOauth":{"accessToken":"old","refreshToken":"refresh","expiresAt":1}}""";
    try
    {
        foreach (var (status, data) in new[]
        {
            (HttpStatusCode.BadRequest, """{"error":"invalid_grant"}"""),
            (HttpStatusCode.ServiceUnavailable, "unavailable"),
            (HttpStatusCode.OK, "null"),
            (HttpStatusCode.OK, """{"access_token":"new","expires_in":0}"""),
            (HttpStatusCode.OK, """{"access_token":"new","expires_in":true}"""),
            (HttpStatusCode.OK, """{"access_token":"new","expires_in":3600,"refresh_token":null}"""),
        })
        {
            await File.WriteAllTextAsync(path, credentials);
            var handler = new ClaudeHandler(HttpStatusCode.OK, (_, _) => Task.FromResult(new HttpResponseMessage(status)
            {
                Content = new StringContent(data),
            }));
            using var client = new ClaudeClient(path, handler);
            try
            {
                await client.ReadQuotaAsync();
                throw new Exception("Expected renewal failure");
            }
            catch (BackendException error)
            {
                Equal(status == HttpStatusCode.BadRequest ? "Claude login expired or unavailable" : "Claude login renewal failed", error.Message);
            }
            Equal(credentials, await File.ReadAllTextAsync(path));
            True(!Directory.Exists(Path.Combine(directory, ".oauth_refresh.lock")));
        }
        var calls = 0;
        var unauthorized = new ClaudeHandler(HttpStatusCode.OK, (request, _) =>
        {
            calls++;
            return Task.FromResult(new HttpResponseMessage(request.Method == HttpMethod.Post ? HttpStatusCode.OK : HttpStatusCode.Unauthorized)
            {
                Content = new StringContent(request.Method == HttpMethod.Post ? """{"access_token":"new","expires_in":3600}""" : "{}"),
            });
        });
        await File.WriteAllTextAsync(path, credentials.Replace("\"expiresAt\":1", $"\"expiresAt\":{DateTimeOffset.Now.AddHours(1).ToUnixTimeMilliseconds()}"));
        using var rejected = new ClaudeClient(path, unauthorized);
        try
        {
            await rejected.ReadQuotaAsync();
            throw new Exception("Expected rejected login");
        }
        catch (BackendException error)
        {
            Equal("Claude login expired or unavailable", error.Message);
        }
        Equal(3, calls);
        var saved = JsonNode.Parse(await File.ReadAllTextAsync(path))!.AsObject();
        Equal("refresh", saved["claudeAiOauth"]!["refreshToken"]!.GetValue<string>());
    }
    finally
    {
        Directory.Delete(directory, recursive: true);
    }
}

static async Task TestClaudeConcurrentRenewal()
{
    var directory = Path.Combine(Path.GetTempPath(), $"cuotax-{Guid.NewGuid()}");
    Directory.CreateDirectory(directory);
    var path = Path.Combine(directory, ".credentials.json");
    try
    {
        await File.WriteAllTextAsync(path, """{"claudeAiOauth":{"accessToken":"old","refreshToken":"refresh","expiresAt":1}}""");
        var posts = 0;
        var handler = new ClaudeHandler(HttpStatusCode.OK, async (request, cancellationToken) =>
        {
            if (request.Method == HttpMethod.Post)
            {
                Interlocked.Increment(ref posts);
                await Task.Delay(100, cancellationToken);
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new StringContent("""{"access_token":"new","refresh_token":"rotated","expires_in":3600}"""),
                };
            }
            Equal("new", request.Headers.Authorization?.Parameter);
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("""{"five_hour":{"utilization":42}}"""),
            };
        });
        using var first = new ClaudeClient(path, handler);
        using var second = new ClaudeClient(path, handler);
        var results = await Task.WhenAll(first.ReadQuotaAsync(), second.ReadQuotaAsync());
        Equal(42d, results[0].FiveHour?.UsedPercent);
        Equal(42d, results[1].FiveHour?.UsedPercent);
        Equal(1, posts);
        var lockPath = Path.Combine(directory, ".oauth_refresh.lock");
        True(!Directory.Exists(lockPath));
        var saved = JsonNode.Parse(await File.ReadAllTextAsync(path))!.AsObject();
        saved["claudeAiOauth"]!["expiresAt"] = 1;
        await File.WriteAllTextAsync(path, saved.ToJsonString());
        Directory.CreateDirectory(lockPath);
        Directory.SetLastWriteTimeUtc(lockPath, DateTime.UtcNow.AddMinutes(-2));
        Equal(42d, (await first.ReadQuotaAsync()).FiveHour?.UsedPercent);
        True(!Directory.Exists(lockPath));
    }
    finally
    {
        Directory.Delete(directory, recursive: true);
    }
}

internal sealed class ClaudeHandler(HttpStatusCode status, Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>>? handle = null) : HttpMessageHandler
{
    internal int Requests { get; private set; }

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (handle is not null)
        {
            Requests++;
            return handle(request, cancellationToken);
        }
        if (request.RequestUri?.AbsoluteUri != "https://api.anthropic.com/api/oauth/usage"
            || request.Headers.Authorization?.Scheme != "Bearer"
            || request.Headers.GetValues("anthropic-beta").Single() != "oauth-2025-04-20")
        {
            throw new Exception("Unexpected Claude usage request");
        }
        Requests++;
        return Task.FromResult(new HttpResponseMessage(status)
        {
            Content = new StringContent("""{"five_hour":{"utilization":42},"seven_day":{"utilization":7}}"""),
        });
    }
}
