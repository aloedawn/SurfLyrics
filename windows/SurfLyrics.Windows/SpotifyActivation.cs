using System.Runtime.InteropServices;
using Windows.Management.Deployment;

namespace SurfLyrics.Windows;
internal static class SpotifyActivation
{
    internal sealed record Installation(string? Executable, string? AppId, string Directory);
    internal static Installation? Find(string? runningPath)
    {
        var regular = runningPath ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),"Spotify","Spotify.exe");
        if (File.Exists(regular) && !regular.Contains("\\WindowsApps\\",StringComparison.OrdinalIgnoreCase)) return new(regular,null,Path.GetDirectoryName(regular)!);
        // Store executables cannot be started directly. Use the package's main
        // app entry (migrator), which forwards arguments to its desktop process.
        try
        {
            var package = new PackageManager().FindPackagesForUser("").FirstOrDefault(p => p.Id.Name == "SpotifyAB.SpotifyMusic");
            if (package != null) return new(null,package.Id.FamilyName + "!Spotify",package.InstalledLocation.Path);
        }
        catch (Exception ex) when (ex is COMException or UnauthorizedAccessException) { }
        return null;
    }
    internal static bool Matches(Installation installation,string executable) => string.Equals(Path.Combine(installation.Directory,"Spotify.exe"),executable,StringComparison.OrdinalIgnoreCase);
    internal static int Start(Installation installation)
    {
        const string args = "--remote-debugging-address=127.0.0.1 --remote-debugging-port=43827";
        if (installation.AppId != null)
        {
            var type = Type.GetTypeFromCLSID(new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C"),throwOnError:true)!;
            var manager = Activator.CreateInstance(type)!;
            try { Marshal.ThrowExceptionForHR(((IApplicationActivationManager)manager).ActivateApplication(installation.AppId,args,0,out uint pid)); return checked((int)pid); }
            finally { Marshal.ReleaseComObject(manager); }
        }
        else
        {
            using var process = Process.Start(new ProcessStartInfo(installation.Executable!,args) { UseShellExecute=false }) ?? throw new InvalidOperationException("Spotify did not start");
            return process.Id;
        }
    }
    [ComImport,Guid("2e941141-7f97-4756-ba1d-9decde894a3d"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IApplicationActivationManager
    {
        [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)]string id,
            [MarshalAs(UnmanagedType.LPWStr)]string args,int options,out uint processId);
    }
}
