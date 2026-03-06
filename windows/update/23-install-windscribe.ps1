$ErrorActionPreference = "Stop"
# AZ_VM_TASK_TIMEOUT_SECONDS=1800
Write-Host "Update task started: install-windscribe"

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

function Resolve-WingetExe {
    $portableCandidate = "C:\ProgramData\az-vm\tools\winget-x64\winget.exe"
    if (Test-Path -LiteralPath $portableCandidate) {
        return [string]$portableCandidate
    }

    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        return [string]$cmd.Source
    }

    return ""
}

Refresh-SessionPath
$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    throw "winget command is not available."
}

Write-Host "Resolved winget executable: $wingetExe"
Write-Host "Running: winget install windscribe --accept-source-agreements --accept-package-agreements --silent --disable-interactivity --force"
& $wingetExe install windscribe --accept-source-agreements --accept-package-agreements --silent --disable-interactivity --force
$installExit = [int]$LASTEXITCODE
if ($installExit -ne 0 -and $installExit -ne -1978335189) {
    throw "winget install windscribe failed with exit code $installExit."
}

Write-Host "Running: winget list windscribe"
$listOutput = & $wingetExe list windscribe
$listText = [string]($listOutput | Out-String)
$hasPackage = $false
if (-not [string]::IsNullOrWhiteSpace($listText) -and $listText.ToLowerInvariant().Contains("windscribe")) {
    $hasPackage = $true
}

if (-not $hasPackage) {
    $startApps = @()
    if (Get-Command Get-StartApps -ErrorAction SilentlyContinue) {
        $startApps = @(Get-StartApps | Where-Object { ([string]$_.Name).ToLowerInvariant().Contains("windscribe") })
    }
    if ($startApps.Count -gt 0) {
        $hasPackage = $true
    }
}

if (-not $hasPackage) {
    throw "Windscribe install could not be verified."
}

Write-Host "install-windscribe-completed"
Write-Host "Update task completed: install-windscribe"
