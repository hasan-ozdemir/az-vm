$ErrorActionPreference = "Stop"
Write-Host "Init task started: install-sysinternals-suite"

$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path -LiteralPath $chocoExe)) { throw "choco was not found." }
$sysinternalsToolsPath = "C:\ProgramData\chocolatey\lib\sysinternals\tools"
if (Test-Path -LiteralPath $sysinternalsToolsPath) {
    Write-Host ("Existing Sysinternals installation is already healthy: {0}" -f $sysinternalsToolsPath)
    Write-Host "Init task completed: install-sysinternals-suite"
    return
}

& $chocoExe install sysinternals -y --no-progress --ignore-detected-reboot --ignore-checksums
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) { throw "choco install sysinternals failed with exit code $LASTEXITCODE." }
if (-not (Test-Path -LiteralPath $sysinternalsToolsPath)) { throw "sysinternals tools path not found." }
Write-Host "Init task completed: install-sysinternals-suite"

