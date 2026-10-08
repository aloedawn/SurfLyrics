using System.IO.Pipes;
using Microsoft.Win32;

namespace SurfLyrics.Windows;
public partial class App
{
    private readonly string settingsPipe = "SurfLyrics.Settings." + Guid.NewGuid().ToString("N");
    private Process? settingsProcess;
    private bool settingsReady;
    private const string StartupKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    private async Task ServeSettingsAsync()
    {
        while (!lifetime.IsCancellationRequested)
        {
            try
            {
                using var pipe = new NamedPipeServerStream(settingsPipe, PipeDirection.InOut, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(lifetime.Token);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                timeout.CancelAfter(TimeSpan.FromSeconds(45));
                using var reader = new StreamReader(pipe, Encoding.UTF8, leaveOpen:true);
                using var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen:true) { AutoFlush = true };
                var line = await reader.ReadLineAsync(timeout.Token);
                if (line == null || line.Length > 16_384) continue;
                var request = JsonSerializer.Deserialize<SettingsRequest>(line);
                if (request == null) continue;
                var response = await HandleSettingsAsync(request);
                await writer.WriteLineAsync(JsonSerializer.Serialize(response));
            }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { break; }
            catch (Exception ex) when (ex is IOException or OperationCanceledException or JsonException or UnauthorizedAccessException)
            { /* A closed settings window does not affect playback. */ }
        }
    }
    private async Task<SettingsResponse> HandleSettingsAsync(SettingsRequest request)
    {
        if (request.Action == "get")
        {
            using var key = Registry.CurrentUser.OpenSubKey(StartupKey);
            settingsReady = true;
            return new(true,"",Settings,key?.GetValue("SurfLyrics") is string);
        }
        if (request.Action == "connect") return new(true, await ConnectSpotifyAsync());
        if (request.Action != "save" || request.Settings is not Preferences next) return new(false,"잘못된 설정 요청입니다.");
        if (!double.IsFinite(next.TaskbarFontSize) || next.TaskbarFontSize is <10 or >18 || next.OffsetMs is <-5000 or >5000)
            return new(false,"설정 값이 허용 범위를 벗어났습니다.");
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(StartupKey);
            if (request.StartAtLogin) key.SetValue("SurfLyrics", "\"" + Environment.ProcessPath + "\" --minimized");
            else key.DeleteValue("SurfLyrics",throwOnMissingValue:false);
            if (!next.Save()) return new(false,"설정을 저장하지 못했습니다.");
            Settings = next; ReloadLyrics(); Render();
            return new(true,"설정을 저장했습니다.");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        { return new(false,"Windows 시작 설정을 저장하지 못했습니다."); }
    }
    public void OpenSettings()
    {
        if (settingsProcess is { HasExited:false })
        {
            settingsProcess.Refresh();
            if (settingsProcess.MainWindowHandle != nint.Zero) SettingsNative.SetForegroundWindow(settingsProcess.MainWindowHandle);
            return;
        }
        var path = Path.Combine(AppContext.BaseDirectory,"Settings","SurfLyrics.Settings.exe");
        if (!File.Exists(path)) { System.Windows.MessageBox.Show("Settings 폴더가 없습니다. SurfLyrics 배포 폴더 전체를 함께 보관해 주세요.","SurfLyrics"); return; }
        settingsProcess?.Dispose();
        var info = new ProcessStartInfo(path) { UseShellExecute=false };
        info.ArgumentList.Add("--pipe"); info.ArgumentList.Add(settingsPipe);
        settingsReady = false;
        settingsProcess = Process.Start(info);
    }
    private void CloseSettings()
    {
        if (settingsProcess is { HasExited:false }) settingsProcess.Kill();
        settingsProcess?.Dispose(); settingsProcess = null;
    }
    private static class SettingsNative
    {
        [System.Runtime.InteropServices.DllImport("user32.dll")] internal static extern bool SetForegroundWindow(nint hwnd);
    }
}
