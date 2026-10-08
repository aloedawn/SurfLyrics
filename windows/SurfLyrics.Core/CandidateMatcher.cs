namespace SurfLyrics.Core;

public sealed record LyricsCandidate(string Title, string Artist, string Album, long DurationMs);

// The same rejection gates, weights and ambiguity margin as the macOS matcher.
public static class CandidateMatcher
{
    public static string[] Tokens(string text)
    {
        var folded = text.Normalize(NormalizationForm.FormKD).ToLowerInvariant();
        folded = string.Concat(folded.Where(c => CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark));
        var tokens = Regex.Split(folded, @"[^\p{L}\p{N}]+").Where(x => x.Length > 0).ToArray();
        int feature = Array.FindIndex(tokens, x => x is "feat" or "ft" or "featuring");
        return feature > 0 ? tokens[..feature] : tokens;
    }

    private static string[] WithoutRemaster(string[] tokens) => tokens.Any(t => t is "remaster" or "remastered")
        ? tokens.Where(t => t is not ("remaster" or "remastered") && !(t.Length == 4 && t.All(char.IsDigit))).ToArray() : tokens;

    private static double Similarity(string[] left, string[] right)
    {
        if (left.Length == 0 || right.Length == 0) return 0;
        if (left.SequenceEqual(right)) return 1;
        var remaining = right.GroupBy(x => x).ToDictionary(g => g.Key, g => g.Count());
        int common = 0;
        foreach (var token in left)
            if (remaining.GetValueOrDefault(token) > 0) { common++; remaining[token]--; }
        double dice = 2.0 * common / (left.Length + right.Length);
        return Math.Max(dice, .85 * Math.Max(EditSimilarity(string.Join(' ', left), string.Join(' ', right)),
            EditSimilarity(string.Concat(left), string.Concat(right))));
    }

    private static double EditSimilarity(string left, string right)
    {
        if (left.Length == 0 || right.Length == 0) return left == right ? 1 : 0;
        // Bound work for malformed provider metadata.
        if (Math.Max(left.Length, right.Length) > 512) return 0;
        var previous = Enumerable.Range(0, right.Length + 1).ToArray();
        var current = new int[right.Length + 1];
        for (int i = 0; i < left.Length; i++)
        {
            current[0] = i + 1;
            for (int j = 0; j < right.Length; j++)
                current[j + 1] = Math.Min(Math.Min(current[j] + 1, previous[j + 1] + 1), previous[j] + (left[i] == right[j] ? 0 : 1));
            (previous, current) = (current, previous);
        }
        return 1.0 - (double)previous[right.Length] / Math.Max(left.Length, right.Length);
    }

    public static bool SameTitle(string left, string right) =>
        WithoutRemaster(Tokens(left)).SequenceEqual(WithoutRemaster(Tokens(right)));

    private static HashSet<string> Editions(string title)
    {
        var segments = Regex.Matches(title.ToLowerInvariant(), @"[\(\[\{]([^\)\]\}]+)[\)\]\}]| [–—-] (.*)$")
            .Select(m => m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value).ToList();
        var tokens = Tokens(title);
        if (tokens.LastOrDefault() is "live" or "remix" or "remixed" or "acoustic" or "instrumental" or "karaoke" or "slowed")
            segments.Add(tokens[^1]);
        if (tokens.Length >= 2 && tokens[^2] == "sped" && tokens[^1] == "up") segments.Add("sped up");
        var tags = new HashSet<string>();
        foreach (var segment in segments)
        {
            if (Regex.IsMatch(segment, @"\b(feat|ft|featuring)\b")) continue;
            var part = Tokens(segment);
            foreach (var tag in new[] { "live", "acoustic", "instrumental", "karaoke", "slowed" })
                if (part.Contains(tag)) tags.Add(tag);
            if (part.Any(t => t is "remix" or "remixed")) tags.Add("remix");
            if (segment.Contains("sped up", StringComparison.Ordinal)) tags.Add("sped up");
        }
        return tags;
    }

    public static double? Score(MusicTrack track, LyricsCandidate candidate)
    {
        if (!Editions(track.Title).SetEquals(Editions(candidate.Title))) return null;
        double? duration = null;
        if (track.DurationMs > 0 && candidate.DurationMs > 0)
        {
            long tolerance = Math.Clamp((long)(track.DurationMs * .03), 4000, 8000);
            long difference = Math.Abs(track.DurationMs - candidate.DurationMs);
            if (difference > tolerance) return null;
            duration = 1.0 - (double)difference / tolerance;
        }
        var left = Tokens(track.Title); var right = Tokens(candidate.Title);
        var cleanLeft = WithoutRemaster(left); var cleanRight = WithoutRemaster(right);
        double title = Math.Max(Similarity(left, right), Similarity(cleanLeft, cleanRight));
        if (title < .55 || (Math.Min(cleanLeft.Length, cleanRight.Length) == 1 && !cleanLeft.SequenceEqual(cleanRight) && title < .9)) return null;
        double artist = Similarity(Tokens(track.Artist), Tokens(candidate.Artist));
        if (artist < .45) return null;
        double total = title * .4 + artist * .25, weight = .65;
        if (track.Album.Length > 0 && candidate.Album.Length > 0) { total += Similarity(Tokens(track.Album), Tokens(candidate.Album)) * .1; weight += .1; }
        if (duration.HasValue) { total += duration.Value * .25; weight += .25; }
        return total / weight;
    }

    public static int? Best(MusicTrack track, IReadOnlyList<LyricsCandidate> candidates)
    {
        var ranked = candidates.Select((c, i) => (Index: i, Score: Score(track, c)))
            .Where(x => x.Score.HasValue).OrderByDescending(x => x.Score).ToArray();
        if (ranked.Length == 0 || ranked[0].Score < .74) return null;
        var best = ranked[0];
        foreach (var other in ranked.Skip(1))
        {
            if (best.Score - other.Score >= .06) continue;
            var a = candidates[best.Index]; var b = candidates[other.Index];
            bool equivalent = SameTitle(a.Title, b.Title) && Tokens(a.Artist).SequenceEqual(Tokens(b.Artist))
                && (a.Album.Length == 0 || b.Album.Length == 0 || Tokens(a.Album).SequenceEqual(Tokens(b.Album)))
                && (a.DurationMs == 0 || b.DurationMs == 0 || Math.Abs(a.DurationMs - b.DurationMs) <= Math.Clamp((long)(Math.Min(a.DurationMs, b.DurationMs) * .03), 4000, 8000));
            if (!equivalent) return null;
        }
        return best.Index;
    }
}
