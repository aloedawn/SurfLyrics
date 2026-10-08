[CmdletBinding()]
param([string]$Dotnet = 'dotnet')
$ErrorActionPreference = 'Stop'
$taskRepoRoot = Split-Path $PSScriptRoot -Parent
$taskTests = Join-Path $taskRepoRoot 'windows/SurfLyrics.Tests/SurfLyrics.Tests.csproj'
& $Dotnet restore $taskTests --configfile (Join-Path $taskRepoRoot 'windows/NuGet.Config')
if ($LASTEXITCODE -ne 0) { throw 'Windows test dependency restore failed.' }
& $Dotnet run --project $taskTests -c Release --no-restore
if ($LASTEXITCODE -ne 0) { throw 'Windows regression checks failed.' }
& node --test (Join-Path $taskRepoRoot 'scripts/spotify-client-bridge.test.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Shared Spotify bridge checks failed.' }
