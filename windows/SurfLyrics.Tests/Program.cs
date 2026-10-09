using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using SurfLyrics.Core;
using SurfLyrics.Windows;

int passed = 0;
void Check(string name, bool condition)
{
    if (!condition) throw new InvalidOperationException("FAIL: " + name);
    passed++; Console.WriteLine("PASS: " + name);
}
JsonElement Json(string source) { using var doc = JsonDocument.Parse(source); return doc.RootElement.Clone(); }
var track = new MusicTrack("Spotify", "Sample Song", "Sample Artist", "Sample Album", 180_000);

var parsed = LrcParser.Parse("[ar:Fixture]\n[00:02.5]second\n[00:00.05]first\n[00:03]\n[00:04:125]fourth\n[00:99]bad\n[999999999999999999:00]overflow");
Check("LRC sorts, supports colon fractions, rejects invalid timestamps", parsed.Count == 4 && parsed[0].TimeMs == 50 && parsed[1].TimeMs == 2500 && parsed[3].TimeMs == 4125);
Check("LRC keeps timed blank instrumental gaps", parsed[2].Text == "");
Check("LRC repeated timestamps", LrcParser.Parse("[00:01][00:03.25]repeat").Select(l => l.TimeMs).SequenceEqual(new long[] { 1000, 3250 }));
Check("LRC global offset", LrcParser.Parse("[00:01]line\n[offset:-100]")[0].TimeMs == 900);
Check("LRC ignores plain lyrics", LrcParser.Parse("plain fixture").Count == 0);
Check("LRC bounds oversized payloads", LrcParser.Parse(new string('x', 1_000_001)).Count == 0);
Check("Instrumental symbols include emoji and variation selector", TimedLyrics.IsInstrumental(" 🎵 ♪\uFE0F "));
Check("Words are not instrumental", !TimedLyrics.IsInstrumental("a note ♪"));
var lyrics = new TimedLyrics(new[] { new LyricsLine(1000, "first"), new LyricsLine(3000, ""), new LyricsLine(5000, "next") }, "Fixture");
Check("No premature first lyric", lyrics.IndexAt(999) == -1);
Check("Exact lyric boundary", lyrics.IndexAt(1000) == 0);
Check("Seek into instrumental", lyrics.IndexAt(4500) == 1);
Check("Seek backwards", lyrics.IndexAt(6000) == 2 && lyrics.IndexAt(1500) == 0);

var good = new LyricsCandidate("Sample Song", "Sample Artist", "Sample Album", 180_000);
Check("Exact candidate", CandidateMatcher.Score(track, good) == 1);
Check("Reject wrong artist", CandidateMatcher.Score(track, good with { Artist = "Someone Else" }) == null);
Check("Reject wrong duration", CandidateMatcher.Score(track, good with { DurationMs = 210_000 }) == null);
Check("Reject live edition", CandidateMatcher.Score(track, good with { Title = "Sample Song (Live)" }) == null);
Check("Ignore remaster label", CandidateMatcher.Score(track, good with { Title = "Sample Song - 2024 Remaster" }) >= .74);
Check("Fold accents and width", CandidateMatcher.SameTitle("Café Ｓｏｎｇ", "Cafe Song"));
Check("Keep Korean metadata", CandidateMatcher.SameTitle("한글 노래", "한글 노래"));
Check("Feature artist suffix", CandidateMatcher.SameTitle("Sample Song (feat. Guest)", "Sample Song"));
Check("Reject ambiguous recordings", CandidateMatcher.Best(track with { Album = "" }, new[] { good, good with { Album = "Another Album" } }) == null);
Check("Allow equivalent duplicate records", CandidateMatcher.Best(track, new[] { good, good }) == 0);
Check("Reject short title prefix confusion", CandidateMatcher.Score(track with { Title = "Fire" }, good with { Title = "Fireworks" }) == null);

const string id = "1234567890123456789012";
var spotifyPayload = Json("""
{"status":"found","trackID":"1234567890123456789012","syncType":"LINE_SYNCED","lines":[{"startTimeMs":"1000","words":"synthetic"},{"startTimeMs":"3000","words":""}]}
""");
Check("Spotify preserves timed blank", SpotifyClient.Decode(spotifyPayload, id, 180_000).Lyrics?.Lines.Count == 2);
Check("Spotify rejects wrong track", SpotifyClient.Decode(spotifyPayload, "other", 180_000).Status == FetchStatus.TransientFailure);
Check("Spotify rejects unordered times", SpotifyClient.Decode(Json(spotifyPayload.GetRawText().Replace("\"3000\"", "\"500\"")), id, 180_000).Status == FetchStatus.TransientFailure);
Check("Spotify rejects out-of-range times", SpotifyClient.Decode(Json(spotifyPayload.GetRawText().Replace("\"3000\"", "\"99999999\"")), id, 180_000).Status == FetchStatus.TransientFailure);
Check("Spotify rejects unsynced as timed data", SpotifyClient.Decode(Json(spotifyPayload.GetRawText().Replace("LINE_SYNCED", "UNSYNCED")), id, 180_000).Status != FetchStatus.Found);
var target = Json("""
{"type":"page","url":"https://xpui.app.spotify.com/","webSocketDebuggerUrl":"ws://127.0.0.1:43827/devtools/page/fixture"}
""");
Check("Spotify permits fixed loopback target", SpotifyClient.ValidateTarget(target) != null);
Check("Spotify rejects remote socket", SpotifyClient.ValidateTarget(Json(target.GetRawText().Replace("127.0.0.1", "example.com"))) == null);
Check("Spotify rejects wrong page", SpotifyClient.ValidateTarget(Json(target.GetRawText().Replace("xpui.app.spotify.com", "example.com"))) == null);
Check("Spotify rejects socket query", SpotifyClient.ValidateTarget(Json(target.GetRawText().Replace("/fixture", "/fixture?token=fixture"))) == null);
Check("Spotify rejects other port", SpotifyClient.ValidateTarget(Json(target.GetRawText().Replace("43827", "9222"))) == null);
Check("Spotify rejects socket credentials", SpotifyClient.ValidateTarget(Json(target.GetRawText().Replace("ws://", "ws://user@"))) == null);

var mxm = Json("""
{"message":{"header":{"status_code":200},"body":{"macro_calls":{"matcher.track.get":{"message":{"header":{"status_code":200},"body":{"track":{"track_name":"Sample Song","artist_name":"Sample Artist","album_name":"Sample Album","track_length":180,"track_spotify_id":"1234567890123456789012"}}}},"track.subtitles.get":{"message":{"header":{"status_code":200},"body":{"subtitle_list":[{"subtitle":{"subtitle_body":"[00:01]synthetic"}}]}}}}}}}
""");
Check("Musixmatch metadata match", MusixmatchProvider.Decode(mxm, track).Result.Status == FetchStatus.Found);
Check("Musixmatch mismatched Spotify ID", MusixmatchProvider.Decode(mxm, track with { SpotifyId = "wrong" }).Result.Status == FetchStatus.NotFound);
Check("Musixmatch stable ID across translations", MusixmatchProvider.Decode(mxm, track with { SpotifyId = id, Title = "번역된 제목", Artist = "다른 표기" }).Result.Status == FetchStatus.Found);
Check("Musixmatch rejects API errors inside HTTP 200", MusixmatchProvider.Decode(Json("""{"message":{"header":{"status_code":401},"body":[]}}"""), track).RefreshToken);

var first = new FixtureProvider(LyricsResult.Transient);
var second = new FixtureProvider(new(FetchStatus.Found, lyrics));
var last = new FixtureProvider(LyricsResult.Missing);
var service = new LyricsService(new ILyricsProvider[] { first, second, last });
Check("Provider priority and transient fallback", (await service.FetchAsync(track, default)).Status == FetchStatus.Found && first.Calls == 1 && second.Calls == 1 && last.Calls == 0);
await service.FetchAsync(track, default);
Check("Positive cache avoids duplicate requests", first.Calls == 1 && second.Calls == 1);
service.Clear(); await service.FetchAsync(track, default);
Check("Manual reload clears cache", second.Calls == 2);
var temporary = new FixtureProvider(LyricsResult.Transient);
var failureService = new LyricsService(new[] { temporary });
await failureService.FetchAsync(track, default); await failureService.FetchAsync(track, default);
Check("Do not cache transient failures", temporary.Calls == 2);
var missing = new FixtureProvider(LyricsResult.Missing);
var missingService = new LyricsService(new[] { missing });
await missingService.FetchAsync(track, default); await missingService.FetchAsync(track, default);
Check("Negative cache bounds repeated missing lookups", missing.Calls == 1);
using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
try { await service.FetchAsync(track with { Title = "New" }, cancelled.Token); Check("Cancelled request fails", false); }
catch (OperationCanceledException) { Check("Cancelled request does not probe providers", second.Calls == 2); }

using var transport = new FixtureTransport();
using var http = new HttpClient(transport);
var lrclib = new LrclibProvider(http);
var lrclibResult = await lrclib.FetchAsync(track, default);
Check("LRCLIB ignores unsynced exact result and finds matched search", lrclibResult.Status == FetchStatus.Found && transport.Requests == 2);
Check("LRCLIB result source", lrclibResult.Lyrics?.Source == "LRCLIB");
var paused = new PlaybackSnapshot(track, 1000, false, DateTimeOffset.UtcNow.AddSeconds(-10));
Check("Paused playback does not extrapolate", paused.PositionNow == 1000);
var playing = paused with { IsPlaying = true };
Check("Playing playback extrapolates", playing.PositionNow >= 11_000 && playing.PositionNow < 12_000);
Check("Playback clamps at duration", (playing with { PositionMs = 180_000 }).PositionNow == 180_000);
SpringChecks.Run(Check);
Console.WriteLine($"\n{passed} Windows regression checks passed.");

sealed class FixtureProvider(LyricsResult result) : ILyricsProvider
{
    public int Calls { get; private set; }
    public Task<LyricsResult> FetchAsync(MusicTrack track, CancellationToken ct) { Calls++; return Task.FromResult(result); }
}
sealed class FixtureTransport : HttpMessageHandler
{
    public int Requests { get; private set; }
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        Requests++;
        var content = request.RequestUri!.AbsolutePath.EndsWith("/get", StringComparison.Ordinal)
            ? """{"plainLyrics":"not timed","syncedLyrics":null}"""
            : """[{"trackName":"Sample Song","artistName":"Sample Artist","albumName":"Sample Album","duration":180,"syncedLyrics":"[00:01]synthetic"}]""";
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(content) });
    }
}
