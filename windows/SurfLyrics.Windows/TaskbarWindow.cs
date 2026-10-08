using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;

namespace SurfLyrics.Windows;

// A transparent, non-activating window positioned beside the notification area.
// Explorer is never patched, injected into, or restarted.
public sealed class TaskbarWindow : Window
{
    private readonly TextBlock text;
    private readonly LyricTextTransition transition;
    private readonly App host;
    private nint handle;
    private DateTimeOffset nextLayout;
    public bool TaskbarLocated { get; private set; }

    public TaskbarWindow(App app)
    {
        host = app;
        Title = "SurfLyrics 작업 표시줄 가사";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Width = 40; Height = 32;
        text = new TextBlock { Text = "♫", Foreground = Brushes.White, FontFamily = new FontFamily("Segoe UI, Malgun Gothic"),
            VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap, Margin = new Thickness(6, 0, 6, 0) };
        Content = text;
        transition = new(text, () => nextLayout = default);
        Cursor = Cursors.Hand;
        SourceInitialized += (_, _) =>
        {
            handle = new WindowInteropHelper(this).Handle;
            var source = HwndSource.FromHwnd(handle);
            source?.AddHook((nint hwnd, int message, nint wParam, nint lParam, ref bool handled) =>
            {
                if (message == 0x0021) { handled = true; return new nint(3); } // MA_NOACTIVATE
                return nint.Zero;
            });
        };
        MouseLeftButtonUp += (_, _) => OpenMenu();
        MouseRightButtonUp += (_, _) => OpenMenu();
    }

    private void OpenMenu()
    {
        var menu = new ContextMenu();
        void Add(string label, Action action)
        {
            var item = new MenuItem { Header = label };
            item.Click += (_, _) => action(); menu.Items.Add(item);
        }
        Add("가사 창 표시 / 숨기기", host.ToggleWindow);
        Add("설정", host.OpenSettings);
        Add("재생 / 일시정지", () => _ = host.TogglePlaybackAsync());
        Add("가사 다시 불러오기", host.ReloadLyrics);
        menu.Items.Add(new Separator());
        Add("종료", host.ExitApp);
        menu.PlacementTarget = text;
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint;
        menu.IsOpen = true;
    }

    public void Render(PlaybackSnapshot? playback, TimedLyrics? lyrics, bool loading)
    {
        if (!host.Settings.TaskbarLyrics) { if (IsVisible) Hide(); return; }
        int index = lyrics?.IndexAt((playback?.PositionNow ?? 0) + host.Settings.OffsetMs) ?? -1;
        var line = index >= 0 ? lyrics!.Lines[index].Text : null;
        string value = line != null ? TimedLyrics.IsInstrumental(line) ? "♫" : line
            : playback != null ? "♫ " + playback.Track.Title + " — " + playback.Track.Artist : "♫";
        transition.SetText(value, host.Settings.FadeLyrics);
        text.FontSize = value == "♫" ? Math.Max(18, host.Settings.TaskbarFontSize) : host.Settings.TaskbarFontSize;
        ToolTip = playback == null ? "SurfLyrics · Spotify 또는 Apple Music에서 음악을 재생해 주세요"
            : playback.Track.Title + " — " + playback.Track.Artist + "\n" + (loading ? "가사를 찾는 중…" : lyrics?.Source ?? "동기화 가사 없음") + "\n클릭하여 메뉴 열기";
        if (DateTimeOffset.UtcNow < nextLayout) return;
        nextLayout = DateTimeOffset.UtcNow.AddMilliseconds(500);
        PositionBesideTray();
    }

    private void PositionBesideTray()
    {
        var bar = Native.FindWindow("Shell_TrayWnd", null);
        var tray = Native.FindWindowEx(bar, nint.Zero, "TrayNotifyWnd", null);
        TaskbarLocated = bar != nint.Zero && tray != nint.Zero;
        if (!TaskbarLocated || !Native.IsWindowVisible(bar)
            || !Native.GetWindowRect(bar, out var bounds) || !Native.GetWindowRect(tray, out var icons)
            || bounds.Right - bounds.Left <= bounds.Bottom - bounds.Top || Native.ForegroundIsFullscreen(bar))
        { if (IsVisible) Hide(); return; }
        var monitor = new Native.MonitorInfo { Size = Marshal.SizeOf<Native.MonitorInfo>() };
        if (!Native.GetMonitorInfo(Native.MonitorFromWindow(bar, 2), ref monitor)) return;
        double scale = Native.GetDpiForWindow(bar) / 96.0;
        if (scale <= 0) scale = 1;
        int visibleHeight = Math.Min(bounds.Bottom, monitor.Monitor.Bottom) - Math.Max(bounds.Top, monitor.Monitor.Top);
        if (visibleHeight < 20 * scale) { if (IsVisible) Hide(); return; }
        text.Measure(new Size(420, Math.Max(24, (bounds.Bottom - bounds.Top) / scale)));
        int width = (int)Math.Ceiling(Math.Clamp(text.DesiredSize.Width, 28, 440) * scale);
        int right = icons.Left;
        int left = right - width;
        if (left < bounds.Left + 200 * scale) { if (IsVisible) Hide(); return; }
        Width = width / scale; Height = (bounds.Bottom - bounds.Top) / scale;
        if (!IsVisible) Show();
        Native.SetWindowPos(handle, new nint(-1), left, bounds.Top, width, bounds.Bottom - bounds.Top, 0x0010 | 0x0040);
    }

    private static class Native
    {
        [StructLayout(LayoutKind.Sequential)] internal struct Rect { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] internal struct MonitorInfo { public int Size; public Rect Monitor, Work; public uint Flags; }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern nint FindWindow(string className, string? title);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern nint FindWindowEx(nint parent, nint after, string className, string? title);
        [DllImport("user32.dll")] internal static extern bool GetWindowRect(nint window, out Rect rect);
        [DllImport("user32.dll")] internal static extern bool IsWindowVisible(nint window);
        [DllImport("user32.dll")] internal static extern uint GetDpiForWindow(nint window);
        [DllImport("user32.dll")] internal static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
        [DllImport("user32.dll")] internal static extern nint GetForegroundWindow();
        [DllImport("user32.dll")] internal static extern nint MonitorFromWindow(nint window, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(nint window, StringBuilder className, int max);
        internal static bool ForegroundIsFullscreen(nint bar)
        {
            var foreground = GetForegroundWindow();
            if (foreground == nint.Zero || foreground == bar) return false;
            var name = new StringBuilder(128); GetClassName(foreground, name, name.Capacity);
            if (name.ToString() is "Progman" or "WorkerW" or "Shell_TrayWnd") return false;
            if (!GetWindowRect(foreground, out var rect)) return false;
            var monitor = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
            if (!GetMonitorInfo(MonitorFromWindow(bar, 2), ref monitor)) return false;
            return rect.Left <= monitor.Monitor.Left && rect.Top <= monitor.Monitor.Top
                && rect.Right >= monitor.Monitor.Right && rect.Bottom >= monitor.Monitor.Bottom;
        }
    }
}
