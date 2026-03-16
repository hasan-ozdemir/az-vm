$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-7zip-system"

function Refresh-SessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path -LiteralPath $refreshEnvCmd) { cmd.exe /d /c "`"$refreshEnvCmd`"" }
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
}

$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path -LiteralPath $chocoExe)) { throw "choco was not found." }
Refresh-SessionPath

if (Get-Command 7z -ErrorAction SilentlyContinue) {
    Write-Host "Existing 7-Zip installation is already healthy. Skipping choco install."
    7z
    Write-Host "Update task completed: install-7zip-system"
    return
}

& $chocoExe install 7zip -y --no-progress --ignore-detected-reboot
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) { throw "choco install 7zip failed with exit code $LASTEXITCODE." }
Refresh-SessionPath
if (-not (Get-Command 7z -ErrorAction SilentlyContinue)) { throw "7z command was not found after install." }
7z
Write-Host "Update task completed: install-7zip-system"

