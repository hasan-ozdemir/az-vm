$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-vs2022community"

$taskConfig = [ordered]@{
    ChocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    PackageId = 'visualstudio2022community'
    DevenvPath = 'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\devenv.exe'
}

function Refresh-SessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path -LiteralPath $refreshEnvCmd) {
        cmd.exe /d /c "`"$refreshEnvCmd`""
    }

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) {
        $env:Path = $machinePath
    }
    else {
        $env:Path = "$machinePath;$userPath"
    }
}

Refresh-SessionPath

if (Test-Path -LiteralPath ([string]$taskConfig.DevenvPath)) {
    Write-Host ("Visual Studio 2022 Community executable already exists: {0}" -f [string]$taskConfig.DevenvPath)
    Write-Host "install-vs2022community-completed"
    Write-Host "Update task completed: install-vs2022community"
    return
}

if (-not (Test-Path -LiteralPath ([string]$taskConfig.ChocoExe))) {
    throw "choco was not found."
}

Write-Host ("Running: choco install {0} -y --no-progress --ignore-detected-reboot" -f [string]$taskConfig.PackageId)
& ([string]$taskConfig.ChocoExe) install ([string]$taskConfig.PackageId) -y --no-progress --ignore-detected-reboot
$installExit = [int]$LASTEXITCODE
if ($installExit -ne 0 -and $installExit -ne 2) {
    throw ("choco install {0} failed with exit code {1}." -f [string]$taskConfig.PackageId, $installExit)
}

Refresh-SessionPath
if (-not (Test-Path -LiteralPath ([string]$taskConfig.DevenvPath))) {
    throw ("Visual Studio 2022 Community executable was not found after installation: {0}" -f [string]$taskConfig.DevenvPath)
}

Write-Host "install-vs2022community-completed"
Write-Host "Update task completed: install-vs2022community"

