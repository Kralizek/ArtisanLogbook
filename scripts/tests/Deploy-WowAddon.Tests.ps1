# Self-contained mocked tests; no Pester, GitHub access or game installation needed.
$ErrorActionPreference = "Stop"
$env:LOCALAPPDATA = [IO.Path]::GetTempPath()
. "$PSScriptRoot/../Deploy-WowAddon.ps1"

$temp = Join-Path ([IO.Path]::GetTempPath()) ("ArtisanLogbook-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temp | Out-Null
$ConfigDirectory = Join-Path $temp "config"
$ConfigPath = Join-Path $ConfigDirectory "deploy.json"
$script:passed = 0
$testState = @{ forceDispatch = $false; dispatches = 0; copies = 0 }
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Test($Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
    Write-Host "PASS $Name"
}
function Throws([scriptblock]$Body, $Pattern) {
    try { & $Body } catch {
        Assert ($_.Exception.Message -match $Pattern) "Unexpected error: $_"
        return
    }
    throw "Expected failure matching $Pattern"
}
function Read-Host { throw "Unexpected installation path prompt" }
function Copy-Addon { $script:copies++ }
$script:copies = 0
function New-TestArchive($Name, $Interface, $Directories = @("ArtisanLogbook_Tracer"), $Target = $null) {
    $path = Join-Path $temp $Name
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($directory in $Directories) {
            $entry = $zip.CreateEntry("$directory/$directory.toc")
            $writer = [IO.StreamWriter]::new($entry.Open())
            try {
                $writer.WriteLine("## Interface: $Interface")
                if ($Target) { $writer.WriteLine("## X-ArtisanLogbook-Flavor: $Target") }
            } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
    return $path
}
try {
    Test "Retail is default and authoritative flavor versions are derived" {
        Assert ($Flavor -eq "Retail") "Default flavor changed"
        $script:flavorConfig = Get-FlavorConfiguration
        Assert ($flavorConfig.ClientDirectory -eq "_retail_") "Wrong Retail directory"
        Assert ($flavorConfig.Interface -eq 120105 -and $flavorConfig.Suffix -eq "") "Wrong Retail identity"
    }
    $retailRoot = Join-Path $temp "retail-root"
    $sharedRoot = Join-Path $temp "shared-root"
    New-Item -ItemType Directory -Path (Join-Path $retailRoot "_retail_"),
        (Join-Path $sharedRoot "_retail_"), (Join-Path $sharedRoot "_forever_") | Out-Null
    Test "legacy config migrates without losing its root or unrelated fields" {
        New-Item -ItemType Directory -Path $ConfigDirectory | Out-Null
        @{ wowPath = $sharedRoot; custom = "preserved" } | ConvertTo-Json | Set-Content $ConfigPath
        Assert ((Resolve-WowPath) -eq $sharedRoot) "Legacy root not reused"
        $saved = Get-Content -Raw $ConfigPath | ConvertFrom-Json
        Assert ($saved.paths.retail -eq $sharedRoot -and $saved.custom -eq "preserved") "Unsafe migration"
    }
    $Flavor = "Forever"
    $script:flavorConfig = Get-FlavorConfiguration
    Test "Forever resolves the shared installation root without prompting" {
        Assert ($flavorConfig.ClientDirectory -eq "_forever_" -and $flavorConfig.Interface -eq 16001) "Wrong Forever identity"
        Assert ((Resolve-WowPath) -eq $sharedRoot) "Shared root not reused"
        $saved = Get-Content -Raw $ConfigPath | ConvertFrom-Json
        Assert ($saved.paths.retail -eq $sharedRoot -and $saved.paths.forever -eq $sharedRoot) "Lost flavor paths"
    }
    Test "separate flavor roots preserve previously saved paths" {
        $script:Flavor = "Retail"
        Resolve-WowPath $retailRoot | Out-Null
        $script:Flavor = "Forever"
        Assert ((Get-ConfiguredWowPath) -eq $sharedRoot) "Forever path lost"
        $saved = Get-Content -Raw $ConfigPath | ConvertFrom-Json
        Assert ($saved.paths.retail -eq $retailRoot -and $saved.wowPath -eq $sharedRoot) "Retail path or legacy root lost"
    }
    Test "missing selected client fails actionably without copy or fallback" {
        Throws { Resolve-WowPath $retailRoot } "_forever_.*-WowPath"
        Assert ($script:copies -eq 0) "Copied files after path validation failure"
    }
    $Addon = "Tracer"
    $archivePrefix = "ArtisanLogbook_Tracer"
    $valid = New-TestArchive "ArtisanLogbook_Tracer-forever.zip" 16001
    $wrong = New-TestArchive "ArtisanLogbook_Tracer.zip" 120105
    Test "TOC mismatch and wrong flavor prevent extraction and all copying" {
        $expanded = Join-Path $temp "must-not-exist"
        Throws { Install-AddonArchive $wrong $expanded $sharedRoot } "must target Forever interface"
        Assert (-not (Test-Path $expanded) -and $script:copies -eq 0) "Validation was too late"
        $badTarget = New-TestArchive "wrong-flavor.zip" 16001 @("ArtisanLogbook_Tracer") "retail"
        Throws { Test-AddonArchive $badTarget } "wrong flavor"
    }
    Test "all bundle TOCs validate before copying any addon" {
        $script:Addon = "Both"
        Throws { Install-AddonArchive $valid (Join-Path $temp "bad-bundle") $sharedRoot } "expected TOC"
        Assert ($script:copies -eq 0) "Partial bundle copied"
        $bundle = New-TestArchive "bundle.zip" 16001 @("ArtisanLogbook_Core", "ArtisanLogbook", "ArtisanLogbook_Tracer")
        Install-AddonArchive $bundle (Join-Path $temp "good-bundle") $sharedRoot
        Assert ($script:copies -eq 3) "Bundle selection broken"
        $script:Addon = "Tracer"
    }
    Test "UI and Core selectors each deploy exactly their own flavor archive" {
        foreach ($selection in @("UI", "Core")) {
            $script:Addon = $selection
            $directory = @(Get-AddonDirectories)[0]
            $single = New-TestArchive "$selection-forever.zip" 16001 @($directory)
            $before = $script:copies
            Install-AddonArchive $single (Join-Path $temp "$selection-expanded") $sharedRoot
            Assert ($script:copies -eq $before + 1) "Wrong addon selection for $selection"
        }
        $script:Addon = "Tracer"
    }
    Test "unsafe and malformed archives are rejected before extraction" {
        $unsafe = New-TestArchive "unsafe.zip" 16001 @("../escape")
        $before = $script:copies
        Throws { Install-AddonArchive $unsafe (Join-Path $temp "unsafe-expanded") $sharedRoot } "Unsafe"
        $broken = Join-Path $temp "broken.zip"
        Set-Content $broken "not a zip"
        Throws { Install-AddonArchive $broken (Join-Path $temp "broken-expanded") $sharedRoot } "."
        Assert (-not (Test-Path (Join-Path $temp "unsafe-expanded"))) "Unsafe archive extracted"
        Assert ($script:copies -eq $before) "Copied files from invalid archive"
    }
    function gh {
        $global:LASTEXITCODE = 0
        if ($args[0] -eq "api" -and $args[1] -match "/artifacts") {
            return '{"artifacts":[{"name":"ArtisanLogbook-addon","expired":false}]}'
        }
        if ($args[0] -eq "run" -and $args[1] -eq "download") {
            $destination = $args[[array]::IndexOf($args, "--dir") + 1]
            $requestedDownload = $script:downloadFlavor
            if ($testState.forceDispatch) { $requestedDownload = $testState.flavor }
            if ($requestedDownload -eq "forever") {
                Copy-Item $valid (Join-Path $destination "ArtisanLogbook_Tracer-forever.zip")
            } else {
                Copy-Item $wrong (Join-Path $destination "ArtisanLogbook_Tracer.zip")
            }
            return
        }
        if ($args[0] -eq "api" -and $args[1] -match "/releases") {
            if ($testState.forceDispatch) { return "[]" }
            return '{"tag_name":"addon-v1.0.0","assets":[{"name":"ArtisanLogbook_Tracer-forever-1.0.0.zip","state":"uploaded"},{"name":"ArtisanLogbook_Tracer-1.0.0.zip","state":"uploaded"}]}'
        }
        if ($args[0] -eq "api" -and $args[1] -match "/commits/") { return "abc123" }
        if ($args[0] -eq "run" -and $args[1] -eq "list") { return "[]" }
        if ($args[0] -eq "workflow" -and $args[1] -eq "run") {
            $testState.dispatches++
            return "https://github.com/Kralizek/ArtisanLogbook/actions/runs/99"
        }
        if ($args[0] -eq "run" -and $args[1] -eq "watch") { return }
        if ($args[0] -eq "run" -and $args[1] -eq "view") { return $testState.sha }
        throw "Unexpected gh command: $args"
    }
    Test "same-commit Retail artifact cannot be reused for Forever" {
        $script:downloadFlavor = "retail"
        Assert (-not (Test-RunArtifact 1)) "Wrong-flavor artifact reused"
        $script:downloadFlavor = "forever"
        Assert (Test-RunArtifact 2) "Forever artifact not recognized"
    }
    Test "cached runs require requested addon contents; running runs are not blindly reused" {
        function Get-WorkflowRunsForCommit { @(
            [pscustomobject]@{ databaseId = 3; status = "in_progress" },
            [pscustomobject]@{ databaseId = 2; status = "completed"; conclusion = "success" }
        ) }
        $script:downloadFlavor = "retail"
        Assert ($null -eq (Find-ReusableRun "abc123")) "Wrong cached run reused"
        $script:downloadFlavor = "forever"
        Assert ((Find-ReusableRun "abc123").databaseId -eq 2) "Usable run not reused"
        $script:Addon = "Core"
        $script:archivePrefix = "ArtisanLogbook_Core"
        Assert (-not (Test-RunArtifact 2)) "Missing Core archive accepted"
        $script:Addon = "Tracer"
        $script:archivePrefix = "ArtisanLogbook_Tracer"
    }
    Test "release assets use the exact flavor suffix" {
        $release = Find-ReleasePackage "abc123" "ArtisanLogbook_Tracer"
        Assert ($release.Asset -eq "ArtisanLogbook_Tracer-forever-1.0.0.zip") "Wrong release flavor"
        $script:Flavor = "Retail"
        $script:flavorConfig = Get-FlavorConfiguration
        $release = Find-ReleasePackage "abc123" "ArtisanLogbook_Tracer"
        Assert ($release.Asset -eq "ArtisanLogbook_Tracer-1.0.0.zip") "Retail release semantics changed"
    }
    Test "newly dispatched run deploys Forever only after commit and package validation" {
        function git {
            $global:LASTEXITCODE = 0
            if ($args[0] -eq "branch") { return "feature/forever-test" }
            if ($args[0] -eq "rev-parse") { return "abc123" }
            throw "Unexpected git command: $args"
        }
        function robocopy { $testState.copies++; $global:LASTEXITCODE = 0 }
        $env:LOCALAPPDATA = $temp
        $testState.forceDispatch = $true
        $testState.sha = "abc123"
        $testState.flavor = "forever"
        & "$PSScriptRoot/../Deploy-WowAddon.ps1" -Flavor Forever -Addon Tracer -WowPath $sharedRoot
        Assert ($testState.dispatches -eq 1 -and $testState.copies -eq 1) "Dispatch/deployment failed"
        Assert (Test-Path (Join-Path $sharedRoot "_forever_/Interface/AddOns/ArtisanLogbook_Tracer")) "Wrong client destination"
        Assert (-not (Test-Path (Join-Path $sharedRoot "_retail_/Interface/AddOns"))) "Silently deployed Retail"
        $testState.sha = "different-commit"
        Throws {
            & "$PSScriptRoot/../Deploy-WowAddon.ps1" -Flavor Forever -Addon Tracer -WowPath $sharedRoot
        } "does not target commit"
        $testState.sha = "abc123"
        $testState.flavor = "retail"
        Throws {
            & "$PSScriptRoot/../Deploy-WowAddon.ps1" -Flavor Forever -Addon Tracer -WowPath $sharedRoot
        } "without a usable"
        Assert ($testState.copies -eq 1) "Copied files after dispatched-run validation failure"
        $testState.forceDispatch = $false
    }
    Test "invalid config is not silently overwritten" {
        Set-Content $ConfigPath "{broken"
        Throws { Save-WowPath $sharedRoot } "Invalid deployment configuration"
        Assert ((Get-Content -Raw $ConfigPath).Trim() -eq "{broken") "Corrupt config overwritten"
    }
    Write-Host "$script:passed deployment tests passed"
} finally { Remove-Item -Recurse -Force $temp }
