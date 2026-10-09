using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace SurfLyrics.Windows;

public partial class App : System.Windows.Application
{
    public Preferences Settings { get; private set; } = new();
    public bool Exiting { get; private set; }
    private readonly CancellationTokenSource lifetime = new();
    private readonly MediaSessionReader media = new();
    private readonly SpotifyClient spotify = new();
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(10), MaxResponseContentBufferSize = 1_000_000 };
    private LyricsService service = null!;
    private TaskbarWindow? taskbar;
    private Forms.NotifyIcon? tray;
    private Mutex? instance;
    private PlaybackSnapshot? playback;
    private TimedLyrics? lyrics;
    private CancellationTokenSource? lyricRequest;
    private bool loading;
    private string? issue;
    private DateTimeOffset nextRetry;
    private DateTimeOffset nextConnect;
    private Task? connectTask;
    private bool mediaApiAvailable;
    private DispatcherTimer? timer;
    private string? diagnosticPath;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        bool diagnostics = e.Args.Length == 2 && e.Args[0] == "--diagnostics";
        if (!diagnostics)
        {
            instance = new Mutex(true, @"Local\SurfLyrics.Windows", out bool first);
            if (!first) { Shutdown(); return; }
        }
        else diagnosticPath = Path.GetFullPath(e.Args[1]);
        Settings = Preferences.Load();
        http.DefaultRequestHeaders.UserAgent.ParseAdd("SurfLyrics/1.0 (https://github.com/aloedawn/surflyrics)");
        BuildService();
        taskbar = new(this);
        CreateTray();
        timer = new DispatcherTimer(TimeSpan.FromMilliseconds(100), DispatcherPriority.Background, (_, _) => Render(), Dispatcher);
        _ = ServeSettingsAsync();
        _ = PollAsync();
        if (diagnostics) _ = FinishDiagnosticsAsync();
    }

    private void BuildService()
    {
        var providers = new List<ILyricsProvider>();
        if (Settings.SpotifyLyrics) providers.Add(spotify);
        if (Settings.Lrclib) providers.Add(new LrclibProvider(http));
        if (Settings.Musixmatch) providers.Add(new MusixmatchProvider(http));
        service = new(providers);
    }

    private void CreateTray()
    {
        var menu = NativeMenu.Create();
        menu.Items.Add("설정", null, (_, _) => Dispatcher.Invoke(OpenSettings));
        menu.Items.Add("재생 / 일시정지", null, (_, _) => Dispatcher.Invoke(() => _ = TogglePlaybackAsync()));
        menu.Items.Add("가사 다시 불러오기", null, (_, _) => Dispatcher.Invoke(ReloadLyrics));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("종료", null, (_, _) => Dispatcher.Invoke(ExitApp));
        var resource = GetResourceStream(new Uri("pack://application:,,,/Assets/SurfLyrics.ico"));
        using var stream = resource.Stream;
        tray = new Forms.NotifyIcon { Icon = new Icon(stream), Text = "SurfLyrics", ContextMenuStrip = menu, Visible = true };
    }

    private async Task PollAsync()
    {
        while (!lifetime.IsCancellationRequested)
        {
            try
            {
                var snapshot = await media.ReadAsync(lifetime.Token);
                mediaApiAvailable = true;
                bool changed = snapshot?.Track.Identity != playback?.Track.Identity;
                playback = snapshot;
                if (changed)
                {
                    lyricRequest?.Cancel(); lyrics = null; loading = false; issue = null; nextRetry = default;
                    if (snapshot != null) StartLyrics(snapshot.Track);
                }
                else if (snapshot != null && !loading && lyrics == null && nextRetry != default && DateTimeOffset.UtcNow >= nextRetry)
                    StartLyrics(snapshot.Track);
                if (snapshot?.Track.Player == "Spotify" && Settings.SpotifyLyrics && Settings.AutoConnectSpotify
                    && DateTimeOffset.UtcNow >= nextConnect && connectTask is not { IsCompleted: false })
                {
                    nextConnect = DateTimeOffset.UtcNow.AddMinutes(2);
                    connectTask = AutoConnectAsync();
                }
            }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { break; }
            catch (Exception ex) when (ex is COMException or InvalidOperationException or TimeoutException or UnauthorizedAccessException)
            {
                // A failed probe must not keep advancing the previous track's lyrics.
                lyricRequest?.Cancel(); playback = null; lyrics = null; loading = false;
                issue = "음악 앱의 미디어 정보를 읽지 못했습니다. 잠시 후 다시 확인합니다.";
            }
            Render();
            try { await Task.Delay(1000, lifetime.Token); } catch (OperationCanceledException) { break; }
        }
    }

    private void StartLyrics(MusicTrack track)
    {
        lyricRequest?.Cancel(); lyricRequest?.Dispose();
        lyricRequest = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        loading = true; nextRetry = default;
        _ = LoadLyricsAsync(track, lyricRequest.Token);
    }

    private async Task LoadLyricsAsync(MusicTrack track, CancellationToken ct)
    {
        try
        {
            var result = await service.FetchAsync(track, ct);
            if (ct.IsCancellationRequested || playback?.Track.Identity != track.Identity) return;
            lyrics = result.Lyrics;
            issue = result.Status == FetchStatus.TransientFailure ? "가사 연결을 확인하는 중" : result.Status == FetchStatus.NotFound ? "동기화 가사 없음" : null;
            if (result.Status == FetchStatus.TransientFailure) nextRetry = DateTimeOffset.UtcNow.AddSeconds(30);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) when (ex is IOException or COMException or InvalidOperationException)
        {
            if (!ct.IsCancellationRequested && playback?.Track.Identity == track.Identity)
            { issue = "가사를 불러오지 못했습니다"; nextRetry = DateTimeOffset.UtcNow.AddSeconds(30); }
        }
        finally { if (!ct.IsCancellationRequested && playback?.Track.Identity == track.Identity) loading = false; }
    }

    private async Task AutoConnectAsync()
    {
        try
        {
            if (!await spotify.IsReadyAsync(lifetime.Token))
            {
                await ConnectSpotifyAsync();

            }
        }
        catch (OperationCanceledException) { }
    }

    public async Task<string> ConnectSpotifyAsync()
    {
        try { var message = await spotify.ConnectAsync(lifetime.Token); ReloadLyrics(); return message; }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or IOException or InvalidOperationException or System.Net.NetworkInformation.NetworkInformationException or OperationCanceledException or TimeoutException or COMException)
        { return "Spotify 연결을 준비하지 못했습니다. 다른 가사 소스로 계속합니다."; }
    }

    public async Task TogglePlaybackAsync()
    {
        try { await media.TogglePlaybackAsync(); }
        catch (Exception ex) when (ex is COMException or InvalidOperationException or TimeoutException) { issue = "음악 앱에서 재생을 조작해 주세요"; }
    }
    public void Render()
    {
        if (Exiting) return;
        taskbar?.Render(playback, lyrics, loading);
        if (tray != null)
        {
            var text = playback == null ? "SurfLyrics · 음악을 기다리는 중" : "SurfLyrics · " + playback.Track.Title;
            tray.Text = text[..Math.Min(63, text.Length)];
        }
    }
    public bool SaveSettings() => Settings.Save();
    public void ReloadLyrics()
    {
        lyricRequest?.Cancel(); BuildService(); lyrics = null; issue = null; loading = false;
        if (playback != null) StartLyrics(playback.Track);
    }
    private async Task FinishDiagnosticsAsync()
    {
        await Task.Delay(15_000);
        OpenSettings();
        await Task.Delay(2500);
        bool settingsLoaded = settingsReady;
        CloseSettings();
        File.WriteAllText(diagnosticPath!, JsonSerializer.Serialize(new { taskbarLoaded = taskbar?.IsLoaded == true, trayVisible = tray?.Visible == true,
            mediaApiAvailable, supportedSessions = media.SupportedSessionCount, hasTrack = playback != null,
            playbackPlayer = playback?.Track.Player, isPlaying = playback?.IsPlaying, lyricsSource = lyrics?.Source,
            syncedLineCount = lyrics?.Lines.Count ?? 0, settingsLoaded, clickThrough = taskbar?.ClickThrough == true,
            taskbarLocated = taskbar?.TaskbarLocated == true, taskbarVisible = taskbar?.IsVisible == true,
            trayIconColored = TrayIconHasColor(), spotifyBridgeEmbedded = true, pretendardJpBundled = LyricFont.Bundled, spotifyStoreDetected = SpotifyActivation.Find(null)?.AppId != null, osVersion = Environment.OSVersion.Version.ToString() }, new JsonSerializerOptions { WriteIndented = true }));
        ExitApp();
    }
    private bool TrayIconHasColor()
    {
        if (tray?.Icon == null) return false;
        using var bitmap = tray.Icon.ToBitmap();
        for (int y = 0; y < bitmap.Height; y++)
            for (int x = 0; x < bitmap.Width; x++)
            {
                var pixel = bitmap.GetPixel(x, y);
                if (pixel.A > 128 && Math.Max(pixel.R, Math.Max(pixel.G, pixel.B)) -
                    Math.Min(pixel.R, Math.Min(pixel.G, pixel.B)) > 32) return true;
            }
        return false;
    }
    public void ExitApp()
    {
        if (Exiting) return;
        Exiting = true; CloseSettings(); timer?.Stop(); lifetime.Cancel(); lyricRequest?.Cancel();
        SaveSettings();
        Shutdown();
    }
    protected override void OnExit(ExitEventArgs e)
    {
        lifetime.Cancel(); lyricRequest?.Cancel(); tray?.Dispose(); http.Dispose(); spotify.Dispose(); instance?.Dispose();
        base.OnExit(e);
    }
}
