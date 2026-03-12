$ErrorActionPreference = "Stop"
Write-Host "Update task started: configure-unlocker-io"

$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path -LiteralPath $chocoExe)) { throw "choco was not found." }
if (Test-Path -LiteralPath "C:\ProgramData\chocolatey\lib\io-unlocker") {
    Write-Host "Existing Io Unlocker installation is already healthy. Skipping choco install."
    Write-Host "Update task completed: configure-unlocker-io"
    return
}

& $chocoExe install io-unlocker -y --no-progress --ignore-detected-reboot
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) { throw "choco install io-unlocker failed with exit code $LASTEXITCODE." }
if (-not (Test-Path -LiteralPath "C:\ProgramData\chocolatey\lib\io-unlocker")) { throw "io-unlocker path not found." }
Write-Host "Update task completed: configure-unlocker-io"
