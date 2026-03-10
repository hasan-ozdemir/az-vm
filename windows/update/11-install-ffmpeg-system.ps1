$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-ffmpeg-system"

function Refresh-SessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path -LiteralPath $refreshEnvCmd) { cmd.exe /d /c "`"$refreshEnvCmd`"" }
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
}

$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path -LiteralPath $chocoExe)) { throw "choco was not found." }
& $chocoExe install ffmpeg -y --no-progress --ignore-detected-reboot
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) { throw "choco install ffmpeg failed with exit code $LASTEXITCODE." }
Refresh-SessionPath
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw "ffmpeg command was not found after install." }
ffmpeg -version
Write-Host "Update task completed: install-ffmpeg-system"
