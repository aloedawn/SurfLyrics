namespace SurfLyrics.Core;

public sealed class LyricsService(IReadOnlyList<ILyricsProvider> providers)
{
    private readonly Dictionary<string, (DateTimeOffset Expires, LyricsResult Result)> cache = [];
    public void Clear() => cache.Clear();

    public async Task<LyricsResult> FetchAsync(MusicTrack track, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (cache.TryGetValue(track.Identity, out var saved) && saved.Expires > DateTimeOffset.UtcNow) return saved.Result;
        bool transient = false;
        foreach (var provider in providers)
        {
            cancellationToken.ThrowIfCancellationRequested();
            LyricsResult result;
            try { result = await provider.FetchAsync(track, cancellationToken); }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
            catch (Exception ex) when (ex is HttpRequestException or JsonException or OperationCanceledException or FormatException)
            { result = LyricsResult.Transient; }
            cancellationToken.ThrowIfCancellationRequested();
            if (result.Status == FetchStatus.Found)
            {
                Store(track.Identity, result, TimeSpan.FromHours(6));
                return result;
            }
            transient |= result.Status == FetchStatus.TransientFailure;
        }
        if (transient) return LyricsResult.Transient;
        Store(track.Identity, LyricsResult.Missing, TimeSpan.FromMinutes(3));
        return LyricsResult.Missing;
    }

    private void Store(string key, LyricsResult result, TimeSpan lifetime)
    {
        if (cache.Count >= 128) cache.Remove(cache.MinBy(x => x.Value.Expires).Key);
        cache[key] = (DateTimeOffset.UtcNow + lifetime, result);
    }
}

public sealed class LrclibProvider(HttpClient client) : ILyricsProvider
{
    private DateTimeOffset notBefore;
    private DateTimeOffset lastRequest;

    private async Task<JsonDocument?> GetAsync(Dictionary<string, string> query, string endpoint, CancellationToken ct)
    {
        if (notBefore > DateTimeOffset.UtcNow) throw new HttpRequestException("Rate limited");
        var delay = lastRequest.AddMilliseconds(250) - DateTimeOffset.UtcNow;
        if (delay > TimeSpan.Zero) await Task.Delay(delay, ct);
        lastRequest = DateTimeOffset.UtcNow;
        var uri = "https://lrclib.net/api/" + endpoint + "?" + string.Join('&', query.Select(p => Uri.EscapeDataString(p.Key) + "=" + Uri.EscapeDataString(p.Value)));
        using var response = await client.GetAsync(uri, ct);
        if (response.StatusCode == HttpStatusCode.NotFound) return null;
        if (response.StatusCode == HttpStatusCode.TooManyRequests)
        {
            var retry = response.Headers.RetryAfter?.Delta ?? (response.Headers.RetryAfter?.Date - DateTimeOffset.UtcNow) ?? TimeSpan.FromSeconds(60);
            notBefore = DateTimeOffset.UtcNow + (retry > TimeSpan.Zero ? retry : TimeSpan.FromSeconds(1));
        }
        response.EnsureSuccessStatusCode();
        var data = await response.Content.ReadAsByteArrayAsync(ct);
        if (data.Length > 1_000_000) throw new JsonException("Oversized response");
        return JsonDocument.Parse(data);
    }

    public async Task<LyricsResult> FetchAsync(MusicTrack track, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(track.Title) || string.IsNullOrWhiteSpace(track.Artist)) return LyricsResult.Missing;
        var query = new Dictionary<string, string> { ["track_name"] = track.Title, ["artist_name"] = track.Artist };
        if (track.DurationMs > 0 && track.Album.Length > 0)
        {
            var exact = new Dictionary<string, string>(query) { ["album_name"] = track.Album,
                ["duration"] = Math.Round(track.DurationMs / 1000.0).ToString(CultureInfo.InvariantCulture) };
            using var doc = await GetAsync(exact, "get", cancellationToken);
            if (doc != null)
            {
                var result = LyricsResult.FromLrc(doc.RootElement.At("syncedLyrics").Text(), "LRCLIB");
                if (result.Status == FetchStatus.Found) return result;
            }
        }
        for (int attempt = 0; attempt < 2; attempt++)
        {
            if (attempt == 1) query.Remove("artist_name");
            using var doc = await GetAsync(query, "search", cancellationToken);
            if (doc?.RootElement.ValueKind != JsonValueKind.Array) continue;
            var records = doc.RootElement.EnumerateArray().Take(200).Where(e => e.At("syncedLyrics").Text().Length > 0).ToArray();
            var candidates = records.Select(e => Candidate(e)).ToArray();
            int? index = CandidateMatcher.Best(track, candidates);
            if (index.HasValue)
            {
                var result = LyricsResult.FromLrc(records[index.Value].At("syncedLyrics").Text(), "LRCLIB");
                if (result.Status == FetchStatus.Found) return result;
            }
        }
        return LyricsResult.Missing;
    }

    public static LyricsCandidate Candidate(JsonElement record) => new(record.At("trackName").Text(), record.At("artistName").Text(),
        record.At("albumName").Text(), (long)Math.Clamp(record.At("duration").Number() * 1000, 0, 86_400_000));
}

public sealed class MusixmatchProvider(HttpClient client) : ILyricsProvider
{
    private string? token;
    private DateTimeOffset tokenExpiry;
    private readonly SemaphoreSlim tokenGate = new(1, 1);

    private async Task<JsonDocument> GetAsync(string endpoint, Dictionary<string, string> query, CancellationToken ct)
    {
        query["app_id"] = "web-desktop-app-v1.0";
        var uri = "https://apic-desktop.musixmatch.com/ws/1.1/" + endpoint + "?" + string.Join('&', query.Select(p => Uri.EscapeDataString(p.Key) + "=" + Uri.EscapeDataString(p.Value)));
        using var request = new HttpRequestMessage(HttpMethod.Get, uri);
        request.Headers.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
        using var response = await client.SendAsync(request, ct);
        response.EnsureSuccessStatusCode();
        var data = await response.Content.ReadAsByteArrayAsync(ct);
        if (data.Length > 1_000_000) throw new JsonException("Oversized response");
        return JsonDocument.Parse(data);
    }

    private async Task<string?> TokenAsync(CancellationToken ct)
    {
        await tokenGate.WaitAsync(ct);
        try
        {
            if (token != null && tokenExpiry > DateTimeOffset.UtcNow) return token;
            using var doc = await GetAsync("token.get", [], ct);
            if (doc.RootElement.At("message", "header", "status_code").Number() != 200) return null;
            token = doc.RootElement.At("message", "body", "user_token").Text();
            tokenExpiry = DateTimeOffset.UtcNow.AddHours(1);
            return token.Length > 0 ? token : null;
        }
        finally { tokenGate.Release(); }
    }

    public async Task<LyricsResult> FetchAsync(MusicTrack track, CancellationToken cancellationToken)
    {
        for (int attempt = 0; attempt < 2; attempt++)
        {
            var current = await TokenAsync(cancellationToken);
            if (current == null) return LyricsResult.Transient;
            var query = new Dictionary<string, string> { ["format"] = "json", ["namespace"] = "lyrics_richsynced", ["subtitle_format"] = "lrc",
                ["q_track"] = track.Title, ["q_artist"] = track.Artist, ["q_album"] = track.Album,
                ["q_duration"] = (track.DurationMs / 1000).ToString(CultureInfo.InvariantCulture), ["usertoken"] = current };
            if (track.SpotifyId != null) query["track_spotify_id"] = track.SpotifyId;
            using var doc = await GetAsync("macro.subtitles.get", query, cancellationToken);
            var evaluation = Decode(doc.RootElement, track);
            if (!evaluation.RefreshToken) return evaluation.Result;
            if (token == current) { token = null; tokenExpiry = default; }
        }
        return LyricsResult.Transient;
    }

    public static (bool RefreshToken, LyricsResult Result) Decode(JsonElement root, MusicTrack track)
    {
        var calls = root.At("message", "body", "macro_calls");
        var matcher = calls.At("matcher.track.get", "message");
        var subtitles = calls.At("track.subtitles.get", "message");
        var statuses = new[] { root.At("message", "header", "status_code"), matcher.At("header", "status_code"), subtitles.At("header", "status_code") }
            .Where(e => e.ValueKind != JsonValueKind.Undefined).Select(e => (int)e.Number()).ToArray();
        if (statuses.Contains(401)) return (true, LyricsResult.Transient);
        if (statuses.Length == 0 || statuses.Any(s => s != 200))
            return (false, statuses.Contains(404) ? LyricsResult.Missing : LyricsResult.Transient);
        var matched = matcher.At("body", "track");
        if (matched.ValueKind != JsonValueKind.Object) return (false, LyricsResult.Missing);
        var matchedId = matched.At("track_spotify_id").Text();
        if (!string.IsNullOrEmpty(track.SpotifyId) && matchedId.Length > 0)
        {
            if (track.SpotifyId != matchedId) return (false, LyricsResult.Missing);
        }
        else
        {
            var candidate = new LyricsCandidate(matched.At("track_name").Text(), matched.At("artist_name").Text(), matched.At("album_name").Text(),
                (long)Math.Clamp(matched.At("track_length").Number() * 1000, 0, 86_400_000));
            if (CandidateMatcher.Score(track, candidate) is not >= .74) return (false, LyricsResult.Missing);
        }
        var list = subtitles.At("body", "subtitle_list");
        if (list.ValueKind != JsonValueKind.Array || list.GetArrayLength() == 0) return (false, LyricsResult.Missing);
        return (false, LyricsResult.FromLrc(list[0].At("subtitle", "subtitle_body").Text(), "Musixmatch"));
    }
}
