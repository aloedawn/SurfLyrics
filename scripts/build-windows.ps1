[CmdletBinding()]
param(
    [string]$Dotnet = 'dotnet',
    [string]$OutputDirectory = '',
    [switch]$Run
)
$ErrorActionPreference = 'Stop'
$taskRepoRoot = Split-Path $PSScriptRoot -Parent
if (!$OutputDirectory) { $OutputDirectory = Join-Path $taskRepoRoot 'build/windows/win-x64' }
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
& $Dotnet restore (Join-Path $taskRepoRoot 'windows/SurfLyrics.Windows/SurfLyrics.Windows.csproj') --configfile (Join-Path $taskRepoRoot 'windows/NuGet.Config') -r win-x64 -p:SelfContained=true
if ($LASTEXITCODE -ne 0) { throw 'Windows dependency restore failed.' }
& $Dotnet publish (Join-Path $taskRepoRoot 'windows/SurfLyrics.Windows/SurfLyrics.Windows.csproj') -c Release -r win-x64 --self-contained true --no-restore -o $OutputDirectory
if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed.' }
$taskSettingsProject = Join-Path $taskRepoRoot 'windows/SurfLyrics.Settings/SurfLyrics.Settings.csproj'
& $Dotnet restore $taskSettingsProject --configfile (Join-Path $taskRepoRoot 'windows/NuGet.Config') -r win-x64 -p:SelfContained=true
if ($LASTEXITCODE -ne 0) { throw 'WinUI settings dependency restore failed.' }
& $Dotnet publish $taskSettingsProject -c Release -r win-x64 --self-contained true --no-restore -o (Join-Path $OutputDirectory 'Settings')
if ($LASTEXITCODE -ne 0) { throw 'WinUI settings publish failed.' }
Copy-Item -LiteralPath (Join-Path $taskRepoRoot 'windows/SurfLyrics.Windows/Assets/Fonts/OFL.txt') -Destination (Join-Path $OutputDirectory 'Pretendard-JP-LICENSE.txt')
Copy-Item -LiteralPath (Join-Path $taskRepoRoot 'LICENSE') -Destination (Join-Path $OutputDirectory 'LICENSE.txt')
Copy-Item -LiteralPath (Join-Path $taskRepoRoot 'docs/WINDOWS.md') -Destination (Join-Path $OutputDirectory 'WINDOWS.md')
Copy-Item -LiteralPath (Join-Path $taskRepoRoot 'docs/WINDOWS_ANIMATION.md') -Destination (Join-Path $OutputDirectory 'WINDOWS_ANIMATION.md')
Get-FileHash -LiteralPath (Join-Path $OutputDirectory 'SurfLyrics.exe') -Algorithm SHA256
if ($Run) { Start-Process -FilePath (Join-Path $OutputDirectory 'SurfLyrics.exe') }
