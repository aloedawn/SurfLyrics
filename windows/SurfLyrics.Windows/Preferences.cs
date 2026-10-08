using System.Text.Json;
namespace SurfLyrics.Windows;

public sealed class Preferences
{
    public bool SpotifyLyrics { get; set; } = true;
    public bool Lrclib { get; set; } = true;
    public bool Musixmatch { get; set; } = true;
    public bool AutoConnectSpotify { get; set; }
    public bool TaskbarLyrics { get; set; } = true;
    public bool FadeLyrics { get; set; } = true;
    public double TaskbarFontSize { get; set; } = 13;
    public int OffsetMs { get; set; }
    private static string FilePath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SurfLyrics", "settings.json");

    public static Preferences Load()
    {
        try
        {
            var settings = JsonSerializer.Deserialize<Preferences>(File.ReadAllText(FilePath)) ?? new();
            settings.TaskbarFontSize = double.IsFinite(settings.TaskbarFontSize) ? Math.Clamp(settings.TaskbarFontSize, 10, 18) : 13;
            settings.OffsetMs = Math.Clamp(settings.OffsetMs, -5000, 5000);
            return settings;
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException) { return new(); }
    }

    public bool Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath + ".tmp", JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(FilePath + ".tmp", FilePath, overwrite: true);
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return false; }
    }
}
