using System.Runtime.InteropServices;
using System.Windows.Media.Animation;

namespace SurfLyrics.Windows;

internal static class AnimationCadence
{
    private static DateTimeOffset nextRefresh;
    private static int? frameRate;

    internal static void Apply(Timeline animation)
    {
        if (DateTimeOffset.UtcNow >= nextRefresh)
        {
            nextRefresh = DateTimeOffset.UtcNow.AddSeconds(5);
            frameRate = PrimaryRefreshRate();
        }
        // Let WPF schedule animation frames at the display rate, without a
        // DispatcherTimer or an arbitrary 30/60 FPS limit on high refresh panels.
        Timeline.SetDesiredFrameRate(animation, frameRate);
    }

    private static int? PrimaryRefreshRate()
    {
        const int modeSize = 220; // DEVMODEW; dmDisplayFrequency is at byte 184.
        var mode = Marshal.AllocHGlobal(modeSize);
        try
        {
            Marshal.Copy(new byte[modeSize], 0, mode, modeSize);
            Marshal.WriteInt16(mode, 68, modeSize);
            if (!EnumDisplaySettings(null, -1, mode)) return null;
            int rate = Marshal.ReadInt32(mode, 184);
            return rate > 1 ? rate : null; // 0/1 mean the driver's default refresh rate.
        }
        finally { Marshal.FreeHGlobal(mode); }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplaySettings(string? device, int modeNumber, nint mode);
}