$ErrorActionPreference = "Stop"

$tokenFile = Join-Path $PSScriptRoot "gh-token.env"
$temporaryFile = "$tokenFile.$PID"

try {
  Remove-Item -LiteralPath $tokenFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue

  $tokenLines = @(& gh auth token)
  if ($LASTEXITCODE -ne 0) {
    throw "gh auth token failed. Authenticate on the host with gh auth login."
  }
  if ($tokenLines.Count -ne 1) {
    throw "gh auth token did not return exactly one token."
  }

  $token = [string]$tokenLines[0]
  if ([string]::IsNullOrWhiteSpace($token) -or $token -match "[\r\n]") {
    throw "gh auth token returned an invalid token."
  }

  New-Item -ItemType File -Path $temporaryFile -Force | Out-Null

  if ($env:OS -eq "Windows_NT") {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $temporaryFile /inheritance:r /grant:r "${identity}:(F)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Could not restrict access to the generated GitHub token file."
    }
  } else {
    & chmod 600 $temporaryFile
    if ($LASTEXITCODE -ne 0) {
      throw "Could not restrict access to the generated GitHub token file."
    }
  }

  $encoding = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($temporaryFile, "GH_TOKEN=$token`n", $encoding)
  Move-Item -LiteralPath $temporaryFile -Destination $tokenFile -Force
} catch {
  Remove-Item -LiteralPath $tokenFile -Force -ErrorAction SilentlyContinue
  throw
} finally {
  Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
}