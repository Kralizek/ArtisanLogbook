$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$temporary = Join-Path ([IO.Path]::GetTempPath()) "artisan-deploy-test-$([guid]::NewGuid())"
$install = Join-Path $temporary 'installation'
$deploy = Join-Path $root 'scripts/Deploy-Companion.ps1'
$originalPath = $env:PATH
$originalDevelopment = $env:CompanionWebDevelopment
New-Item -ItemType Directory -Path $temporary | Out-Null
Push-Location (Join-Path $root 'src/companion')
try {
    $env:CompanionWebDevelopment = 'true'
    & $deploy -InstallDirectory $install -NoPathUpdate
    $exe = Join-Path $install 'artisanlogbook.exe'
    $originalHash = (Get-FileHash $exe).Hash
    $dotnetDirectory = Split-Path (Get-Command dotnet -CommandType Application).Source
    try {
        $env:PATH = $dotnetDirectory
        try {
            & $deploy -InstallDirectory $install -NoPathUpdate
            throw 'Deployment unexpectedly succeeded without Node/npm'
        } catch {
            if ($_.Exception.Message -notmatch "Required host tool 'node'") { throw }
        }
    } finally { $env:PATH = $originalPath }
    if ((Get-FileHash $exe).Hash -ne $originalHash) { throw 'Missing Node changed the installation' }

    $nodeOnly = Join-Path $temporary 'node-only'
    New-Item -ItemType Directory -Path $nodeOnly | Out-Null
    Copy-Item (Get-Command node -CommandType Application).Source (Join-Path $nodeOnly 'node.exe')
    try {
        $env:PATH = "$dotnetDirectory;$nodeOnly"
        try {
            & $deploy -InstallDirectory $install -NoPathUpdate
            throw 'Deployment unexpectedly succeeded without npm'
        } catch {
            if ($_.Exception.Message -notmatch "Required host tool 'npm.cmd'") { throw }
        }
    } finally { $env:PATH = $originalPath }
    if ((Get-FileHash $exe).Hash -ne $originalHash) { throw 'Missing npm changed the installation' }

    $codegen = (Resolve-Path 'web/codegen.ts').Path
    $originalCodegen = [IO.File]::ReadAllBytes($codegen)
    try {
        $failure = [Text.Encoding]::UTF8.GetBytes("throw new Error('forced codegen failure');`n")
        [IO.File]::WriteAllBytes($codegen, [byte[]]($failure + $originalCodegen))
        try {
            & $deploy -InstallDirectory $install -NoPathUpdate
            throw 'Deployment unexpectedly succeeded with broken codegen'
        } catch {
            if ($_.Exception.Message -notmatch 'dotnet publish failed') { throw }
        }
    } finally { [IO.File]::WriteAllBytes($codegen, $originalCodegen) }
    if ((Get-FileHash $exe).Hash -ne $originalHash) { throw 'Failed frontend build changed the installation' }

    Remove-Item 'web/node_modules/.companion-production-restore'
    $oldCache = $env:npm_config_cache
    $oldOffline = $env:npm_config_offline
    try {
        $env:npm_config_cache = Join-Path $temporary 'empty-npm-cache'
        $env:npm_config_offline = 'true'
        try {
            & $deploy -InstallDirectory $install -NoPathUpdate
            throw 'Deployment unexpectedly succeeded with an empty offline npm cache'
        } catch {
            if ($_.Exception.Message -notmatch 'dotnet publish failed') { throw }
        }
    } finally {
        $env:npm_config_cache = $oldCache
        $env:npm_config_offline = $oldOffline
    }
    if ((Get-FileHash $exe).Hash -ne $originalHash) { throw 'Failed dependency install changed the installation' }
    Write-Host 'Deployment prerequisite and failed-publication checks passed.'
} finally {
    $env:PATH = $originalPath
    $env:CompanionWebDevelopment = $originalDevelopment
    Pop-Location
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
