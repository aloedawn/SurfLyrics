using System.Net;
using System.Net.NetworkInformation;
using System.Net.WebSockets;
using System.Reflection;
using System.Text.RegularExpressions;

namespace SurfLyrics.Windows;

public sealed class SpotifyClient : ILyricsProvider, IDisposable
{
    public const int Port = 43827;
    private readonly HttpClient local = new(new HttpClientHandler { UseProxy = false, UseCookies = false, AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(2) };
    private readonly SemaphoreSlim connectGate = new(1,1);
    private readonly string bridge;
    private readonly string nowPlayingBridge;
    public SpotifyClient()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("SurfLyrics.Windows.SpotifyClientBridge.js")
            ?? throw new InvalidOperationException("Missing Spotify bridge resource");
        using var reader = new StreamReader(stream);
        bridge = reader.ReadToEnd();
        using var playingStream = Assembly.GetExecutingAssembly().GetManifestResourceStream("SurfLyrics.Windows.SpotifyNowPlayingBridge.js") ?? throw new InvalidOperationException("Missing now-playing bridge");
        using var playingReader = new StreamReader(playingStream);
        nowPlayingBridge = playingReader.ReadToEnd();
    }

    public static Uri? ValidateTarget(JsonElement target)
    {
        if (target.At("type").Text() != "page" || !Uri.TryCreate(target.At("url").Text(), UriKind.Absolute, out var page)
            || page.Host != "xpui.app.spotify.com" || page.Scheme is not ("http" or "https")) return null;
        if (!Uri.TryCreate(target.At("webSocketDebuggerUrl").Text(), UriKind.Absolute, out var socket)
            || socket.Scheme != "ws" || socket.Host != "127.0.0.1" || socket.Port != Port || socket.UserInfo.Length != 0
            || !socket.AbsolutePath.StartsWith("/devtools/page/", StringComparison.Ordinal)
            || socket.Query.Length != 0 || socket.Fragment.Length != 0) return null;
        return socket;
    }

    private async Task<Uri?> TargetAsync(CancellationToken ct)
    {
        using var response = await local.GetAsync($"http://127.0.0.1:{Port}/json/list", ct);
        response.EnsureSuccessStatusCode();
        var bytes = await response.Content.ReadAsByteArrayAsync(ct);
        if (bytes.Length > 1_000_000) return null;
        using var doc = JsonDocument.Parse(bytes);
        if (doc.RootElement.ValueKind != JsonValueKind.Array) return null;
        return doc.RootElement.EnumerateArray().Select(ValidateTarget).FirstOrDefault(u => u != null);
    }

    public async Task<bool> IsReadyAsync(CancellationToken ct)
    {
        try { return await TargetAsync(ct) != null && ListenerIsLocal(); }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException or JsonException or NetworkInformationException) { return false; }
    }

    private static bool ListenerIsLocal()
    {
        var listeners = IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners().Where(e => e.Port == Port).ToArray();
        return listeners.Length > 0 && listeners.All(e => IPAddress.IsLoopback(e.Address));
    }

    private async Task<JsonElement> EvaluateAsync(string expression, CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        var token = timeout.Token;
        var target = await TargetAsync(token) ?? throw new HttpRequestException("Spotify connection unavailable");
        if (!ListenerIsLocal()) throw new HttpRequestException("Non-loopback listener");
        using var socket = new ClientWebSocket();
        socket.Options.Proxy = null;
        await socket.ConnectAsync(target, token);
        var request = JsonSerializer.SerializeToUtf8Bytes(new { id = 1, method = "Runtime.evaluate",
            @params = new { expression, awaitPromise = true, returnByValue = true, timeout = 9000 } });
        await socket.SendAsync(request.AsMemory(), WebSocketMessageType.Text, true, token);
        var buffer = new byte[8192];
        while (true)
        {
            using var message = new MemoryStream();
            ValueWebSocketReceiveResult part;
            do
            {
                part = await socket.ReceiveAsync(buffer.AsMemory(), token);
                if (part.MessageType != WebSocketMessageType.Text || message.Length + part.Count > 1_000_000) throw new JsonException("Invalid CDP response");
                message.Write(buffer, 0, part.Count);
            } while (!part.EndOfMessage);
            using var doc = JsonDocument.Parse(message.ToArray());
            var root = doc.RootElement;
            if (root.At("id").Number() != 1) continue;
            if (root.At("error").ValueKind != JsonValueKind.Undefined || root.At("result", "exceptionDetails").ValueKind != JsonValueKind.Undefined) throw new JsonException("CDP evaluation failed");
            return root.At("result", "result", "value").Clone();
        }
    }

    public async Task<LyricsResult> FetchAsync(MusicTrack track, CancellationToken cancellationToken)
    {
        if (track.Player != "Spotify") return LyricsResult.Missing;
        try
        {
            var id = track.SpotifyId;
            if (id == null)
            {
                // Windows SMTC omits the Spotify ID; validate bounded now-playing metadata.
                var playing = await EvaluateAsync(nowPlayingBridge, cancellationToken);
                if (!CandidateMatcher.SameTitle(playing.At("title").Text(), track.Title)) return LyricsResult.Missing;
                if (CandidateMatcher.Score(track, new(playing.At("title").Text(), playing.At("artist").Text(), "", 0)) is not >= .74) return LyricsResult.Missing;
                id = playing.At("id").Text();
            }
            if (!Regex.IsMatch(id, "^[A-Za-z0-9]{22}$")) return LyricsResult.Missing;
            var payload = await EvaluateAsync(bridge + "(" + JsonSerializer.Serialize(id) + ")", cancellationToken);
            return Decode(payload, id, track.DurationMs);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException or WebSocketException or JsonException or NetworkInformationException)
        { return LyricsResult.Transient; }
    }

    public static LyricsResult Decode(JsonElement root, string expectedId, long durationMs)
    {
        if (root.At("trackID").Text() != expectedId) return LyricsResult.Transient;
        var status = root.At("status").Text();
        if (status is "notFound" or "unsynced") return LyricsResult.Missing;
        if (status != "found" || root.At("syncType").Text() != "LINE_SYNCED") return LyricsResult.Transient;
        var raw = root.At("lines");
        if (raw.ValueKind != JsonValueKind.Array || raw.GetArrayLength() is 0 or > 10_000) return LyricsResult.Transient;
        long maximum = durationMs > 0 ? Math.Min(86_370_000, durationMs) + 30_000 : 86_400_000;
        var lines = new List<LyricsLine>();
        foreach (var item in raw.EnumerateArray())
        {
            if (!long.TryParse(item.At("startTimeMs").Text(), out var time) || time < 0 || time > maximum
                || time < (lines.LastOrDefault()?.TimeMs ?? 0) || item.At("words").ValueKind != JsonValueKind.String) return LyricsResult.Transient;
            var text = item.At("words").Text();
            if (Encoding.UTF8.GetByteCount(text) > 16_384) return LyricsResult.Transient;
            lines.Add(new(time, text));
        }
        return lines.Any(l => !TimedLyrics.IsInstrumental(l.Text)) ? new(FetchStatus.Found, new(lines, "Spotify 클라이언트")) : LyricsResult.Missing;
    }

    public async Task<string> ConnectAsync(CancellationToken ct)
    {
        await connectGate.WaitAsync(ct);
        try { return await ConnectCoreAsync(ct); }
        finally { connectGate.Release(); }
    }
    private async Task<string> ConnectCoreAsync(CancellationToken ct)
    {
        if (await IsReadyAsync(ct)) return "Spotify 가사 연결이 준비되었습니다.";
        var processes = Process.GetProcessesByName("Spotify").Where(p => p.SessionId == Process.GetCurrentProcess().SessionId && p.MainWindowHandle != nint.Zero).ToArray();
        string? path = null;
        foreach (var process in processes)
            try { path ??= process.MainModule?.FileName; } catch (System.ComponentModel.Win32Exception) { }
        var installation = SpotifyActivation.Find(path);
        if (installation == null) return "Spotify 데스크톱 앱을 먼저 설치하고 한 번 실행해 주세요.";
        if (IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners().Any(e => e.Port == Port))
            return "연결 포트가 사용 중입니다. Spotify를 완전히 종료한 뒤 다시 시도해 주세요.";
        // Only called after explicit opt-in. No service, elevation or Spotify file modifications.
        foreach (var process in processes)
        {
            try { if (process.MainModule?.FileName is string executable && SpotifyActivation.Matches(installation,executable))
                { process.Kill(); await process.WaitForExitAsync(ct).WaitAsync(TimeSpan.FromSeconds(5), ct); } }
            catch (InvalidOperationException) { }
            finally { process.Dispose(); }
        }
        int launchedId = SpotifyActivation.Start(installation);
        for (int attempt = 0; attempt < 40; attempt++)
        {
            await Task.Delay(500, ct);
            var listeners = IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners().Where(e => e.Port == Port).ToArray();
            if (listeners.Any(e => !IPAddress.IsLoopback(e.Address)))
            {
                using var launched = Process.GetProcessById(launchedId);
                if (!launched.HasExited && launched.MainModule?.FileName is string executable && SpotifyActivation.Matches(installation,executable)) launched.Kill();
                return "로컬 전용 연결을 만들 수 없어 연결 준비를 중단했습니다.";
            }
            if (await IsReadyAsync(ct)) return "Spotify 가사 연결이 준비되었습니다. 음악을 재생해 주세요.";
        }
        return "Spotify 연결을 준비하지 못했습니다. 다른 가사 소스로 계속합니다.";
    }

    public void Dispose() => local.Dispose();
}
