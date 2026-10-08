using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

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
    private readonly DispatcherTimer motionTimer;
    private long motionStarted;
    private double motionFrom, motionTo, currentWidth, layoutScale;
    private int anchorRight, anchorTop, anchorHeight;
    private bool hasPlacement;
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
        text = new TextBlock { Text = "♫", Foreground = Brushes.White, FontFamily = LyricFont.Family,
            VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap, Margin = new Thickness(6, 0, 6, 0) };
        Content = text;
        motionTimer = new DispatcherTimer(DispatcherPriority.Render, Dispatcher) { Interval = TimeSpan.FromMilliseconds(16) };
        motionTimer.Tick += (_, _) => AnimateWidth();
        Closed += (_, _) => motionTimer.Stop();
        transition = new(text, () =>
        {
            UpdateFontSize();
            nextLayout = DateTimeOffset.UtcNow.AddMilliseconds(500);
            if (host.Settings.TaskbarLyrics) PositionBesideTray();
        });
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
        var menu = NativeMenu.Create();
        void Add(string label, Action action) => menu.Items.Add(label,null,(_,_) => action());
        Add("가사 창 표시 / 숨기기",host.ToggleWindow);
        Add("설정",host.OpenSettings);
        Add("재생 / 일시정지",() => _ = host.TogglePlaybackAsync());
        Add("가사 다시 불러오기",host.ReloadLyrics);
        menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
        Add("종료",host.ExitApp);
        menu.Closed += (_,_) => Dispatcher.BeginInvoke(new Action(menu.Dispose));
        menu.Show(System.Windows.Forms.Cursor.Position);
    }

    public void Render(PlaybackSnapshot? playback, TimedLyrics? lyrics, bool loading)
    {
        if (!host.Settings.TaskbarLyrics) { HideDisplay(); return; }
        int index = lyrics?.IndexAt((playback?.PositionNow ?? 0) + host.Settings.OffsetMs) ?? -1;
        var line = index >= 0 ? lyrics!.Lines[index].Text : null;
        string value = line != null ? TimedLyrics.IsInstrumental(line) ? "♫" : line
            : playback != null ? "♫ " + playback.Track.Title + " — " + playback.Track.Artist : "♫";
        transition.SetText(value, host.Settings.FadeLyrics);
        UpdateFontSize();
        if (!host.Settings.FadeLyrics && motionTimer.IsEnabled) FinishMotion();
        ToolTip = playback == null ? "SurfLyrics · Spotify 또는 Apple Music에서 음악을 재생해 주세요"
            : playback.Track.Title + " — " + playback.Track.Artist + "\n" + (loading ? "가사를 찾는 중…" : lyrics?.Source ?? "동기화 가사 없음") + "\n클릭하여 메뉴 열기";
        if (DateTimeOffset.UtcNow < nextLayout) return;
        nextLayout = DateTimeOffset.UtcNow.AddMilliseconds(500);
        PositionBesideTray();
    }

    private void PositionBesideTray()
    {
        using var coordinates = new Native.PhysicalPixels();
        var bar = Native.FindWindow("Shell_TrayWnd", null);
        var tray = Native.FindWindowEx(bar, nint.Zero, "TrayNotifyWnd", null);
        TaskbarLocated = bar != nint.Zero && tray != nint.Zero;
        if (!TaskbarLocated || !Native.IsWindowVisible(bar)
            || !Native.GetWindowRect(bar, out var bounds) || !Native.GetWindowRect(tray, out var icons)
            || bounds.Right - bounds.Left <= bounds.Bottom - bounds.Top || Native.ForegroundIsFullscreen(bar))
        { HideDisplay(); return; }
        var monitor = new Native.MonitorInfo { Size = Marshal.SizeOf<Native.MonitorInfo>() };
        if (!Native.GetMonitorInfo(Native.MonitorFromWindow(bar, 2), ref monitor)) return;
        double scale = Native.GetDpiForWindow(bar) / 96.0;
        if (scale <= 0) scale = 1;
        int visibleHeight = Math.Min(bounds.Bottom, monitor.Monitor.Bottom) - Math.Max(bounds.Top, monitor.Monitor.Top);
        if (visibleHeight < 20 * scale) { HideDisplay(); return; }
        text.Measure(new Size(420, Math.Max(24, (bounds.Bottom - bounds.Top) / scale)));
        int width = (int)Math.Ceiling(Math.Clamp(text.DesiredSize.Width, 28, 440) * scale);
        int right = icons.Left;
        int left = right - width;
        if (left < bounds.Left + 200 * scale) { HideDisplay(); return; }
        int height = bounds.Bottom - bounds.Top;
        bool anchorChanged = !hasPlacement || !IsVisible || anchorRight != right
            || anchorTop != bounds.Top || anchorHeight != height || layoutScale != scale;
        anchorRight = right; anchorTop = bounds.Top; anchorHeight = height; layoutScale = scale;
        hasPlacement = true;
        if (anchorChanged || !host.Settings.FadeLyrics || !SystemParameters.ClientAreaAnimation)
        {
            motionTo = width;
            FinishMotion();
        }
        else if (motionTo != width)
        {
            // Retarget from the visible width, including during a rapid seek.
            motionFrom = currentWidth; motionTo = width;
            motionStarted = Stopwatch.GetTimestamp();
            motionTimer.Start();
        }
    }

    private void UpdateFontSize()
    {
        // Keep the old line's metrics until the fade swaps the displayed text.
        double size = text.Text == "♫" ? Math.Max(18, host.Settings.TaskbarFontSize) : host.Settings.TaskbarFontSize;
        if (text.FontSize == size) return;
        text.FontSize = size;
        nextLayout = default;
    }

    private void AnimateWidth()
    {
        double progress = Math.Clamp(Stopwatch.GetElapsedTime(motionStarted).TotalMilliseconds / 220, 0, 1);
        double eased = progress * progress * (3 - 2 * progress);
        ApplyWidth(motionFrom + (motionTo - motionFrom) * eased);
        if (progress >= 1) motionTimer.Stop();
    }

    private void FinishMotion()
    {
        motionTimer.Stop();
        ApplyWidth(motionTo);
    }

    private void ApplyWidth(double width)
    {
        using var coordinates = new Native.PhysicalPixels();
        currentWidth = width;
        int pixels = (int)Math.Round(width);
        if (!IsVisible)
        {
            Left = (anchorRight - pixels) / layoutScale; Top = anchorTop / layoutScale;
            Width = pixels / layoutScale; Height = anchorHeight / layoutScale;
            Show();
        }
        // Move and resize atomically in physical pixels. The tray-side edge
        // stays fixed throughout both growing and shrinking transitions.
        Native.SetWindowPos(handle, new nint(-1), anchorRight - pixels, anchorTop, pixels, anchorHeight, 0x0010 | 0x0040);
    }

    private void HideDisplay()
    {
        motionTimer.Stop();
        hasPlacement = false;
        if (IsVisible) Hide();
    }

    private static class Native
    {
        // WinForms tray callbacks can use a different DPI awareness context.
        // Keep every native move/read in the same physical coordinate space.
        internal readonly struct PhysicalPixels : IDisposable
        {
            private readonly nint previous;
            public PhysicalPixels() => previous = SetThreadDpiAwarenessContext(new nint(-4));
            public void Dispose() { if (previous != nint.Zero) SetThreadDpiAwarenessContext(previous); }
        }
        [DllImport("user32.dll")] private static extern nint SetThreadDpiAwarenessContext(nint context);
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
