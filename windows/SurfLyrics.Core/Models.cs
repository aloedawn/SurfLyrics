namespace SurfLyrics.Core;

public sealed record MusicTrack(string Player, string Title, string Artist, string Album,
    long DurationMs, string? SpotifyId = null)
{
    public string Identity => string.Join('\u001f', Player, Title, Artist, Album, DurationMs);
}

public sealed record LyricsLine(long TimeMs, string Text);

public sealed record TimedLyrics(IReadOnlyList<LyricsLine> Lines, string Source)
{
    public int IndexAt(long positionMs)
    {
        int low = 0, high = Lines.Count - 1, found = -1;
        while (low <= high)
        {
            int mid = low + (high - low) / 2;
            if (Lines[mid].TimeMs <= positionMs) { found = mid; low = mid + 1; }
            else high = mid - 1;
        }
        return found;
    }

    public static bool IsInstrumental(string text) => text.EnumerateRunes().All(r =>
        Rune.IsWhiteSpace(r) || "♪♫♬♩🎵🎶\uFE0E\uFE0F".EnumerateRunes().Contains(r));
}

public enum FetchStatus { Found, NotFound, TransientFailure }
public sealed record LyricsResult(FetchStatus Status, TimedLyrics? Lyrics = null)
{
    public static LyricsResult Missing { get; } = new(FetchStatus.NotFound);
    public static LyricsResult Transient { get; } = new(FetchStatus.TransientFailure);
    public static LyricsResult FromLrc(string lrc, string source)
    {
        var lines = LrcParser.Parse(lrc);
        return lines.Any(l => !TimedLyrics.IsInstrumental(l.Text))
            ? new(FetchStatus.Found, new(lines, source)) : Missing;
    }
}

public interface ILyricsProvider
{
    Task<LyricsResult> FetchAsync(MusicTrack track, CancellationToken cancellationToken);
}

public static class LrcParser
{
    private static readonly Regex Timestamp = new(@"\[(\d+):(\d{1,2})(?:[.:](\d+))?\]",
        RegexOptions.Compiled | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));

    public static IReadOnlyList<LyricsLine> Parse(string lrc)
    {
        if (Encoding.UTF8.GetByteCount(lrc) > 1_000_000) return [];
        var result = new List<LyricsLine>();
        long offset = 0;
        foreach (var line in lrc.Split('\n'))
        {
            if (line.Trim() is var trimmed && trimmed.StartsWith("[offset:", StringComparison.OrdinalIgnoreCase)
                && trimmed.EndsWith(']') && long.TryParse(trimmed[8..^1], out var value))
                offset = Math.Clamp(value, -60_000, 60_000);
        }
        foreach (var raw in lrc.Split('\n'))
        {
            var matches = Timestamp.Matches(raw);
            if (matches.Count == 0) continue;
            var last = matches[^1];
            var text = raw[(last.Index + last.Length)..].Trim();
            if (Encoding.UTF8.GetByteCount(text) > 16_384) continue;
            foreach (Match match in matches)
            {
                if (!long.TryParse(match.Groups[1].Value, out var minutes) || minutes > 1440
                    || !int.TryParse(match.Groups[2].Value, out var seconds) || seconds >= 60) continue;
                var fraction = match.Groups[3].Value;
                int millis = fraction.Length == 0 ? 0 : int.Parse(fraction[..Math.Min(3, fraction.Length)].PadRight(3, '0'), CultureInfo.InvariantCulture);
                long time = minutes * 60_000 + seconds * 1000 + millis + offset;
                if (time is < 0 or > 86_400_000) continue;
                result.Add(new(time, text));
                if (result.Count > 10_000) return [];
            }
        }
        return result.OrderBy(l => l.TimeMs).ToArray();
    }
}

public static class JsonFields
{
    public static JsonElement At(this JsonElement item, params string[] path)
    {
        foreach (var key in path)
            if (item.ValueKind != JsonValueKind.Object || !item.TryGetProperty(key, out item)) return default;
        return item;
    }
    public static string Text(this JsonElement item) => item.ValueKind == JsonValueKind.String ? item.GetString() ?? "" : "";
    public static double Number(this JsonElement item) =>
        double.TryParse(item.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var value) && double.IsFinite(value) ? value : 0;
}
