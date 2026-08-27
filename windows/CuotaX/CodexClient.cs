// SPDX-License-Identifier: MIT

using System.Diagnostics;
using System.Text.Json;

namespace CuotaX;

internal sealed class BackendException(string message, string diagnostic) : Exception(message)
{
    internal string Diagnostic { get; } = diagnostic;
}

internal sealed record CodexCommand(string FileName, IReadOnlyList<string> PrefixArguments)
{
    internal static CodexCommand? Find()
    {
        var paths = (Environment.GetEnvironmentVariable("PATH") ?? string.Empty)
            .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Append(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm"))
            .Distinct(StringComparer.OrdinalIgnoreCase);
        var names = new[] { "codex.exe", "codex.com", "codex.cmd", "codex.bat" };

        foreach (var path in paths)
        {
            foreach (var name in names)
            {
                var candidate = Path.Combine(path.Trim('"'), name);
                if (File.Exists(candidate))
                {
                    return new CodexCommand(candidate, Array.Empty<string>());
                }
            }
        }

        return null;
    }

    internal ProcessStartInfo CreateStartInfo()
    {
        var extension = Path.GetExtension(FileName);
        ProcessStartInfo info;
        if (extension.Equals(".cmd", StringComparison.OrdinalIgnoreCase)
            || extension.Equals(".bat", StringComparison.OrdinalIgnoreCase))
        {
            if (PrefixArguments.Count != 0)
            {
                throw new InvalidOperationException("Command scripts do not support prefix arguments");
            }

            info = new ProcessStartInfo
            {
                FileName = Environment.GetEnvironmentVariable("ComSpec")
                    ?? Path.Combine(Environment.SystemDirectory, "cmd.exe"),
                Arguments = $"/d /s /c \"\"{FileName}\" app-server --stdio\"",
            };
        }
        else
        {
            info = new ProcessStartInfo { FileName = FileName };
            foreach (var argument in PrefixArguments)
            {
                info.ArgumentList.Add(argument);
            }
            info.ArgumentList.Add("app-server");
            info.ArgumentList.Add("--stdio");
        }

        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        info.RedirectStandardInput = true;
        info.RedirectStandardOutput = true;
        info.RedirectStandardError = true;
        return info;
    }
}

internal sealed class CodexClient(CodexCommand? command = null, TimeSpan? timeout = null)
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    private const string Request = """
        {"id":0,"method":"initialize","params":{"clientInfo":{"name":"cuotax","title":"CuotaX","version":"1"}}}
        {"method":"initialized","params":{}}
        {"id":1,"method":"account/rateLimits/read"}

        """;

    private readonly CodexCommand? _command = command ?? CodexCommand.Find();
    private readonly TimeSpan _timeout = timeout ?? TimeSpan.FromSeconds(15);

    internal async Task<Quota> ReadQuotaAsync(CancellationToken cancellationToken = default)
    {
        if (_command is null)
        {
            throw new BackendException(
                "Codex CLI not found",
                "Install the native Codex CLI on PATH or in the standard npm location"
            );
        }

        using var process = new Process { StartInfo = _command.CreateStartInfo() };
        try
        {
            process.Start();
        }
        catch (Exception error)
        {
            throw new BackendException("Codex quota request failed", error.Message);
        }

        var errors = process.StandardError.ReadToEndAsync();
        using var timeoutSource = new CancellationTokenSource(_timeout);
        using var linkedSource = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken,
            timeoutSource.Token
        );

        try
        {
            await process.StandardInput.WriteAsync(Request.AsMemory(), linkedSource.Token);
            await process.StandardInput.FlushAsync(linkedSource.Token);

            while (await process.StandardOutput.ReadLineAsync(linkedSource.Token) is { } line)
            {
                ServerMessage? message;
                try
                {
                    message = JsonSerializer.Deserialize<ServerMessage>(line, JsonOptions);
                }
                catch (JsonException)
                {
                    throw new BackendException(
                        "Codex returned invalid data",
                        "The app-server response was not JSON"
                    );
                }

                if (message?.Id != 1)
                {
                    continue;
                }
                if (message.Error is not null)
                {
                    throw new BackendException(
                        "Codex could not read quota",
                        message.Error.Message ?? "Unknown app-server error"
                    );
                }
                if (message.Result is null)
                {
                    throw new BackendException(
                        "Codex returned no quota",
                        "The rate-limit response was empty"
                    );
                }

                return ParseQuota(message.Result);
            }

            await process.WaitForExitAsync(CancellationToken.None);
            throw new BackendException(
                "Codex returned no quota",
                Diagnostic(await errors, "The app-server connection closed before replying")
            );
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new BackendException(
                "Codex quota request timed out",
                $"No response within {(int)_timeout.TotalSeconds} seconds"
            );
        }
        finally
        {
            try
            {
                process.StandardInput.Close();
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                }
                await process.WaitForExitAsync(CancellationToken.None);
            }
            catch (Exception)
            {
            }
        }
    }

    private static Quota ParseQuota(RateLimitResult result)
    {
        var limits = result.RateLimitsByLimitId?.Codex ?? result.RateLimits;
        if (limits is null)
        {
            throw new BackendException(
                "Codex returned no quota limits",
                "The rate-limit response did not contain Codex limits"
            );
        }

        QuotaWindow? fiveHour = null;
        QuotaWindow? weekly = null;
        foreach (var value in new[] { limits.Primary, limits.Secondary }.Where(value => value is not null))
        {
            if (value!.UsedPercent is null)
            {
                continue;
            }

            var window = new QuotaWindow(
                value.UsedPercent.Value,
                ResetTime(value.ResetsAt)
            );
            if (value.WindowDurationMins == QuotaFormatting.FiveHourMinutes)
            {
                fiveHour = window;
            }
            else if (value.WindowDurationMins == QuotaFormatting.WeeklyMinutes)
            {
                weekly = window;
            }
        }

        if (fiveHour is null && weekly is null)
        {
            throw new BackendException(
                "Codex returned no quota limits",
                "The response contained neither a 5-hour nor a weekly limit"
            );
        }

        return new Quota(fiveHour, weekly, DateTimeOffset.Now);
    }

    private static DateTimeOffset? ResetTime(double? seconds)
    {
        if (seconds is not { } value
            || !double.IsFinite(value)
            || value < DateTimeOffset.MinValue.ToUnixTimeSeconds()
            || value > DateTimeOffset.MaxValue.ToUnixTimeSeconds())
        {
            return null;
        }

        return DateTimeOffset.FromUnixTimeSeconds((long)value);
    }

    private static string Diagnostic(string value, string fallback) => string.IsNullOrWhiteSpace(value)
        ? fallback
        : value.Trim();

    private sealed class RateLimitWindow
    {
        public double? UsedPercent { get; init; }
        public int? WindowDurationMins { get; init; }
        public double? ResetsAt { get; init; }
    }

    private sealed class RateLimits
    {
        public RateLimitWindow? Primary { get; init; }
        public RateLimitWindow? Secondary { get; init; }
    }

    private sealed class RateLimitsById
    {
        public RateLimits? Codex { get; init; }
    }

    private sealed class RateLimitResult
    {
        public RateLimits? RateLimits { get; init; }
        public RateLimitsById? RateLimitsByLimitId { get; init; }
    }

    private sealed class RemoteError
    {
        public string? Message { get; init; }
    }

    private sealed class ServerMessage
    {
        public int? Id { get; init; }
        public RateLimitResult? Result { get; init; }
        public RemoteError? Error { get; init; }
    }
}
