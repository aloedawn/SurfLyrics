using Windows.Media.Control;

namespace SurfLyrics.Windows;

public sealed record PlaybackSnapshot(MusicTrack Track, long PositionMs, bool IsPlaying, DateTimeOffset SampledAt)
{
    public long PositionNow => Math.Clamp(PositionMs + (IsPlaying ? (long)(DateTimeOffset.UtcNow - SampledAt).TotalMilliseconds : 0),
        0, Track.DurationMs > 0 ? Track.DurationMs : 86_400_000);
}

public sealed class MediaSessionReader
{
    private GlobalSystemMediaTransportControlsSessionManager? manager;
    private GlobalSystemMediaTransportControlsSession? selected;
    public int SupportedSessionCount { get; private set; }

    private static string? Player(string id) => id.Contains("spotify", StringComparison.OrdinalIgnoreCase) ? "Spotify"
        : id.Contains("AppleMusic", StringComparison.OrdinalIgnoreCase) || id.Contains("iTunes", StringComparison.OrdinalIgnoreCase) ? "Apple Music" : null;

    public async Task<PlaybackSnapshot?> ReadAsync(CancellationToken ct)
    {
        manager ??= await GlobalSystemMediaTransportControlsSessionManager.RequestAsync().AsTask(ct).WaitAsync(TimeSpan.FromSeconds(5), ct);
        var sessions = manager.GetSessions().Where(s => Player(s.SourceAppUserModelId) != null).ToArray();
        SupportedSessionCount = sessions.Length;
        var currentId = manager.GetCurrentSession()?.SourceAppUserModelId;
        // A playing supported session wins over a paused one; preserve Windows' selected app on ties.
        var session = sessions.OrderByDescending(s => s.GetPlaybackInfo().PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing)
            .ThenByDescending(s => s.SourceAppUserModelId == currentId).FirstOrDefault();
        if (session == null) { selected = null; return null; }
        var info = await session.TryGetMediaPropertiesAsync().AsTask(ct).WaitAsync(TimeSpan.FromSeconds(3), ct);
        var playback = session.GetPlaybackInfo();
        var timeline = session.GetTimelineProperties();
        selected = session;
        if (string.IsNullOrWhiteSpace(info.Title)) return null;
        bool playing = playback.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;
        long duration = Math.Max(0, (long)(timeline.EndTime - timeline.StartTime).TotalMilliseconds);
        long position = Math.Max(0, (long)(timeline.Position - timeline.StartTime).TotalMilliseconds);
        var now = DateTimeOffset.UtcNow;
        // A zero/default timestamp is reported by some players and must never extrapolate from 1601.
        if (playing && timeline.LastUpdatedTime.Year >= 2000 && timeline.LastUpdatedTime <= now)
            position += (long)Math.Min(86_400_000, (now - timeline.LastUpdatedTime).TotalMilliseconds);
        return new(new(Player(session.SourceAppUserModelId)!, info.Title.Trim(), info.Artist.Trim(), info.AlbumTitle.Trim(), duration),
            Math.Clamp(position, 0, duration > 0 ? duration : 86_400_000), playing, now);
    }

    public async Task TogglePlaybackAsync()
    {
        if (selected != null) await selected.TryTogglePlayPauseAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(3));
    }
}
