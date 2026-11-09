[CmdletBinding()]
param(
    [string[]]$Addon,

    [string[]]$Flavor,

    [string]$WowPath
)

$ErrorActionPreference = "Stop"

$Repository = "Kralizek/ArtisanLogbook"
$Workflow = "ci-addon.yml"
$ArtifactName = "ArtisanLogbook-addon"
$ConfigDirectory = Join-Path $env:LOCALAPPDATA "ArtisanLogbook"
$ConfigPath = Join-Path $ConfigDirectory "deploy.json"

function Get-FlavorConfigurations {
    param([string]$Path = (Join-Path $PSScriptRoot "../.flavors.yml"))
    $id = $null
    $versions = [ordered]@{}
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*-\s+id:\s+([a-z][a-z0-9-]*)\s*(?:#.*)?$') {
            $id = $Matches[1]
            if ($versions.Contains($id)) { throw "Duplicate flavor '$id' in $Path." }
            $versions[$id] = $null
        }
        elseif ($id -and $line -match '^\s+version:\s+[''"]?(\d+)\.(\d+)\.(\d+)[''"]?\s*(?:#.*)?$') {
            $versions[$id] = [int]$Matches[1] * 10000 + [int]$Matches[2] * 100 + [int]$Matches[3]
        }
    }
    $requested = @($Flavor | Where-Object { $_ })
    if ($requested.Count -eq 0) { $requested = @($versions.Keys) }
    $seen = @{}
    foreach ($name in $requested) {
        $key = $name.ToLowerInvariant()
        if (-not $versions.Contains($key) -or -not $versions[$key]) {
            throw "Flavor '$name' has no valid version in $Path. Available: $($versions.Keys -join ', ')."
        }
        if ($seen[$key]) { continue }
        $seen[$key] = $true
        [pscustomobject]@{
            Id = $key
            Interface = $versions[$key]
            ClientDirectory = "_${key}_"
            Suffix = $(if ($key -eq "retail") { "" } else { "-$key" })
        }
    }
}

function Get-FlavorConfiguration {
    $selected = @(Get-FlavorConfigurations)
    if ($selected.Count -ne 1) { throw "Get-FlavorConfiguration requires one selected flavor." }
    return $selected[0]
}

function Get-SelectedAddons {
    $wanted = @($Addon | Where-Object { $_ })
    if ($wanted.Count -eq 0) { $wanted = @("Core", "UI", "Tracer") }
    $seen = @{}
    foreach ($name in $wanted) {
        if ($name -notin @("Core", "UI", "Tracer")) { throw "Unknown addon '$name'. Available: Core, UI, Tracer." }
        if (-not $seen[$name]) { $seen[$name] = $true; $name }
    }
}

function Get-DeploymentConfiguration {
    if (-not (Test-Path $ConfigPath)) { return @{} }
    try {
        $config = Get-Content -Raw $ConfigPath | ConvertFrom-Json
        if ($config -isnot [pscustomobject]) {
            throw "Expected a configuration object."
        }
        if ($config.paths -and $config.paths -isnot [pscustomobject]) {
            throw "Expected paths to be a flavor-to-installation-root object."
        }
        $result = @{}
        foreach ($property in $config.PSObject.Properties) { $result[$property.Name] = $property.Value }
        return $result
    }
    catch {
        throw "Invalid deployment configuration at $ConfigPath. Repair or back up this file before retrying: $_"
    }
}

function Invoke-Gh {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    & gh @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "gh $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Get-ConfiguredWowPath {
    $config = Get-DeploymentConfiguration
    if ($config.paths) {
        $property = $config.paths.PSObject.Properties[$Flavor.ToLowerInvariant()]
        if ($property -and $property.Value) { return $property.Value }
        if ($config.paths -is [hashtable] -and $config.paths[$Flavor.ToLowerInvariant()]) {
            return $config.paths[$Flavor.ToLowerInvariant()]
        }
    }
    # A shared root (including legacy wowPath) may contain both clients.
    return $config.wowPath
}

function Save-WowPath {
    param([Parameter(Mandatory)][string]$Path)

    New-Item -ItemType Directory -Force -Path $ConfigDirectory | Out-Null
    $config = Get-DeploymentConfiguration
    $paths = @{}
    if ($config.paths) {
        foreach ($property in $config.paths.PSObject.Properties) { $paths[$property.Name] = $property.Value }
    }
    if ($config.wowPath -and -not $paths.retail) { $paths.retail = $config.wowPath }
    $paths[$Flavor.ToLowerInvariant()] = $Path
    if (-not $config.wowPath) { $config.wowPath = $Path }
    $config.paths = $paths
    $config | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $ConfigPath
}

function Resolve-WowPath {
    param([string]$RequestedPath)

    $path = $RequestedPath
    if (-not $path) {
        $path = Get-ConfiguredWowPath
    }

    if (-not $path) {
        $path = Read-Host "World of Warcraft installation directory"
        if (-not $path) {
            throw "A World of Warcraft installation directory is required."
        }
    }
    $client = "_$($Flavor.ToLowerInvariant())_"
    if (-not (Test-Path -Path (Join-Path $path $client) -PathType Container)) {
        throw "'$path' does not contain the selected $Flavor client directory '$client'. Use -WowPath with the installation root containing $client. No addons were copied."
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

        $runs = ($json -join "`n") | ConvertFrom-Json
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

function Get-WorkflowRunsForCommit {
    param([Parameter(Mandatory)][string]$Sha)

    $json = & gh run list --repo $Repository --workflow $Workflow --commit $Sha --event workflow_dispatch --limit 100 --json databaseId,headSha,createdAt,status,conclusion
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list existing workflow runs for $Sha."
    }

    return @(($json -join "`n") | ConvertFrom-Json | Where-Object { $_.headSha -eq $Sha } |
        Sort-Object { ConvertTo-DateTimeOffset $_.createdAt } -Descending)
}

function Test-RunArtifact {
    param([Parameter(Mandatory)]$RunId)
    $json = & gh api "repos/$Repository/actions/runs/$RunId/artifacts?per_page=100"
    if ($LASTEXITCODE -ne 0) { throw "Unable to inspect artifacts for workflow run $RunId." }
    $response = ($json -join "`n") | ConvertFrom-Json
    if (@($response.artifacts | Where-Object { $_.name -eq $ArtifactName -and -not $_.expired }).Count -eq 0) {
        return $false
    }
    $download = if ($script:artifactCache) { $script:artifactCache } else {
        Join-Path ([IO.Path]::GetTempPath()) ("ArtisanLogbook-check-" + [Guid]::NewGuid().ToString("N"))
    }
    New-Item -ItemType Directory -Force -Path $download | Out-Null
    try {
        Get-ChildItem -Path $download -Force | Remove-Item -Recurse -Force
        Invoke-Gh run download $RunId --repo $Repository --name $ArtifactName --dir $download
        foreach ($target in @($script:targets)) {
            $script:flavorConfig = $target.Flavor
            $archive = Join-Path $download "$archivePrefix$($flavorConfig.Suffix).zip"
            if (-not (Test-Path $archive -PathType Leaf)) { return $false }
            try { Test-AddonArchive -Path $archive }
            catch {
                Write-Verbose "Run $RunId archive failed validation for $($flavorConfig.Id): $_"
                return $false
            }
        }
        return $true
    }
    finally { if (-not $script:artifactCache) { Remove-Item -Recurse -Force $download } }
}

function Find-ReusableRun {
    param([Parameter(Mandatory)][string]$Sha)

    $runs = @(Get-WorkflowRunsForCommit -Sha $Sha)
    foreach ($run in $runs) {
        if ($run.status -eq "completed" -and $run.conclusion -eq "success" -and (Test-RunArtifact -RunId $run.databaseId)) {
            return $run
        }
    }

    # An unfinished run is not evidence that the requested package exists.
    return $null
}

function Find-ReleasePackage {
    param(
        [Parameter(Mandatory)][string]$Sha,
        [Parameter(Mandatory)][string]$ArchivePrefix
    )

    $json = & gh api "repos/$Repository/releases?per_page=100"
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list GitHub releases."
    }

    foreach ($release in @(($json -join "`n") | ConvertFrom-Json)) {
        if ($release.draft -or $release.tag_name -notmatch '^addon-v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$') { continue }
        $version = $release.tag_name.Substring("addon-v".Length)
        $expectedAsset = "$ArchivePrefix$($flavorConfig.Suffix)-$version.zip"
        $asset = @($release.assets | Where-Object {
            $_.name -eq $expectedAsset -and
            $_.state -eq "uploaded"
        } | Select-Object -First 1)
        if (-not $asset.Count) { continue }

        # target_commitish can be a branch name; resolve the tag to its actual commit.
        $tagSha = & gh api "repos/$Repository/commits/$($release.tag_name)" --jq '.sha' 2>$null
        if ($LASTEXITCODE -eq 0 -and $tagSha.Trim() -eq $Sha) {
            return [pscustomobject]@{
                Tag = $release.tag_name
                Asset = $asset[0].name
            }
        }
    }
    return $null
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

function Get-AddonDirectories {
    $names = @{ UI = "ArtisanLogbook"; Core = "ArtisanLogbook_Core"; Tracer = "ArtisanLogbook_Tracer" }
    $selected = if ($script:selectedAddons) { $script:selectedAddons } else { @(Get-SelectedAddons) }
    foreach ($name in $selected) { $names[$name] }
}

function Test-AddonArchive {
    param([Parameter(Mandatory)][string]$Path)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $directories = @(Get-AddonDirectories)
        $names = @{}
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if ($name -match '\\|^/|:|(^|/)\.\.?(/|$)' -or
                $name.Split('/')[0] -notin @('ArtisanLogbook_Core', 'ArtisanLogbook', 'ArtisanLogbook_Tracer') -or $names.ContainsKey($name)) {
                throw "Unsafe, duplicate or unexpected archive entry '$name'. No addons were copied."
            }
            if (($entry.ExternalAttributes -shr 16 -band 0xF000) -eq 0xA000) {
                throw "Symbolic links are not allowed in addon archives."
            }
            $names[$name] = $true
        }
        foreach ($directory in $directories) {
            $toc = $zip.GetEntry("$directory/$directory.toc")
            if (-not $toc) { throw "Package does not contain expected TOC '$directory.toc'." }
            $reader = [IO.StreamReader]::new($toc.Open())
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            $interfaces = [regex]::Matches($text, '(?m)^## Interface:\s*([0-9]+)\s*$')
            $declarations = [regex]::Matches($text, '(?m)^## Interface:')
            if ($declarations.Count -ne 1 -or $interfaces.Count -ne 1 -or
                [int]$interfaces[0].Groups[1].Value -ne $flavorConfig.Interface) {
                throw "TOC '$directory.toc' must target $Flavor interface $($flavorConfig.Interface). No addons were copied."
            }
            $target = [regex]::Matches($text, '(?m)^## X-ArtisanLogbook-Flavor:\s*([a-z-]+)\s*$')
            if ($target.Count -gt 1 -or ($target.Count -eq 1 -and $target[0].Groups[1].Value -ne $flavorConfig.Id)) {
                throw "TOC '$directory.toc' targets the wrong flavor. No addons were copied."
            }
        }
    }
    finally { $zip.Dispose() }
}

function Install-AddonArchive {
    param([string]$Path, [string]$Expanded, [string]$Destination)

    Test-AddonArchive -Path $Path
    Expand-Archive -Path $Path -DestinationPath $Expanded -Force
    foreach ($directory in @(Get-AddonDirectories)) {
        $source = Join-Path $Expanded $directory
        $target = Join-Path $Destination $directory
        Write-Host "Deploying $directory -> $target"
        Copy-Addon -Source $source -Destination $target
    }
}

if ($MyInvocation.InvocationName -eq ".") { return }

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI (gh) is required." }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "Git is required." }

$selectedFlavors = @(Get-FlavorConfigurations)
$script:selectedAddons = @(Get-SelectedAddons)
$selectedAddonCount = $script:selectedAddons.Count
if ($selectedAddonCount -eq 0 -or $selectedFlavors.Count -eq 0) { throw "No deployment targets selected." }
$requestedFlavorNames = @($Flavor)
$requestedAddonNames = @($Addon)
$script:targets = @()
# Preflight every installation directory before downloading or modifying any addon.
foreach ($config in $selectedFlavors) {
    $script:Flavor = $config.Id
    $root = Resolve-WowPath $WowPath
    $destination = Join-Path (Join-Path (Join-Path $root $config.ClientDirectory) "Interface") "AddOns"
    $script:targets += [pscustomobject]@{ Flavor = $config; Destination = $destination }
}
$script:Flavor = $requestedFlavorNames
$script:Addon = $requestedAddonNames

$branch = Get-CurrentBranch
$sha = Get-CurrentSha
$archivePrefix = if ($selectedAddonCount -ne 1) { "ArtisanLogbook-Bundle" } else {
    switch ($script:selectedAddons[0]) {
        "UI" { "ArtisanLogbook" }
        "Core" { "ArtisanLogbook_Core" }
        "Tracer" { "ArtisanLogbook_Tracer" }
    }
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ("ArtisanLogbook-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temp | Out-Null
$script:artifactCache = $temp
try {
    # Release assets are selected only when exactly one flavor is requested.
    # Multi-flavor deployment obtains the complete CI artifact once.
    $release = $null
    if ($script:targets.Count -eq 1) {
        $script:flavorConfig = $script:targets[0].Flavor
        $release = Find-ReleasePackage -Sha $sha -ArchivePrefix $archivePrefix
    }
    $runId = $null
    if ($release) {
        Write-Host "Reusing release $($release.Tag) for commit $sha ($($release.Asset))."
        Invoke-Gh release download $release.Tag --repo $Repository --pattern $release.Asset --dir $temp
    }
    else {
        $run = Find-ReusableRun -Sha $sha
        if ($run) {
            $runId = $run.databaseId
            Write-Host "Reusing existing workflow run $runId for commit $sha."
        }
        else {
            Write-Host "No reusable package found. Dispatching $Workflow for $branch ($sha)..."
            $dispatchTime = [DateTimeOffset]::UtcNow
            $dispatchOutput = & gh workflow run $Workflow --repo $Repository --ref $branch 2>&1
            if ($LASTEXITCODE -ne 0) { throw "gh workflow run failed with exit code $LASTEXITCODE." }
            $dispatchOutput | ForEach-Object { Write-Host $_ }
            foreach ($line in $dispatchOutput) {
                if ([string]$line -match '/actions/runs/(?<id>\d+)') { $runId = $Matches.id; break }
            }
            if (-not $runId) {
                $runId = Wait-ForDispatchedRun -Branch $branch -Sha $sha -StartedAfter $dispatchTime
            }
            Write-Host "Waiting for workflow run $runId..."
            Invoke-Gh run watch $runId --repo $Repository --exit-status
            $runSha = Invoke-Gh run view $runId --repo $Repository --json headSha --jq '.headSha'
            if (($runSha -join "").Trim() -ne $sha) {
                throw "Workflow run $runId does not target commit $sha. No addons were copied."
            }
            if (-not (Test-RunArtifact -RunId $runId)) {
                throw "Workflow run $runId completed without valid archives for every selected target."
            }
        }
    }

    # Validate every selected archive and extract all targets before the first robocopy.
    $staged = @()
    foreach ($target in $script:targets) {
        $script:flavorConfig = $target.Flavor
        $script:Flavor = $flavorConfig.Id
        $archive = if ($release) { Join-Path $temp $release.Asset } else {
            Join-Path $temp "$archivePrefix$($flavorConfig.Suffix).zip"
        }
        if (-not (Test-Path $archive -PathType Leaf)) { throw "Missing archive '$archive'. No addons were copied." }
        Test-AddonArchive -Path $archive
        $expanded = Join-Path $temp ("expanded-" + $flavorConfig.Id)
        Expand-Archive -Path $archive -DestinationPath $expanded -Force
        foreach ($directory in @(Get-AddonDirectories)) {
            if (-not (Test-Path (Join-Path $expanded $directory) -PathType Container)) {
                throw "Archive missing directory '$directory'. No addons were copied."
            }
        }
        $staged += [pscustomobject]@{ Flavor = $flavorConfig.Id; Expanded = $expanded; Destination = $target.Destination }
    }
    foreach ($target in $staged) {
        foreach ($directory in @(Get-AddonDirectories)) {
            $source = Join-Path $target.Expanded $directory
            $destination = Join-Path $target.Destination $directory
            Write-Host "Deploying $directory ($($target.Flavor)) -> $destination"
            Copy-Addon -Source $source -Destination $destination
        }
    }
    Write-Host ""
    Write-Host "Deployed $($script:selectedAddons -join ', ') on $($selectedFlavors.Id -join ', ') from $branch ($sha)."
    Write-Host "Switch to World of Warcraft and run /reload for each client."
}
finally {
    Remove-Item -Recurse -Force $temp
}
