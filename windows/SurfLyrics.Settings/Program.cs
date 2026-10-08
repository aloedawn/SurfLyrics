using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using SurfLyrics.Windows;
using Windows.Graphics;

namespace SurfLyrics.SettingsUi;

internal static class Program
{
    internal static string PipeName = "";
    [STAThread]
    static void Main(string[] args)
    {
        if (args.Length != 2 || args[0] != "--pipe" || !args[1].StartsWith("SurfLyrics.Settings.", StringComparison.Ordinal)) return;
        PipeName = args[1];
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(initialization =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new SettingsApp();
        });
    }
}
public sealed partial class SettingsApp : Application
{
    private SettingsWindow? window;
    public SettingsApp() { InitializeComponent(); }
    protected override void OnLaunched(LaunchActivatedEventArgs args) { window = new SettingsWindow(); window.Activate(); }
}
internal sealed class SettingsWindow : Window
{
    private readonly StackPanel content = new() { Spacing = 16, Padding = new Thickness(28, 24, 28, 28) };
    private readonly ToggleSwitch spotify = Toggle("Spotify 클라이언트"), lrclib = Toggle("LRCLIB"), musixmatch = Toggle("Musixmatch");
    private readonly ToggleSwitch autoConnect = Toggle("Spotify 자동 연결"), taskbar = Toggle("작업 표시줄에 가사 표시"), fade = Toggle("가사 전환 시 페이드"), onTop = Toggle("보조 가사 창 항상 위에"), startup = Toggle("Windows 로그인 시 실행");
    private readonly Slider taskbarSize = Slider(10,18,1), windowSize = Slider(18,44,1), offset = Slider(-5000,5000,100);
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly Button connect = new() { Content = "Spotify 연결", HorizontalAlignment = HorizontalAlignment.Left };
    private readonly Button save = new() { Content = "저장", HorizontalAlignment = HorizontalAlignment.Right };
    private Preferences original = new();

    public SettingsWindow()
    {
        Title = "SurfLyrics 설정";
        SystemBackdrop = new MicaBackdrop();
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var appWindow = AppWindow.GetFromWindowId(Win32Interop.GetWindowIdFromWindow(handle));
        appWindow.Resize(new SizeInt32(520,820));
        appWindow.SetIcon(Path.Combine(AppContext.BaseDirectory,"Assets","SurfLyrics.ico"));
        content.ActualThemeChanged += (_,_) => ApplyTitlebarTheme(handle);
        content.Loaded += (_,_) => ApplyTitlebarTheme(handle);
        var scroll = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Content = scroll;
        Heading("SurfLyrics", 28);
        content.Children.Add(new TextBlock { Text = "설정", FontSize = 16, Opacity = .7 });
        Section("가사 소스", spotify, lrclib, musixmatch);
        content.Children.Add(connect);
        content.Children.Add(status);
        content.Children.Add(autoConnect);
        content.Children.Add(new TextBlock { Text = "자동 연결을 켜면 필요할 때 Spotify를 다시 시작합니다. 로컬 연결은 이 PC에서만 열립니다.", TextWrapping = TextWrapping.Wrap, Opacity = .7, FontSize = 12 });
        Section("가사 표시", taskbar, fade);
        LabeledSlider("작업 표시줄 글자 크기", taskbarSize, value => value.ToString("0"));
        LabeledSlider("보조 가사 창 글자 크기", windowSize, value => value.ToString("0"));
        content.Children.Add(onTop);
        LabeledSlider("가사 시간 조정", offset, value => (value / 1000).ToString("+0.0;-0.0;0.0") + "초");
        Section("시작", startup);
        content.Children.Add(save);
        connect.Click += async (_, _) => await ConnectAsync();
        save.Click += async (_, _) => await SaveAsync();
        content.Loaded += async (_, _) => await LoadAsync();
        save.IsEnabled = false; connect.IsEnabled = false;
    }
    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(nint hwnd,int attribute,ref int value,int size);
    private void ApplyTitlebarTheme(nint hwnd)
    {
        int dark = content.ActualTheme == ElementTheme.Dark ? 1 : 0;
        DwmSetWindowAttribute(hwnd,20,ref dark,sizeof(int));
    }
    private static ToggleSwitch Toggle(string text) => new() { Header = text, OnContent = "켬", OffContent = "끔" };
    private static Slider Slider(double min,double max,double step) => new() { Minimum = min, Maximum = max, StepFrequency = step, HorizontalAlignment = HorizontalAlignment.Stretch };
    private void Heading(string text,double size) => content.Children.Add(new TextBlock { Text = text, FontSize = size, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
    private void Section(string text,params UIElement[] controls)
    {
        Heading(text,18);
        foreach (var control in controls) content.Children.Add(control);
    }
    private void LabeledSlider(string text,Slider slider,Func<double,string> format)
    {
        var label = new TextBlock { Text = text };
        slider.ValueChanged += (_,_) => label.Text = text + " · " + format(slider.Value);
        content.Children.Add(label); content.Children.Add(slider);
    }
    private async Task<SettingsResponse> RequestAsync(SettingsRequest request)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(45));
        using var pipe = new NamedPipeClientStream(".", Program.PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        await pipe.ConnectAsync(timeout.Token);
        using var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen:true) { AutoFlush = true };
        using var reader = new StreamReader(pipe, Encoding.UTF8, leaveOpen:true);
        await writer.WriteLineAsync(JsonSerializer.Serialize(request));
        var line = await reader.ReadLineAsync(timeout.Token) ?? throw new IOException("설정 연결이 종료되었습니다.");
        if (line.Length > 16_384) throw new IOException("설정 응답이 너무 큽니다.");
        return JsonSerializer.Deserialize<SettingsResponse>(line) ?? throw new IOException("설정 응답을 읽지 못했습니다.");
    }
    private async Task LoadAsync()
    {
        try
        {
            var response = await RequestAsync(new("get"));
            original = response.Settings ?? throw new IOException(response.Message);
            spotify.IsOn = original.SpotifyLyrics; lrclib.IsOn = original.Lrclib; musixmatch.IsOn = original.Musixmatch;
            autoConnect.IsOn = original.AutoConnectSpotify; taskbar.IsOn = original.TaskbarLyrics; fade.IsOn = original.FadeLyrics;
            onTop.IsOn = original.AlwaysOnTop; startup.IsOn = response.StartAtLogin;
            taskbarSize.Value = original.TaskbarFontSize; windowSize.Value = original.FontSize; offset.Value = original.OffsetMs;
            save.IsEnabled = true; connect.IsEnabled = true;
        }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or JsonException or UnauthorizedAccessException)
        { status.Text = "설정 연결을 열지 못했습니다. SurfLyrics를 다시 실행해 주세요."; }
    }
    private async Task<bool> ConfirmAsync(string title,string message)
    {
        var dialog = new ContentDialog { Title = title, Content = message, PrimaryButtonText = "계속", CloseButtonText = "취소", DefaultButton = ContentDialogButton.Close, XamlRoot = content.XamlRoot };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }
    private async Task ConnectAsync()
    {
        if (!await ConfirmAsync("Spotify 가사 연결", "Spotify를 다시 시작할 수 있으며 재생이 멈출 수 있습니다. 같은 PC의 앱에서 로그인된 Spotify에 접근할 수 있는 로컬 디버깅 연결을 엽니다.")) return;
        connect.IsEnabled = false; save.IsEnabled = false; status.Text = "Spotify 연결 준비 중…";
        try { status.Text = (await RequestAsync(new("connect"))).Message; }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or JsonException) { status.Text = "Spotify 연결을 완료하지 못했습니다."; }
        finally { connect.IsEnabled = true; save.IsEnabled = true; }
    }
    private async Task SaveAsync()
    {
        if (autoConnect.IsOn && !original.AutoConnectSpotify && !await ConfirmAsync("Spotify 자동 연결", "필요할 때 Spotify를 다시 시작하여 로그인된 Spotify의 로컬 디버깅 연결을 엽니다. 자동 연결을 허용할까요?")) return;
        save.IsEnabled = false;
        var value = new Preferences { SpotifyLyrics = spotify.IsOn, Lrclib = lrclib.IsOn, Musixmatch = musixmatch.IsOn,
            AutoConnectSpotify = autoConnect.IsOn, TaskbarLyrics = taskbar.IsOn, FadeLyrics = fade.IsOn,
            AlwaysOnTop = onTop.IsOn, TaskbarFontSize = taskbarSize.Value, FontSize = windowSize.Value, OffsetMs = (int)offset.Value };
        try
        {
            var response = await RequestAsync(new("save",value,startup.IsOn));
            if (response.Success) Close(); else status.Text = response.Message;
        }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or JsonException) { status.Text = "설정을 저장하지 못했습니다."; }
        finally { save.IsEnabled = true; }
    }
}
