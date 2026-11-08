# Self-contained Windows Companion local deployment.
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\ArtisanLogbook\Companion'),
    [switch]$NoPathUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Companion local deployment currently supports Windows only.'
}
if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'A 64-bit Windows installation is required.'
}
if ([string]::IsNullOrWhiteSpace($InstallDirectory)) {
    throw 'InstallDirectory cannot be empty.'
}

$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\companion\src\Cli\Cli.csproj'))
if (-not (Test-Path -LiteralPath $project -PathType Leaf)) {
    throw "Companion project not found: $project"
}
$dotnet = (Get-Command dotnet -ErrorAction Stop).Source
$destination = [IO.Path]::GetFullPath($InstallDirectory)
$parent = Split-Path -Parent $destination
if (-not $parent) { throw 'InstallDirectory must have a parent directory.' }
$marker = '.artisanlogbook-companion-install'
$stage = Join-Path $parent ('.artisanlogbook-stage-' + [guid]::NewGuid().ToString('N'))
$backup = Join-Path $parent ('.artisanlogbook-backup-' + [guid]::NewGuid().ToString('N'))
$priorMoved = $false
$installed = $false

# Never replace an arbitrary pre-existing directory.
if ((Test-Path -LiteralPath $destination) -and
    -not (Test-Path -LiteralPath (Join-Path $destination $marker) -PathType Leaf)) {
    throw "Destination already exists but is not a Companion deployment: $destination"
}
[IO.Directory]::CreateDirectory($parent) | Out-Null

try {
    Write-Host "Publishing Companion ($Configuration, win-x64, self-contained)..."
    $publishArguments = @(
        'publish', $project, '--configuration', $Configuration,
        '--runtime', 'win-x64', '--self-contained', 'true',
        '-p:PublishSingleFile=true', '-p:IncludeNativeLibrariesForSelfExtract=true',
        '-p:PublishTrimmed=false', '--output', $stage
    )
    & $dotnet @publishArguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed (exit $LASTEXITCODE). Existing installation is unchanged."
    }
    $stagedExe = Join-Path $stage 'artisanlogbook.exe'
    if (-not (Test-Path -LiteralPath $stagedExe -PathType Leaf)) {
        throw "Missing published executable: $stagedExe"
    }
    Write-Host 'Verifying staged executable...'
    & $stagedExe --version
    if ($LASTEXITCODE -ne 0) {
        throw "Published executable failed --version (exit $LASTEXITCODE). Existing installation is unchanged."
    }
    [IO.File]::WriteAllText((Join-Path $stage 'al.cmd'),
        ('@echo off' + [Environment]::NewLine +
         '"%~dp0artisanlogbook.exe" %*' + [Environment]::NewLine +
         'exit /b %ERRORLEVEL%' + [Environment]::NewLine),
        [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $stage $marker),
        'Artisan Logbook Companion local deployment', [Text.Encoding]::UTF8)

    # Staging and install directories are on the same volume. If the executable
    # is locked, keep the existing installation or restore it on failure.
    if (Test-Path -LiteralPath $destination) {
        Move-Item -LiteralPath $destination -Destination $backup -ErrorAction Stop
        $priorMoved = $true
    }
    try {
        Move-Item -LiteralPath $stage -Destination $destination -ErrorAction Stop
        $installed = $true
    }
    catch {
        if ($priorMoved -and -not (Test-Path -LiteralPath $destination)) {
            Move-Item -LiteralPath $backup -Destination $destination -ErrorAction Stop
            $priorMoved = $false
        }
        throw
    }
}
finally {
    if (-not $installed -and $priorMoved -and -not (Test-Path -LiteralPath $destination)) {
        Move-Item -LiteralPath $backup -Destination $destination -ErrorAction Stop
        $priorMoved = $false
    }
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}

if ($priorMoved) {
    try { Remove-Item -LiteralPath $backup -Recurse -Force }
    catch { Write-Warning "Previous binaries remain at $backup : $($_.Exception.Message)" }
}

if (-not $NoPathUpdate) {
    try {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $entries = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $present = $false
        foreach ($entry in $entries) {
            $expanded = [Environment]::ExpandEnvironmentVariables($entry).TrimEnd('\')
            if ([string]::Equals($expanded, $destination.TrimEnd('\'),
                    [StringComparison]::OrdinalIgnoreCase)) { $present = $true; break }
        }
        if (-not $present) {
            [Environment]::SetEnvironmentVariable('Path', ((@($entries) + @($destination)) -join ';'), 'User')
            Write-Host 'Added install directory to user PATH.'
        }
        $inProcessPath = $env:Path -split ';' | Where-Object {
            [string]::Equals(([Environment]::ExpandEnvironmentVariables($_)).TrimEnd('\'),
                $destination.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
        }
        if (-not $inProcessPath) { $env:Path = $env:Path.TrimEnd(';') + ';' + $destination }
    }
    catch {
        Write-Warning "Installed, but could not update user PATH: $($_.Exception.Message)"
        Write-Warning "Run '$destination\artisanlogbook.exe' directly."
    }
}
Write-Host "Companion installed: $destination"
Write-Host 'Run: artisanlogbook init | al import | al status'
Write-Host 'Open a new terminal to see PATH changes.'
Write-Host 'Existing settings.json and history.duckdb were not touched.'
