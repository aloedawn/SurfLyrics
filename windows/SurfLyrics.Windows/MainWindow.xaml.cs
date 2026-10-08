using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using System.Windows.Controls.Primitives;

namespace SurfLyrics.Windows;

public partial class MainWindow : Window
{
    private App Host => (App)System.Windows.Application.Current;
    public MainWindow(Preferences settings)
    {
        InitializeComponent();
        Width = settings.Width; Height = settings.Height;
        Topmost = settings.AlwaysOnTop;
        var area = SystemParameters.WorkArea;
        Left = settings.Left is double x && double.IsFinite(x) && x + Width > area.Left && x < area.Right ? x : area.Right - Width - 30;
        Top = settings.Top is double y && double.IsFinite(y) && y + Height > area.Top && y < area.Bottom ? y : area.Bottom - Height - 30;
        PinButton.Opacity = Topmost ? 1 : .5;
    }

    public void Render(PlaybackSnapshot? playback, TimedLyrics? lyrics, bool loading, string? issue)
    {
        var settings = Host.Settings;
        Topmost = settings.AlwaysOnTop;
        PinButton.Opacity = Topmost ? 1 : .5;
        LyricText.FontSize = settings.FontSize;
        PlaybackButton.IsEnabled = playback != null;
        PlaybackButton.Content = playback?.IsPlaying == true ? "일시정지" : "재생";
        if (playback == null)
        {
            LyricText.Text = "♫"; LyricText.FontSize = 42;
            NextText.Text = issue ?? "Spotify 또는 Apple Music에서 음악을 재생해 주세요";
            TrackText.Text = "음악을 기다리는 중";
            SourceText.Text = "동기화 가사 · Spotify / LRCLIB / Musixmatch";
            TrackProgress.Value = 0;
            return;
        }
        var track = playback.Track;
        TrackText.Text = track.Title + (track.Artist.Length > 0 ? " — " + track.Artist : "");
        SourceText.Text = track.Player + " · " + (loading ? "가사를 찾는 중…" : lyrics?.Source ?? issue ?? "동기화 가사 없음") + (playback.IsPlaying ? "" : " · 일시정지");
        long position = playback.PositionNow + settings.OffsetMs;
        int index = lyrics?.IndexAt(position) ?? -1;
        string current = index >= 0 ? lyrics!.Lines[index].Text : "";
        LyricText.Text = TimedLyrics.IsInstrumental(current) ? "♫" : current;
        if (LyricText.Text == "♫") LyricText.FontSize = 42;
        NextText.Text = lyrics != null && index + 1 < lyrics.Lines.Count
            ? lyrics.Lines[index + 1].Text : loading ? "가사를 불러오고 있습니다" : lyrics == null ? "음악을 들으며 잠시 기다려 주세요" : "";
        TrackProgress.Value = track.DurationMs > 0 ? Math.Clamp(playback.PositionNow * 100.0 / track.DurationMs, 0, 100) : 0;
    }

    private void DragWindow(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject target)
            for (DependencyObject? item = target; item != null; item = System.Windows.Media.VisualTreeHelper.GetParent(item))
                if (item is ButtonBase) return;
        if (e.LeftButton == MouseButtonState.Pressed) DragMove();
    }
    private void TogglePin(object sender, RoutedEventArgs e) { Host.Settings.AlwaysOnTop = !Host.Settings.AlwaysOnTop; Host.SaveSettings(); Host.Render(); }
    private void OpenSettings(object sender, RoutedEventArgs e) => Host.OpenSettings();
    private void HideWindow(object sender, RoutedEventArgs e) => Hide();
    private async void TogglePlayback(object sender, RoutedEventArgs e) => await Host.TogglePlaybackAsync();
    private void WindowClosing(object? sender, CancelEventArgs e)
    {
        Host.Settings.Left = Left; Host.Settings.Top = Top; Host.Settings.Width = Width; Host.Settings.Height = Height;
        Host.SaveSettings();
        if (!Host.Exiting) { e.Cancel = true; Hide(); }
    }
}
