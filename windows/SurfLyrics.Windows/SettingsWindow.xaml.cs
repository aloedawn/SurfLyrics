using Microsoft.Win32;
using System.Windows;

namespace SurfLyrics.Windows;

public partial class SettingsWindow : Window
{
    private readonly App host;
    private const string StartupKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public SettingsWindow(App app)
    {
        host = app;
        InitializeComponent();
        var settings = app.Settings;
        SpotifySource.IsChecked = settings.SpotifyLyrics; LrclibSource.IsChecked = settings.Lrclib; MusixmatchSource.IsChecked = settings.Musixmatch;
        AutoConnect.IsChecked = settings.AutoConnectSpotify; OnTop.IsChecked = settings.AlwaysOnTop;
        TaskbarDisplay.IsChecked = settings.TaskbarLyrics; TaskbarFontSlider.Value = settings.TaskbarFontSize;
        FontSlider.Value = settings.FontSize; OffsetSlider.Value = settings.OffsetMs;
        using var key = Registry.CurrentUser.OpenSubKey(StartupKey);
        StartAtLogin.IsChecked = key?.GetValue("SurfLyrics") is string;
        UpdateLabels();
    }
    private void UpdateLabels()
    {
        if (FontLabel == null || OffsetLabel == null || FontSlider == null || OffsetSlider == null) return;
        FontLabel.Text = $"보조 가사 창 글자 크기 · {FontSlider.Value:0}";
        if (TaskbarFontLabel != null && TaskbarFontSlider != null) TaskbarFontLabel.Text = $"작업 표시줄 글자 크기 · {TaskbarFontSlider.Value:0}";
        OffsetLabel.Text = $"가사 시간 조정 · {OffsetSlider.Value / 1000:+0.0;-0.0;0.0}초";
    }
    private void SliderChanged(object sender, RoutedPropertyChangedEventArgs<double> e) => UpdateLabels();
    private async void ConnectSpotify(object sender, RoutedEventArgs e)
    {
        if (System.Windows.MessageBox.Show(this, "Spotify를 다시 시작하여 가사 연결을 준비합니다. 재생 중인 음악이 멈출 수 있습니다. 계속할까요?", "Spotify 가사 연결", MessageBoxButton.OKCancel, MessageBoxImage.Information) != MessageBoxResult.OK) return;
        ConnectButton.IsEnabled = false;
        ConnectionStatus.Text = "Spotify 연결 준비 중…";
        try { ConnectionStatus.Text = await host.ConnectSpotifyAsync(); }
        finally { ConnectButton.IsEnabled = true; }
    }
    private void Save(object sender, RoutedEventArgs e)
    {
        if (AutoConnect.IsChecked == true && !host.Settings.AutoConnectSpotify
            && System.Windows.MessageBox.Show(this, "자동 연결은 필요할 때 Spotify를 다시 시작합니다. 이 동작을 허용할까요?", "Spotify 자동 연결", MessageBoxButton.OKCancel, MessageBoxImage.Information) != MessageBoxResult.OK)
        { AutoConnect.IsChecked = false; return; }
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(StartupKey);
            if (StartAtLogin.IsChecked == true) key.SetValue("SurfLyrics", "\"" + Environment.ProcessPath + "\" --minimized");
            else key.DeleteValue("SurfLyrics", throwOnMissingValue: false);
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or System.Security.SecurityException or IOException)
        { System.Windows.MessageBox.Show(this, "Windows 시작 설정을 저장하지 못했습니다.", "SurfLyrics"); return; }
        var settings = host.Settings;
        settings.SpotifyLyrics = SpotifySource.IsChecked == true; settings.Lrclib = LrclibSource.IsChecked == true;
        settings.Musixmatch = MusixmatchSource.IsChecked == true; settings.AutoConnectSpotify = AutoConnect.IsChecked == true;
        settings.AlwaysOnTop = OnTop.IsChecked == true; settings.FontSize = FontSlider.Value; settings.OffsetMs = (int)OffsetSlider.Value;
        settings.TaskbarLyrics = TaskbarDisplay.IsChecked == true; settings.TaskbarFontSize = TaskbarFontSlider.Value;
        if (!host.SaveSettings()) { System.Windows.MessageBox.Show(this, "설정을 저장하지 못했습니다. 폴더 쓰기 권한을 확인해 주세요.", "SurfLyrics"); return; }
        host.ReloadLyrics(); host.Render(); Close();
    }
}
