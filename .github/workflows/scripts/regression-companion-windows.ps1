$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This regression suite requires PowerShell 7 or later on Windows.' }
$root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
foreach ($tool in @('dotnet', 'node', 'npm.cmd')) {
    if (-not (Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue)) {
        throw "Required host tool not found: $tool"
    }
}

Write-Host 'Checking Windows deployment prerequisites and failure preservation'
try {
    & (Join-Path $root 'scripts/tests/Deploy-Companion.Tests.ps1')
} finally {
    # The offline failure deliberately leaves a partial npm tree.
    Push-Location (Join-Path $root 'src/companion/web')
    try {
        Write-Host 'Restoring development dependencies after the failure test'
        & npm.cmd ci --include=dev --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw "Dependency recovery failed: $LASTEXITCODE" }
    } finally { Pop-Location }
}
Write-Host 'Windows Companion extended regression checks passed.'
