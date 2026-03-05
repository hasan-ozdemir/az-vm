$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-io-unlocker"

$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path -LiteralPath $chocoExe)) { throw "choco was not found." }
& $chocoExe install io-unlocker -y --no-progress --ignore-detected-reboot
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) { throw "choco install io-unlocker failed with exit code $LASTEXITCODE." }
if (-not (Test-Path -LiteralPath "C:\ProgramData\chocolatey\lib\io-unlocker")) { throw "io-unlocker path not found." }
Write-Host "Update task completed: install-io-unlocker"
