$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-sysinternals"

$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path -LiteralPath $chocoExe)) { throw "choco was not found." }
& $chocoExe upgrade sysinternals -y --no-progress --ignore-detected-reboot --ignore-checksums
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) { throw "choco upgrade sysinternals failed with exit code $LASTEXITCODE." }
if (-not (Test-Path -LiteralPath "C:\ProgramData\chocolatey\lib\sysinternals\tools")) { throw "sysinternals tools path not found." }
Write-Host "Update task completed: install-sysinternals"
