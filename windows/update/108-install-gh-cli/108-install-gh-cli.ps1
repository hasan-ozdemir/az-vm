$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-gh-cli"

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

if (Get-Command gh -ErrorAction SilentlyContinue) {
    Write-Host "Existing GitHub CLI installation is already healthy. Skipping choco install."
    gh --version
    Write-Host "Update task completed: install-gh-cli"
    return
}

& $chocoExe install gh -y --no-progress --ignore-detected-reboot
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) { throw "choco install gh failed with exit code $LASTEXITCODE." }
Refresh-SessionPath
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "gh command was not found after install." }
gh --version
Write-Host "Update task completed: install-gh-cli"

