# Self-contained deployment tests; no Pester, GitHub access or game installation.
$ErrorActionPreference = "Stop"
$env:LOCALAPPDATA = [IO.Path]::GetTempPath()
. "$PSScriptRoot/../Deploy-WowAddon.ps1"

$temp = Join-Path ([IO.Path]::GetTempPath()) ("ArtisanLogbook-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temp | Out-Null
$ConfigDirectory = Join-Path $temp "config"
$ConfigPath = Join-Path $ConfigDirectory "deploy.json"
$script:passed = 0
$state = @{ dispatches = 0; downloads = 0; copies = 0; sha = "abc123"; missing = $false; wrong = $false }
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Test($Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
    Write-Host "PASS $Name"
}
function Throws([scriptblock]$Body, [string]$Pattern) {
    try { & $Body } catch {
        Assert ($_.Exception.Message -match $Pattern) "Unexpected exception: $_"
        return
    }
    throw "Expected failure matching $Pattern"
}
function Read-Host { throw "Unexpected installation path prompt" }
function robocopy { $state.copies++; $global:LASTEXITCODE = 0 }
function New-TestArchive($Name, $Interface, $Directories, $Target) {
    $path = Join-Path $temp $Name
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($directory in $Directories) {
            $entry = $zip.CreateEntry("$directory/$directory.toc")
            $writer = [IO.StreamWriter]::new($entry.Open())
            try {
                $writer.WriteLine("## Interface: $Interface")
                $writer.WriteLine("## X-ArtisanLogbook-Flavor: $Target")
            } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
    return $path
}

try {
    Test "omitting selectors means every configured flavor and addon" {
        $script:Flavor = @(); $script:Addon = @()
        $selected = @(Get-FlavorConfigurations)
        Assert ($selected.Count -eq 2 -and $selected[0].Id -eq "retail" -and $selected[1].Id -eq "forever") "Wrong default flavors"
        Assert ((@(Get-SelectedAddons) -join ",") -eq "Core,UI,Tracer") "Wrong default addons"
        Assert ($selected[0].Interface -eq 120105 -and $selected[1].Interface -eq 16001) "Wrong interfaces"
    }
    Test "one, multiple, deduplicated and invalid selectors" {
        $script:Flavor = @("Forever", "retail", "FOREVER"); $script:Addon = @("Tracer", "Core", "Tracer")
        Assert ((@(Get-FlavorConfigurations).Id -join ",") -eq "forever,retail") "Flavor order/dedup failed"
        Assert ((@(Get-SelectedAddons) -join ",") -eq "Tracer,Core") "Addon order/dedup failed"
        $script:Flavor = @("bad-client")
        Throws { @(Get-FlavorConfigurations) | Out-Null } "Available"
        $script:Flavor = @("Retail")
    }
    $sharedRoot = Join-Path $temp "shared-root"
    $retailRoot = Join-Path $temp "retail-root"
    New-Item -ItemType Directory -Path (Join-Path $sharedRoot "_retail_"),
        (Join-Path $sharedRoot "_forever_"), (Join-Path $retailRoot "_retail_") -Force | Out-Null
    Test "legacy path migration and independent flavor roots" {
        New-Item -ItemType Directory -Path $ConfigDirectory -Force | Out-Null
        @{ wowPath = $sharedRoot; custom = "keep" } | ConvertTo-Json | Set-Content $ConfigPath
        $script:Flavor = @("Retail")
        Assert ((Resolve-WowPath) -eq $sharedRoot) "Legacy path failed"
        $script:Flavor = @("Forever")
        Assert ((Resolve-WowPath) -eq $sharedRoot) "Forever path failed"
        $script:Flavor = @("Retail")
        Resolve-WowPath $retailRoot | Out-Null
        $saved = Get-Content -Raw $ConfigPath | ConvertFrom-Json
        Assert ($saved.paths.retail -eq $retailRoot -and $saved.paths.forever -eq $sharedRoot -and $saved.custom -eq "keep") "Path migration failed"
    }
    Test "unknown client directory rejects target before any copy" {
        $script:Flavor = @("Forever")
        Throws { Resolve-WowPath $retailRoot } "_forever_.*-WowPath"
        Assert ($state.copies -eq 0) "A copy occurred"
    }
    $dirs = @("ArtisanLogbook_Core", "ArtisanLogbook", "ArtisanLogbook_Tracer")
    $retailBundle = New-TestArchive "ArtisanLogbook-Bundle.zip" 120105 $dirs "retail"
    $foreverBundle = New-TestArchive "ArtisanLogbook-Bundle-forever.zip" 16001 $dirs "forever"
    $retailCore = New-TestArchive "ArtisanLogbook_Core.zip" 120105 @("ArtisanLogbook_Core") "retail"
    $foreverCore = New-TestArchive "ArtisanLogbook_Core-forever.zip" 16001 @("ArtisanLogbook_Core") "forever"
    Test "bundle validates TOCs for every selected addon" {
        $script:Addon = @("Core", "UI")
        $script:selectedAddons = @("Core", "UI")
        $script:flavorConfig = [pscustomobject]@{ Id = "retail"; Interface = 120105 }
        Test-AddonArchive $retailBundle
        Throws { Test-AddonArchive $foreverBundle } "interface"
        Assert ((@(Get-AddonDirectories) -join ",") -eq "ArtisanLogbook_Core,ArtisanLogbook") "Wrong selected directories"
        $script:flavorConfig = [pscustomobject]@{ Id = "forever"; Interface = 16001 }
        Test-AddonArchive $foreverBundle
        Throws { Test-AddonArchive $foreverCore } "expected TOC"
    }
    Test "malformed and hostile archives cannot be deployed" {
        $unsafe = New-TestArchive "unsafe.zip" 16001 @("../escape") "forever"
        Throws { Test-AddonArchive $unsafe } "Unsafe"
        $broken = Join-Path $temp "broken.zip"
        Set-Content $broken "not a zip"
        Throws { Test-AddonArchive $broken } "."
        Assert ($state.copies -eq 0) "Invalid archives copied"
    }
    function git {
        $global:LASTEXITCODE = 0
        if ($args[0] -eq "branch") { return "feature/multi-target-deployment" }
        if ($args[0] -eq "rev-parse") { return "abc123" }
        throw "Unexpected git: $args"
    }
    function gh {
        $global:LASTEXITCODE = 0
        if ($args[0] -eq "api" -and $args[1] -match "/releases") { return "[]" }
        if ($args[0] -eq "api" -and $args[1] -match "/artifacts") {
            return '{"artifacts":[{"name":"ArtisanLogbook-addon","expired":false}]}'
        }
        if ($args[0] -eq "run" -and $args[1] -eq "list") { return "[]" }
        if ($args[0] -eq "workflow" -and $args[1] -eq "run") {
            $state.dispatches++
            return "https://github.com/Kralizek/ArtisanLogbook/actions/runs/99"
        }
        if ($args[0] -eq "run" -and $args[1] -eq "watch") { return }
        if ($args[0] -eq "run" -and $args[1] -eq "view") { return $state.sha }
        if ($args[0] -eq "run" -and $args[1] -eq "download") {
            $state.downloads++
            $destination = $args[[array]::IndexOf($args, "--dir") + 1]
            $bundle = $script:archivePrefix -eq "ArtisanLogbook-Bundle"
            Copy-Item $(if ($bundle) { $retailBundle } else { $retailCore }) (Join-Path $destination $(if ($bundle) { "ArtisanLogbook-Bundle.zip" } else { "ArtisanLogbook_Core.zip" }))
            if (-not $state.missing) {
                Copy-Item $(if ($bundle) { $foreverBundle } else { $foreverCore }) (Join-Path $destination $(if ($bundle) { "ArtisanLogbook-Bundle-forever.zip" } else { "ArtisanLogbook_Core-forever.zip" }))
            }
            if ($state.wrong) {
                Copy-Item $retailBundle (Join-Path $destination "ArtisanLogbook-Bundle-forever.zip") -Force
            }
            return
        }
        throw "Unexpected gh: $args"
    }
    # PowerShell 5.1 supports neither ternary expressions nor null-coalescing operators.
    Test "both flavors and all three addons use one dispatch and download" {
        $script:Flavor = @(); $script:Addon = @(); $script:selectedAddons = $null
        $state.dispatches = 0; $state.downloads = 0; $state.copies = 0
        & "$PSScriptRoot/../Deploy-WowAddon.ps1" -WowPath $sharedRoot
        Assert ($state.dispatches -eq 1 -and $state.downloads -eq 1 -and $state.copies -eq 6) "Multi-target deployment failed"
    }
    Test "explicit selection deploys only requested combinations" {
        $state.dispatches = 0; $state.downloads = 0; $state.copies = 0
        & "$PSScriptRoot/../Deploy-WowAddon.ps1" -Flavor Retail,Forever -Addon Core -WowPath $sharedRoot
        Assert ($state.dispatches -eq 1 -and $state.downloads -eq 1 -and $state.copies -eq 2) "Selected addons/flavors ignored"
    }
    Test "missing or wrong second flavor archive blocks every copy" {
        $state.missing = $true; $state.copies = 0
        Throws { & "$PSScriptRoot/../Deploy-WowAddon.ps1" -WowPath $sharedRoot } "valid archives"
        Assert ($state.copies -eq 0) "Copied before all archives validated"
        $state.missing = $false; $state.wrong = $true
        Throws { & "$PSScriptRoot/../Deploy-WowAddon.ps1" -WowPath $sharedRoot } "valid archives"
        Assert ($state.copies -eq 0) "Copied wrong-flavor archive"
        $state.wrong = $false
    }
    Test "missing destination blocks dispatch and all copying" {
        $before = $state.dispatches
        Throws { & "$PSScriptRoot/../Deploy-WowAddon.ps1" -WowPath $retailRoot } "_forever_"
        Assert ($state.dispatches -eq $before -and $state.copies -eq 0) "Deployment began with invalid destination"
    }
    Test "wrong workflow commit blocks deployment" {
        $state.sha = "wrong"
        Throws { & "$PSScriptRoot/../Deploy-WowAddon.ps1" -WowPath $sharedRoot } "does not target commit"
        Assert ($state.copies -eq 0) "Copied from wrong commit"
        $state.sha = "abc123"
    }
    Test "invalid configuration is never overwritten" {
        Set-Content $ConfigPath "{broken"
        Throws { Save-WowPath $sharedRoot } "Invalid deployment configuration"
        Assert ((Get-Content -Raw $ConfigPath).Trim() -eq "{broken") "Config overwritten"
    }
    Write-Host "$script:passed deployment tests passed"
} finally { Remove-Item -Recurse -Force $temp }
