// SPDX-License-Identifier: MIT

using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CuotaX;

internal sealed class UpdateChecker : IDisposable
{
    private const string ApiUrl = "https://api.github.com/repos/jpnurmi/cuotax/compare";

    private readonly HttpClient _client;
    private readonly string? _buildCommit;

    internal UpdateChecker(HttpClient? client = null, string? buildCommit = null)
    {
        _client = client ?? new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        _buildCommit = buildCommit ?? Assembly.GetExecutingAssembly()
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(attribute => attribute.Key == "BuildCommit")
            ?.Value;
    }

    internal async Task<bool> IsUpdateAvailableAsync(CancellationToken cancellationToken = default)
    {
        if (!IsCommit(_buildCommit))
        {
            return false;
        }

        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            $"{ApiUrl}/{_buildCommit}...main"
        );
        request.Headers.Add("Accept", "application/vnd.github+json");
        request.Headers.Add("User-Agent", "CuotaX");
        using var response = await _client.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return false;
        }

        return HasUpdate(await response.Content.ReadAsStringAsync(cancellationToken));
    }

    internal static bool HasUpdate(string json)
    {
        try
        {
            return JsonSerializer.Deserialize<Comparison>(json)?.AheadBy > 0;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    public void Dispose() => _client.Dispose();

    private static bool IsCommit(string? value) =>
        value is { Length: 40 }
        && value.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');

    private sealed record Comparison([property: JsonPropertyName("ahead_by")] int AheadBy);
}
