// SPDX-License-Identifier: MIT

using System.Globalization;

namespace CuotaX;

internal sealed record QuotaWindow(double UsedPercent, DateTimeOffset? ResetsAt);

internal sealed record Quota(QuotaWindow? FiveHour, QuotaWindow? Weekly, DateTimeOffset UpdatedAt)
{
    internal double? HighestPercent
    {
        get
        {
            var values = new[] { FiveHour, Weekly }
                .Where(value => value is not null)
                .Select(value => value!.UsedPercent)
                .ToArray();
            return values.Length == 0 ? null : values.Max();
        }
    }

    internal QuotaStatus Status(DateTimeOffset? now = null)
    {
        var current = now ?? DateTimeOffset.Now;
        var statuses = new[]
        {
            WindowStatus(FiveHour, "5-hour", QuotaFormatting.FiveHourMinutes, current),
            WindowStatus(Weekly, "weekly", QuotaFormatting.WeeklyMinutes, current),
        }.Where(value => value is not null).Select(value => value!).ToArray();

        if (statuses.Length == 0)
        {
            return QuotaStatus.Unavailable;
        }

        var timed = statuses.Where(value => value.Status.OnTrackPercent is not null).ToArray();
        return (timed.Length == 0 ? statuses : timed).MinBy(value => value.Coverage)!.Status;
    }

    private static RankedStatus? WindowStatus(
        QuotaWindow? value,
        string window,
        int durationMinutes,
        DateTimeOffset now
    )
    {
        if (value is null)
        {
            return null;
        }

        var usedPercent = QuotaFormatting.NormalizePercent(value.UsedPercent);
        var remainingPercent = 100 - usedPercent;
        if (value.ResetsAt is null || value.ResetsAt <= now)
        {
            var untimedCoverage = remainingPercent / 100;
            return new RankedStatus(
                untimedCoverage,
                new QuotaStatus(
                    untimedCoverage,
                    QuotaFormatting.Severity(usedPercent),
                    null,
                    remainingPercent,
                    window
                )
            );
        }

        var duration = TimeSpan.FromMinutes(durationMinutes).TotalSeconds;
        var timeRemaining = Math.Clamp((value.ResetsAt.Value - now).TotalSeconds / duration, 0, 1);
        var onTrackPercent = Math.Round(
            1000 * (1 - timeRemaining),
            MidpointRounding.AwayFromZero
        ) / 10;
        var coverage = timeRemaining == 0
            ? double.PositiveInfinity
            : remainingPercent / 100 / timeRemaining;
        var level = usedPercent <= onTrackPercent
            ? QuotaLevel.Normal
            : coverage < 0.5
                ? QuotaLevel.Critical
                : QuotaLevel.Warning;

        return new RankedStatus(
            coverage,
            new QuotaStatus(coverage, level, onTrackPercent, remainingPercent, window)
        );
    }

    private sealed record RankedStatus(double Coverage, QuotaStatus Status);
}

internal enum QuotaLevel
{
    Normal,
    Warning,
    Critical,
    Unavailable,
}

internal sealed record QuotaStatus(
    double? Coverage,
    QuotaLevel Level,
    double? OnTrackPercent,
    double? RemainingPercent,
    string? Window
)
{
    internal static QuotaStatus Unavailable { get; } = new(null, QuotaLevel.Unavailable, null, null, null);

    internal string PaceLabel => Level switch
    {
        QuotaLevel.Normal => "On track",
        QuotaLevel.Warning => "Running high",
        QuotaLevel.Critical => "At risk",
        _ => "Pace unavailable",
    };
}

internal readonly record struct PaceColor(int Red, int Green, int Blue);

internal static class QuotaFormatting
{
    internal const int FiveHourMinutes = 5 * 60;
    internal const int WeeklyMinutes = 7 * 24 * 60;

    internal static double DisplayPercent(double value) => Math.Clamp(value, 0, 100);

    internal static double NormalizePercent(double value) => Math.Round(
        DisplayPercent(value) * 10,
        MidpointRounding.AwayFromZero
    ) / 10;

    internal static QuotaLevel Severity(double value) => value switch
    {
        >= 90 => QuotaLevel.Critical,
        >= 70 => QuotaLevel.Warning,
        _ => QuotaLevel.Normal,
    };

    internal static PaceColor? Color(QuotaStatus status)
    {
        if (status.Level == QuotaLevel.Unavailable || status.Coverage is null || double.IsNaN(status.Coverage.Value))
        {
            return null;
        }

        var coverage = Math.Clamp(status.Coverage.Value, 0, 1);
        var hue = 120 * (1 - Math.Sqrt(1 - coverage));
        const double saturation = 0.75;
        const double lightness = 0.55;
        var chroma = (1 - Math.Abs(2 * lightness - 1)) * saturation;
        var secondary = chroma * (1 - Math.Abs((hue / 60 % 2) - 1));
        var offset = lightness - chroma / 2;
        var (red, green) = hue < 60 ? (chroma, secondary) : (secondary, chroma);
        return new PaceColor(
            (int)Math.Round((red + offset) * 255, MidpointRounding.AwayFromZero),
            (int)Math.Round((green + offset) * 255, MidpointRounding.AwayFromZero),
            (int)Math.Round(offset * 255, MidpointRounding.AwayFromZero)
        );
    }

    internal static string Percent(double? value)
    {
        if (value is null)
        {
            return "—";
        }

        var displayed = DisplayPercent(value.Value);
        return displayed == Math.Round(displayed)
            ? $"{displayed:0}%"
            : $"{displayed.ToString("0.0", CultureInfo.InvariantCulture)}%";
    }

    internal static string Time(DateTimeOffset? value) => value?.ToLocalTime().ToString("t", CultureInfo.CurrentCulture) ?? "—";

    internal static string Reset(DateTimeOffset? value) => value is null
        ? "reset unknown"
        : $"resets {value.Value.ToLocalTime().ToString("g", CultureInfo.CurrentCulture)}";
}
