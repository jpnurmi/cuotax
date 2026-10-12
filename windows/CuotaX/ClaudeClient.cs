// SPDX-License-Identifier: MIT

using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;

namespace CuotaX;

internal sealed class ClaudeClient : IDisposable
{
    private readonly HttpClient _http;
    private readonly string _credentialsPath;
    private readonly string _cachePath;
    private FileSystemWatcher? _watcher;

    internal ClaudeClient(string? credentialsPath = null, HttpMessageHandler? handler = null)
    {
        var directory = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
        if (string.IsNullOrEmpty(directory))
        {
            directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");
        }
        _credentialsPath = credentialsPath ?? Path.Combine(directory, ".credentials.json");
        _cachePath = Path.Combine(Path.GetDirectoryName(_credentialsPath)!, "cuotax-usage.json");
        _http = handler is null ? new HttpClient() : new HttpClient(handler);
        _http.Timeout = TimeSpan.FromSeconds(15);
    }

    internal async Task<Quota> ReadQuotaAsync(CancellationToken cancellationToken = default)
    {
        var cached = await ReadCacheAsync(cancellationToken);
        if (cached is not null)
        {
            return cached;
        }

        var token = Environment.GetEnvironmentVariable("CLAUDE_CODE_OAUTH_TOKEN");
        if (string.IsNullOrEmpty(token))
        {
            string data;
            try
            {
                data = await File.ReadAllTextAsync(_credentialsPath, cancellationToken);
            }
            catch (IOException)
            {
                throw MissingLogin();
            }
            catch (UnauthorizedAccessException)
            {
                throw MissingLogin();
            }
            token = ParseToken(data);
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.anthropic.com/api/oauth/usage");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Add("anthropic-beta", "oauth-2025-04-20");
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        using var response = await _http.SendAsync(request, cancellationToken);
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
        {
            throw new BackendException("Claude login expired or unavailable", "Open Claude Code and run /login, then refresh");
        }
        if (response.StatusCode == HttpStatusCode.TooManyRequests)
        {
            throw new BackendException("Claude usage requests are rate limited", "Wait a few minutes before refreshing");
        }
        if (response.StatusCode != HttpStatusCode.OK)
        {
            throw new BackendException("Claude quota request failed", $"The usage endpoint returned HTTP {(int)response.StatusCode}");
        }
        return ParseQuota(await response.Content.ReadAsStringAsync(cancellationToken));
    }

    internal void WatchUsage(Action onChange)
    {
        if (_watcher is not null || !Directory.Exists(Path.GetDirectoryName(_cachePath)))
        {
            return;
        }
        _watcher = new FileSystemWatcher(Path.GetDirectoryName(_cachePath)!, Path.GetFileName(_cachePath));
        _watcher.Changed += (_, _) => onChange();
        _watcher.Created += (_, _) => onChange();
        _watcher.Renamed += (_, _) => onChange();
        _watcher.EnableRaisingEvents = true;
    }

    internal void StopWatching()
    {
        _watcher?.Dispose();
        _watcher = null;
    }

    internal static string ParseToken(string data, DateTimeOffset? now = null)
    {
        using var document = ParseJson(data);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty("claudeAiOauth", out var oauth)
            || oauth.ValueKind != JsonValueKind.Object
            || !oauth.TryGetProperty("accessToken", out var value)
            || value.ValueKind != JsonValueKind.String
            || string.IsNullOrEmpty(value.GetString()))
        {
            throw MissingLogin();
        }
        if (oauth.TryGetProperty("expiresAt", out var expiry)
            && expiry.ValueKind == JsonValueKind.Number
            && expiry.TryGetDouble(out var expiresAt)
            && expiresAt <= (now ?? DateTimeOffset.Now).ToUnixTimeMilliseconds())
        {
            throw new BackendException("Claude login expired", "Open Claude Code to renew the login, then refresh");
        }
        return value.GetString()!;
    }

    internal static Quota ParseQuota(string data, DateTimeOffset? updatedAt = null)
    {
        using var document = ParseJson(data);
        var root = document.RootElement;
        QuotaWindow? fiveHour = null;
        QuotaWindow? weekly = null;
        if (root.ValueKind == JsonValueKind.Object)
        {
            if (root.TryGetProperty("five_hour", out var five))
            {
                fiveHour = Window(five);
            }
            if (root.TryGetProperty("seven_day", out var seven))
            {
                weekly = Window(seven);
            }
            if (root.TryGetProperty("limits", out var limits) && limits.ValueKind == JsonValueKind.Array)
            {
                foreach (var limit in limits.EnumerateArray())
                {
                    if (limit.ValueKind != JsonValueKind.Object
                        || !limit.TryGetProperty("kind", out var kind)
                        || kind.ValueKind != JsonValueKind.String)
                    {
                        continue;
                    }
                    if (kind.GetString() == "session")
                    {
                        fiveHour ??= Window(limit);
                    }
                    else if (kind.GetString() == "weekly_all")
                    {
                        weekly ??= Window(limit);
                    }
                }
            }
        }
        if (fiveHour is null && weekly is null)
        {
            throw new BackendException("Claude returned no quota limits", "Subscription usage requires a Claude Code login with a Claude plan");
        }
        return new Quota(fiveHour, weekly, updatedAt ?? DateTimeOffset.Now);
    }

    private async Task<Quota?> ReadCacheAsync(CancellationToken cancellationToken)
    {
        try
        {
            var data = await File.ReadAllTextAsync(_cachePath, cancellationToken);
            using var document = JsonDocument.Parse(data);
            if (!document.RootElement.TryGetProperty("updatedAt", out var timestamp)
                || !timestamp.TryGetInt64(out var milliseconds))
            {
                return null;
            }
            var updatedAt = DateTimeOffset.FromUnixTimeMilliseconds(milliseconds);
            var age = DateTimeOffset.Now - updatedAt;
            return age >= TimeSpan.Zero && age < TimeSpan.FromMinutes(5) ? ParseQuota(data, updatedAt) : null;
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            return null;
        }
    }

    private static QuotaWindow? Window(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object
            || !(value.TryGetProperty("utilization", out var percent) || value.TryGetProperty("percent", out percent))
            || percent.ValueKind != JsonValueKind.Number
            || !percent.TryGetDouble(out var used)
            || !double.IsFinite(used))
        {
            return null;
        }
        DateTimeOffset? reset = value.TryGetProperty("resets_at", out var date)
            && date.ValueKind == JsonValueKind.String
            && DateTimeOffset.TryParse(date.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var parsed)
                ? parsed : null;
        return new QuotaWindow(used, reset);
    }

    private static JsonDocument ParseJson(string data)
    {
        try
        {
            return JsonDocument.Parse(data);
        }
        catch (JsonException)
        {
            throw new BackendException("Claude returned invalid data", "The response was not valid JSON");
        }
    }

    private static BackendException MissingLogin() => new("Claude Code login not found", "Open Claude Code and run /login with a Claude account");

    public void Dispose()
    {
        StopWatching();
        _http.Dispose();
    }
}
