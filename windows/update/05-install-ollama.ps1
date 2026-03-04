$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-ollama"

function Refresh-SessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path -LiteralPath $refreshEnvCmd) { cmd.exe /d /c "`"$refreshEnvCmd`"" }
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
}

$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path -LiteralPath $chocoExe)) { throw "choco was not found." }
& $chocoExe install ollama -y --no-progress --ignore-detected-reboot
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) { throw "choco install ollama failed with exit code $LASTEXITCODE." }
Refresh-SessionPath
if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) { throw "ollama command was not found after install." }
ollama --version
Write-Host "Update task completed: install-ollama"
