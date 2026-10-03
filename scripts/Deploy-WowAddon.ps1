[CmdletBinding()]
param(
    [ValidateSet("Both", "UI", "Core")]
    [string]$Addon = "Both",

    [string]$WowPath
)

$ErrorActionPreference = "Stop"

$Repository = "Kralizek/ArtisanLogbook"
$Workflow = "ci-addon.yml"
$ArtifactName = "ArtisanLogbook-addon"
$ConfigDirectory = Join-Path $env:LOCALAPPDATA "ArtisanLogbook"
$ConfigPath = Join-Path $ConfigDirectory "deploy.json"

function Invoke-Gh {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    & gh @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "gh $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Get-ConfiguredWowPath {
    if (-not (Test-Path $ConfigPath)) {
        return $null
    }

    try {
        $config = Get-Content -Raw $ConfigPath | ConvertFrom-Json
        return $config.wowPath
    }
    catch {
        Write-Warning "Ignoring invalid deployment configuration at $ConfigPath."
        return $null
    }
}

function Save-WowPath {
    param([Parameter(Mandatory)][string]$Path)

    New-Item -ItemType Directory -Force -Path $ConfigDirectory | Out-Null
    @{ wowPath = $Path } | ConvertTo-Json | Set-Content -Encoding UTF8 $ConfigPath
}

function Resolve-WowPath {
    param([string]$RequestedPath)

    $path = $RequestedPath
    if (-not $path) {
        $path = Get-ConfiguredWowPath
    }

    while (-not $path -or -not (Test-Path (Join-Path $path "_retail_"))) {
        if ($path) {
            Write-Warning "'$path' does not contain a _retail_ directory."
        }
        $path = Read-Host "World of Warcraft installation directory"
        if (-not $path) {
            throw "A World of Warcraft installation directory is required."
        }
    }

    $resolved = (Resolve-Path $path).Path
    Save-WowPath $resolved
    return $resolved
}

function Get-CurrentBranch {
    $branch = (& git branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $branch) {
        throw "Unable to determine the current Git branch. Detached HEAD is not supported."
    }
    return $branch
}

function Get-CurrentSha {
    $sha = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $sha) {
        throw "Unable to determine the current commit SHA."
    }
    return $sha
}

function ConvertTo-DateTimeOffset {
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]$Value }
    return [DateTimeOffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
    )
}

function Wait-ForDispatchedRun {
    param(
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Sha,
        [Parameter(Mandatory)][DateTimeOffset]$StartedAfter
    )

    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(2)
    do {
        $json = & gh run list --repo $Repository --workflow $Workflow --branch $Branch --event workflow_dispatch --limit 20 --json databaseId,headSha,createdAt,status,conclusion
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to list workflow runs."
        }

        $runs = $json | ConvertFrom-Json
        $run = $runs |
            Where-Object {
                $_.headSha -eq $Sha -and
                (ConvertTo-DateTimeOffset $_.createdAt) -ge $StartedAfter.AddSeconds(-5)
            } |
            Sort-Object { ConvertTo-DateTimeOffset $_.createdAt } -Descending |
            Select-Object -First 1

        if ($run) {
            return $run.databaseId
        }

        Start-Sleep -Seconds 2
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "Timed out waiting for the workflow_dispatch run for $Sha."
}

function Copy-Addon {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    & robocopy $Source $Destination /MIR /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -gt 7) {
        throw "robocopy failed for '$Source' with exit code $LASTEXITCODE."
    }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is required."
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git is required."
}

$branch = Get-CurrentBranch
$sha = Get-CurrentSha
$wowRoot = Resolve-WowPath $WowPath
$addonsDirectory = Join-Path $wowRoot "_retail_\Interface\AddOns"

Write-Host "Dispatching $Workflow for $branch ($sha)..."
$dispatchTime = [DateTimeOffset]::UtcNow
$dispatchOutput = & gh workflow run $Workflow --repo $Repository --ref $branch 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "gh workflow run failed with exit code $LASTEXITCODE."
}
$dispatchOutput | ForEach-Object { Write-Host $_ }

$runId = $null
foreach ($line in $dispatchOutput) {
    if ([string]$line -match '/actions/runs/(?<id>\d+)') {
        $runId = $Matches.id
        break
    }
}

if (-not $runId) {
    Write-Host "Workflow run ID was not returned by gh; locating the dispatched run..."
    $runId = Wait-ForDispatchedRun -Branch $branch -Sha $sha -StartedAfter $dispatchTime
}
Write-Host "Waiting for workflow run $runId..."
Invoke-Gh run watch $runId --repo $Repository --exit-status

$temp = Join-Path ([IO.Path]::GetTempPath()) ("ArtisanLogbook-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temp | Out-Null

try {
    Write-Host "Downloading CI artifact..."
    Invoke-Gh run download $runId --repo $Repository --name $ArtifactName --dir $temp

    $archiveName = switch ($Addon) {
        "UI"   { "ArtisanLogbook.zip" }
        "Core" { "ArtisanLogbook_Core.zip" }
        default { "ArtisanLogbook-Bundle.zip" }
    }
    $archive = Join-Path $temp $archiveName
    if (-not (Test-Path $archive)) {
        throw "Expected artifact '$archiveName' was not downloaded."
    }

    $expanded = Join-Path $temp "expanded"
    Expand-Archive -Path $archive -DestinationPath $expanded -Force

    $directories = switch ($Addon) {
        "UI"   { @("ArtisanLogbook") }
        "Core" { @("ArtisanLogbook_Core") }
        default { @("ArtisanLogbook_Core", "ArtisanLogbook") }
    }

    foreach ($directory in $directories) {
        $source = Join-Path $expanded $directory
        if (-not (Test-Path $source)) {
            throw "Package does not contain expected addon directory '$directory'."
        }

        $destination = Join-Path $addonsDirectory $directory
        Write-Host "Deploying $directory -> $destination"
        Copy-Addon -Source $source -Destination $destination
    }
}
finally {
    Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Deployed $Addon from $branch ($sha)."
Write-Host "Switch to World of Warcraft and run /reload."
