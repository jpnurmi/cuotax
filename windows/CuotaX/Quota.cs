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

    internal static string? ResetMessage(Quota? previous, Quota current)
    {
        if (previous is null)
        {
            return null;
        }

        var fiveHour = CrossedReset(previous.FiveHour, previous.UpdatedAt, current.UpdatedAt);
        var weekly = CrossedReset(previous.Weekly, previous.UpdatedAt, current.UpdatedAt);
        return (fiveHour, weekly) switch
        {
            (true, true) => "5-hour and weekly quotas reset",
            (true, false) => "5-hour quota reset",
            (false, true) => "Weekly quota reset",
            _ => null,
        };
    }

    internal DateTimeOffset? NextReset(DateTimeOffset? now = null)
    {
        var current = now ?? DateTimeOffset.Now;
        return new[] { FiveHour?.ResetsAt, Weekly?.ResetsAt }
            .Where(value => value > current)
            .Min();
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

    internal static QuotaStatus StatusFor(
        QuotaWindow? value,
        string window,
        int durationMinutes,
        DateTimeOffset? now = null
    ) => WindowStatus(value, window, durationMinutes, now ?? DateTimeOffset.Now)?.Status
        ?? QuotaStatus.Unavailable;

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
                    null,
                    remainingPercent,
                    window
                )
            );
        }

        var duration = TimeSpan.FromMinutes(durationMinutes).TotalSeconds;
        var targetEnd = durationMinutes == QuotaFormatting.WeeklyMinutes
            ? new[] { NextLocalMidnight(now), value.ResetsAt.Value }.Min()
            : now;
        var targetTimeRemaining = Math.Clamp(
            (value.ResetsAt.Value - targetEnd).TotalSeconds / duration,
            0,
            1
        );
        var actualTimeRemaining = Math.Clamp(
            (value.ResetsAt.Value - now).TotalSeconds / duration,
            0,
            1
        );
        var targetPercent = 100 * (1 - targetTimeRemaining);
        var onTrackPercent = Math.Round(
            10 * targetPercent,
            MidpointRounding.AwayFromZero
        ) / 10;
        double? paceProgress = null;
        if (durationMinutes == QuotaFormatting.WeeklyMinutes)
        {
            var startTimeRemaining = Math.Clamp(
                (value.ResetsAt.Value - StartOfLocalDay(now)).TotalSeconds / duration,
                0,
                1
            );
            var startPercent = 100 * (1 - startTimeRemaining);
            var allowance = targetPercent - startPercent;
            if (allowance > 0)
            {
                paceProgress = (usedPercent - startPercent) / allowance;
            }
        }
        var coverage = actualTimeRemaining == 0
            ? double.PositiveInfinity
            : remainingPercent / 100 / actualTimeRemaining;
        var level = usedPercent <= onTrackPercent
            ? QuotaLevel.Normal
            : coverage < 0.5
                ? QuotaLevel.Critical
                : QuotaLevel.Warning;

        return new RankedStatus(
            coverage,
            new QuotaStatus(coverage, level, onTrackPercent, paceProgress, remainingPercent, window)
        );
    }

    private static bool CrossedReset(
        QuotaWindow? window,
        DateTimeOffset previousUpdatedAt,
        DateTimeOffset currentUpdatedAt
    ) => window?.ResetsAt is { } resetsAt
        && previousUpdatedAt < resetsAt
        && resetsAt <= currentUpdatedAt;

    private static DateTimeOffset NextLocalMidnight(DateTimeOffset now)
        => LocalMidnight(now, 1);

    private static DateTimeOffset StartOfLocalDay(DateTimeOffset now)
        => LocalMidnight(now, 0);

    private static DateTimeOffset LocalMidnight(DateTimeOffset now, int days)
    {
        var local = TimeZoneInfo.ConvertTime(now, TimeZoneInfo.Local);
        var midnight = DateTime.SpecifyKind(local.Date.AddDays(days), DateTimeKind.Unspecified);
        return new DateTimeOffset(midnight, TimeZoneInfo.Local.GetUtcOffset(midnight));
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
    double? PaceProgress,
    double? RemainingPercent,
    string? Window
)
{
    internal static QuotaStatus Unavailable { get; } = new(
        null,
        QuotaLevel.Unavailable,
        null,
        null,
        null,
        null
    );

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
        if (status.Level == QuotaLevel.Unavailable || status.RemainingPercent is null || !double.IsFinite(status.RemainingPercent.Value))
        {
            return null;
        }

        var usage = 1 - Math.Clamp(status.RemainingPercent.Value, 0, 100) / 100;
        var threshold = Math.Clamp((status.OnTrackPercent ?? 70) / 100, 0, 1);
        double hue;
        if (status.PaceProgress is { } progress && double.IsFinite(progress) && usage <= threshold)
        {
            hue = 120 - 90 * Smoothstep(Math.Clamp(progress, 0, 1));
        }
        else if (usage <= 0)
        {
            hue = 120;
        }
        else if (usage < threshold)
        {
            hue = 120 - 90 * Smoothstep(usage / threshold);
        }
        else if (usage < 1)
        {
            hue = 30 * (1 - Smoothstep((usage - threshold) / (1 - threshold)));
        }
        else
        {
            hue = 0;
        }
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

    private static double Smoothstep(double value) => value * value * (3 - 2 * value);

    internal static string Percent(double? value)
    {
        if (value is null)
        {
            return "—";
        }

        var displayed = DisplayPercent(value.Value);
        var format = displayed == Math.Round(displayed) ? "0" : "0.0";
        return $"{displayed.ToString(format, CultureInfo.CurrentCulture)}%";
    }

    internal static string Time(DateTimeOffset? value) => value?.ToLocalTime().ToString("t", CultureInfo.CurrentCulture) ?? "—";

    internal static string Reset(DateTimeOffset? value, DateTimeOffset? now = null)
    {
        if (value is null)
        {
            return "reset unknown";
        }

        var remaining = Remaining(value.Value - (now ?? DateTimeOffset.Now));
        var suffix = remaining is null ? "" : $" ({remaining})";
        return $"{value.Value.ToLocalTime().ToString("ddd, MMM d HH:mm", CultureInfo.InvariantCulture)}{suffix}";
    }

    private static string? Remaining(TimeSpan value)
    {
        if (value <= TimeSpan.Zero)
        {
            return null;
        }
        if (value.TotalDays >= 1)
        {
            return $"{(int)value.TotalDays}d";
        }
        if (value.TotalHours >= 1)
        {
            return $"{(int)value.TotalHours}h";
        }
        return $"{Math.Max(1, (int)value.TotalMinutes)}m";
    }
}
