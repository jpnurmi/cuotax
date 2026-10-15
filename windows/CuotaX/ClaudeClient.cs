// SPDX-License-Identifier: MIT

using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;

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

        var token = await AccessTokenAsync(cancellationToken);
        for (var attempt = 0; attempt < 2; attempt++)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.anthropic.com/api/oauth/usage");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.Add("anthropic-beta", "oauth-2025-04-20");
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            using var response = await _http.SendAsync(request, cancellationToken);
            if (response.StatusCode == HttpStatusCode.Unauthorized && attempt == 0)
            {
                var renewed = await AccessTokenAsync(cancellationToken, token);
                if (renewed != token)
                {
                    token = renewed;
                    continue;
                }
            }
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            {
                throw ExpiredLogin();
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
        throw ExpiredLogin();
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
        var oauth = ParseCredentials(data)["claudeAiOauth"]!.AsObject();
        if (Number(oauth, "expiresAt") is { } expiresAt
            && expiresAt <= (now ?? DateTimeOffset.Now).ToUnixTimeMilliseconds())
        {
            throw ExpiredLogin();
        }
        return Text(oauth, "accessToken")!;
    }

    internal static Quota ParseQuota(string data, DateTimeOffset? updatedAt = null)
    {
        using var document = ParseJson(data);
        var root = document.RootElement;
        QuotaWindow? fiveHour = null;
        QuotaWindow? weekly = null;
        QuotaWindow? fable = null;
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
                    else if (kind.GetString() == "weekly_scoped"
                        && limit.TryGetProperty("scope", out var scope)
                        && scope.ValueKind == JsonValueKind.Object
                        && scope.TryGetProperty("model", out var model)
                        && model.ValueKind == JsonValueKind.Object
                        && model.TryGetProperty("display_name", out var name)
                        && name.ValueKind == JsonValueKind.String
                        && name.GetString() == "Fable")
                    {
                        fable ??= Window(limit);
                    }
                }
            }
        }
        if (fiveHour is null && weekly is null && fable is null)
        {
            throw new BackendException("Claude returned no quota limits", "Subscription usage requires a Claude Code login with a Claude plan");
        }
        return new Quota(fiveHour, weekly, updatedAt ?? DateTimeOffset.Now, fable);
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
            var now = DateTimeOffset.Now;
            var age = now - updatedAt;
            if (age < TimeSpan.Zero || age >= TimeSpan.FromMinutes(5))
            {
                return null;
            }
            var quota = ParseQuota(data, updatedAt);
            return new[] { quota.FiveHour?.ResetsAt, quota.Weekly?.ResetsAt, quota.Fable?.ResetsAt }
                .Any(reset => reset <= now) ? null : quota;
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

    private static BackendException ExpiredLogin() => new(
        "Claude login expired or unavailable",
        "The saved login could not be renewed; run /login in Claude Code"
    );

    private static BackendException RenewalFailed(string diagnostic) => new("Claude login renewal failed", diagnostic);

    private static string? Text(JsonObject value, string key)
        => value[key] is JsonValue node && node.TryGetValue<string>(out var text) ? text : null;

    private static double? Number(JsonObject value, string key)
        => value[key] is JsonValue node && node.TryGetValue<double>(out var number) && double.IsFinite(number) ? number : null;

    private static JsonObject ParseCredentials(string data)
    {
        JsonObject? credentials;
        try
        {
            credentials = JsonNode.Parse(data) as JsonObject;
        }
        catch (JsonException)
        {
            throw MissingLogin();
        }
        if (credentials?["claudeAiOauth"] is not JsonObject oauth || string.IsNullOrEmpty(Text(oauth, "accessToken")))
        {
            throw MissingLogin();
        }
        return credentials;
    }

    private async Task<JsonObject> ReadCredentialsAsync(CancellationToken cancellationToken)
    {
        try
        {
            return ParseCredentials(await File.ReadAllTextAsync(_credentialsPath, cancellationToken));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw MissingLogin();
        }
    }

    private static bool NeedsRefresh(JsonObject oauth, string? rejected)
        => Text(oauth, "accessToken") == rejected
            || Number(oauth, "expiresAt") is { } expiresAt && expiresAt <= DateTimeOffset.Now.ToUnixTimeMilliseconds() + 60_000;

    private async Task<string> AccessTokenAsync(CancellationToken cancellationToken, string? rejected = null)
    {
        var token = Environment.GetEnvironmentVariable("CLAUDE_CODE_OAUTH_TOKEN");
        if (!string.IsNullOrEmpty(token))
        {
            return token;
        }
        var credentials = await ReadCredentialsAsync(cancellationToken);
        var oauth = credentials["claudeAiOauth"]!.AsObject();
        if (!NeedsRefresh(oauth, rejected) || string.IsNullOrEmpty(Text(oauth, "refreshToken")))
        {
            return ParseToken(credentials.ToJsonString());
        }
        var path = Path.Combine(Path.GetDirectoryName(_credentialsPath)!, ".oauth_refresh.lock");
        await LockRefreshAsync(path, cancellationToken);
        try
        {
            credentials = await ReadCredentialsAsync(cancellationToken);
            oauth = credentials["claudeAiOauth"]!.AsObject();
            if (!NeedsRefresh(oauth, rejected))
            {
                return Text(oauth, "accessToken")!;
            }
            if (string.IsNullOrEmpty(Text(oauth, "refreshToken")))
            {
                throw ExpiredLogin();
            }
            return await RenewTokenAsync(oauth, cancellationToken);
        }
        finally
        {
            Directory.Delete(path);
        }
    }

    private static async Task LockRefreshAsync(string path, CancellationToken cancellationToken)
    {
        // share Claude Code's refresh lock to avoid rotating the same token twice
        for (var attempt = 0; attempt < 5; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (TryCreateLock(path))
            {
                return;
            }
            try
            {
                if (DateTime.UtcNow - Directory.GetLastWriteTimeUtc(path) >= TimeSpan.FromSeconds(60))
                {
                    Directory.Delete(path);
                    continue;
                }
            }
            catch (DirectoryNotFoundException)
            {
                continue;
            }
            await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
        }
        throw new BackendException("Claude login renewal busy", "Another process is renewing the login");
    }

    private static bool TryCreateLock(string path)
    {
        var created = OperatingSystem.IsWindows() ? CreateDirectory(path, nint.Zero) : Mkdir(path, 0x1C0) == 0;
        if (created)
        {
            return true;
        }
        var error = Marshal.GetLastPInvokeError();
        if (OperatingSystem.IsWindows() ? error == 183 : error == 17)
        {
            return false;
        }
        throw RenewalFailed("Could not lock the credentials for renewal");
    }

    [DllImport("kernel32.dll", EntryPoint = "CreateDirectoryW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateDirectory(string path, nint attributes);

    [DllImport("libc", EntryPoint = "mkdir", SetLastError = true)]
    private static extern int Mkdir(string path, uint mode);

    private async Task<string> RenewTokenAsync(JsonObject oauth, CancellationToken cancellationToken)
    {
        var body = new JsonObject
        {
            ["grant_type"] = "refresh_token",
            ["refresh_token"] = Text(oauth, "refreshToken"),
            ["client_id"] = Text(oauth, "clientId")
                ?? Environment.GetEnvironmentVariable("CLAUDE_CODE_OAUTH_CLIENT_ID")
                ?? "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        };
        if (oauth["scopes"] is JsonArray scopes && scopes.Count > 0)
        {
            body["scope"] = string.Join(" ", scopes.Select(value => value?.GetValue<string>()));
        }
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://platform.claude.com/v1/oauth/token")
        {
            Content = new StringContent(body.ToJsonString(), System.Text.Encoding.UTF8, "application/json"),
        };
        try
        {
            using var response = await _http.SendAsync(request, cancellationToken);
            JsonObject? result;
            try
            {
                result = JsonNode.Parse(await response.Content.ReadAsStringAsync()) as JsonObject;
            }
            catch (JsonException)
            {
                result = null;
            }
            if (response.StatusCode == HttpStatusCode.Unauthorized || result is not null && Text(result, "error") == "invalid_grant")
            {
                throw ExpiredLogin();
            }
            if (response.StatusCode != HttpStatusCode.OK)
            {
                throw RenewalFailed($"The token endpoint returned HTTP {(int)response.StatusCode}");
            }
            if (result is null || string.IsNullOrEmpty(Text(result, "access_token"))
                || Number(result, "expires_in") is not { } expiresIn || expiresIn <= 0
                || result.ContainsKey("refresh_token") && string.IsNullOrEmpty(Text(result, "refresh_token")))
            {
                throw RenewalFailed("The token response was invalid");
            }
            var renewed = new JsonObject
            {
                ["accessToken"] = Text(result, "access_token"),
                ["refreshToken"] = Text(result, "refresh_token") ?? Text(oauth, "refreshToken"),
                ["expiresAt"] = DateTimeOffset.Now.ToUnixTimeMilliseconds() + expiresIn * 1000,
            };
            if (Text(result, "scope") is { } scope)
            {
                renewed["scopes"] = JsonSerializer.SerializeToNode(scope.Split(' ', StringSplitOptions.RemoveEmptyEntries));
            }
            if (Number(result, "refresh_token_expires_in") is { } refreshExpiresIn && refreshExpiresIn > 0)
            {
                renewed["refreshTokenExpiresAt"] = DateTimeOffset.Now.ToUnixTimeMilliseconds() + refreshExpiresIn * 1000;
            }
            return await SaveCredentialsAsync(oauth, renewed);
        }
        catch (Exception error) when (error is HttpRequestException || error is OperationCanceledException && !cancellationToken.IsCancellationRequested)
        {
            throw RenewalFailed("Could not renew the saved login; CuotaX will retry automatically");
        }
    }

    private async Task<string> SaveCredentialsAsync(JsonObject previous, JsonObject renewed)
    {
        var temporary = $"{_credentialsPath}.{Guid.NewGuid()}.tmp";
        try
        {
            // finish saving rotated credentials even if the backend was disabled
            for (var attempt = 0; attempt < 3; attempt++)
            {
                var data = await File.ReadAllTextAsync(_credentialsPath);
                var credentials = ParseCredentials(data);
                var oauth = credentials["claudeAiOauth"]!.AsObject();
                if (Text(oauth, "accessToken") != Text(previous, "accessToken")
                    || Text(oauth, "refreshToken") != Text(previous, "refreshToken"))
                {
                    return ParseToken(data);
                }
                foreach (var (key, value) in renewed)
                {
                    oauth[key] = value?.DeepClone();
                }
                await File.WriteAllTextAsync(temporary, credentials.ToJsonString());
                if (File.ReadAllText(_credentialsPath) != data)
                {
                    continue;
                }
                File.Replace(temporary, _credentialsPath, null);
                return Text(oauth, "accessToken")!;
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw RenewalFailed("Could not save the renewed credentials");
        }
        finally
        {
            File.Delete(temporary);
        }
        throw RenewalFailed("Could not save the renewed credentials");
    }

    public void Dispose()
    {
        StopWatching();
        _http.Dispose();
    }
}
