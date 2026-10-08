using System.Text.Json;
namespace SurfLyrics.Windows;

// Private, current-user-only pipe. No credentials or track/lyric text cross it.
public sealed record SettingsRequest(string Action, Preferences? Settings = null, bool StartAtLogin = false);
public sealed record SettingsResponse(bool Success, string Message, Preferences? Settings = null, bool StartAtLogin = false);
