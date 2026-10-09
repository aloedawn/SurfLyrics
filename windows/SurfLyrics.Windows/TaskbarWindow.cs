using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;


namespace SurfLyrics.Windows;

// A fixed, mouse-transparent surface over the primary taskbar. Only the glyphs
// move: resizing a layered HWND on each frame interrupts smooth composition.
// Explorer is never patched, injected into, or restarted.
public sealed class TaskbarWindow : Window
{
    private readonly TextBlock text;
    private readonly Canvas surface = new() { ClipToBounds = false, IsHitTestVisible = false };
    private readonly TranslateTransform position = new();
    private readonly LyricTextTransition transition;
    private readonly SpringTextMotion motion;
    private readonly App host;
    private nint handle;
    private DateTimeOffset nextLayout;
    private double destination, layoutScale;
    private Native.Rect placement;
    private int anchorRight;
    private bool hasPlacement;
    public bool TaskbarLocated { get; private set; }
    public bool ClickThrough { get; private set; }

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
        Focusable = false;
        IsHitTestVisible = false;
        Width = 40; Height = 32;
        text = new TextBlock { Text = "♫", Foreground = Brushes.White, FontFamily = LyricFont.Family, FontWeight = FontWeights.Light,
            TextTrimming = TextTrimming.None, TextWrapping = TextWrapping.NoWrap,
            RenderTransform = position, IsHitTestVisible = false };
        var outgoing = new TextBlock { Opacity = 0, TextTrimming = TextTrimming.None, TextWrapping = TextWrapping.NoWrap, IsHitTestVisible = false };
        surface.Children.Add(outgoing);
        surface.Children.Add(text);
        motion = new(position);
        Closed += (_, _) => motion.Dispose();
        Content = surface;
        transition = new(text, outgoing, () =>
        {
            UpdateFontSize();
            nextLayout = DateTimeOffset.UtcNow.AddMilliseconds(500);
            if (host.Settings.TaskbarLyrics) PositionBesideTray();
        });
        SourceInitialized += (_, _) =>
        {
            handle = new WindowInteropHelper(this).Handle;
            const long flags = 0x00000020 | 0x00000080 | 0x00080000 | 0x08000000;
            Native.SetWindowLongPtr(handle, -20, new nint(Native.GetWindowLongPtr(handle, -20).ToInt64() | flags));
            ClickThrough = (Native.GetWindowLongPtr(handle, -20).ToInt64() & flags) == flags;
            HwndSource.FromHwnd(handle)?.AddHook((nint hwnd, int message, nint wParam, nint lParam, ref bool handled) =>
            {
                if (message == 0x0084) { handled = true; return new nint(-1); } // HTTRANSPARENT
                if (message == 0x0021) { handled = true; return new nint(3); } // MA_NOACTIVATE
                return nint.Zero;
            });
        };
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
        if (!host.Settings.FadeLyrics || !SystemParameters.ClientAreaAnimation) FinishMotion();
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
        int height = bounds.Bottom - bounds.Top;
        int visibleHeight = Math.Min(bounds.Bottom, monitor.Monitor.Bottom) - Math.Max(bounds.Top, monitor.Monitor.Top);
        if (visibleHeight < 20 * scale) { HideDisplay(); return; }
        bool anchorChanged = !hasPlacement || !IsVisible || anchorRight != icons.Left
            || !placement.Equals(bounds) || layoutScale != scale;
        anchorRight = icons.Left; placement = bounds; layoutScale = scale;
        hasPlacement = true;
        if (anchorChanged)
        {
            Left = bounds.Left / scale; Top = bounds.Top / scale;
            Width = (bounds.Right - bounds.Left) / scale; Height = height / scale;
            if (!IsVisible) Show();
            Native.SetWindowPos(handle, new nint(-1), bounds.Left, bounds.Top,
                bounds.Right - bounds.Left, height, 0x0010 | 0x0040);
        }

        // Measure without a width constraint. The whole new line is drawn at the
        // previous X, even when it temporarily overlaps notification icons.
        text.Width = double.NaN;
        text.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        double width = Math.Max(16, text.DesiredSize.Width);
        text.Width = width;
        Canvas.SetTop(text, (height / scale - text.DesiredSize.Height) / 2);
        double target = (anchorRight - bounds.Left) / scale - 6 - width;
        if (anchorChanged || !host.Settings.FadeLyrics || !SystemParameters.ClientAreaAnimation)
        {
            destination = target;
            FinishMotion();
        }
        else if (destination != target)
        {
            destination = target;
            motion.MoveTo(target, animate: true);
        }
    }

    private void UpdateFontSize()
    {
        // The incoming line is measured immediately when its text changes.
        double size = text.Text == "♫" ? Math.Max(18, host.Settings.TaskbarFontSize) : host.Settings.TaskbarFontSize;
        if (text.FontSize == size) return;
        text.FontSize = size;
        nextLayout = default;
    }

    private void FinishMotion() => motion.MoveTo(destination, animate: false);

    private void HideDisplay()
    {
        FinishMotion();
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
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] internal static extern nint GetWindowLongPtr(nint window, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] internal static extern nint SetWindowLongPtr(nint window, int index, nint value);
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
