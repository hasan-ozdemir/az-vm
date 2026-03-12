$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-nvda-system"

function Refresh-SessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path -LiteralPath $refreshEnvCmd) {
        cmd.exe /d /c "`"$refreshEnvCmd`"" | Out-Null
    }

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace([string]$userPath)) {
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

function Resolve-NvdaExe {
    foreach ($candidate in @(
        "C:\Program Files\NVDA\nvda.exe",
        "C:\Program Files (x86)\NVDA\nvda.exe"
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return [string]$candidate
        }
    }

    return ""
}

Refresh-SessionPath
$existingExe = Resolve-NvdaExe
if (-not [string]::IsNullOrWhiteSpace([string]$existingExe)) {
    Write-Host ("NVDA executable already exists: {0}" -f $existingExe)
    Write-Host "install-nvda-system-completed"
    Write-Host "Update task completed: install-nvda-system"
    return
}

$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    throw "winget command is not available."
}

Write-Host "Resolved winget executable: $wingetExe"
Write-Host "Running: winget install --id NVAccess.NVDA --accept-source-agreements --accept-package-agreements --silent --disable-interactivity"
& $wingetExe install --id NVAccess.NVDA --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
$installExit = [int]$LASTEXITCODE
if ($installExit -ne 0 -and $installExit -ne -1978335189) {
    throw "winget install NVAccess.NVDA failed with exit code $installExit."
}

Refresh-SessionPath
$installedExe = Resolve-NvdaExe
if ([string]::IsNullOrWhiteSpace([string]$installedExe)) {
    Write-Host "Running: winget list --id NVAccess.NVDA"
    $listOutput = & $wingetExe list --id NVAccess.NVDA
    $listText = [string]($listOutput | Out-String)
    if ([string]::IsNullOrWhiteSpace($listText) -or -not $listText.ToLowerInvariant().Contains("nvda")) {
        throw "NVDA install could not be verified."
    }
}

Write-Host "install-nvda-system-completed"
Write-Host "Update task completed: install-nvda-system"
