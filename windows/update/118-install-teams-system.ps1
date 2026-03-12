$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-teams-system"

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

function Test-TeamsInstalled {
    $hasTeams = $false
    if (Get-Command Get-StartApps -ErrorAction SilentlyContinue) {
        $startApps = @(Get-StartApps | Where-Object { ([string]$_.Name).ToLowerInvariant().Contains("teams") })
        if ($startApps.Count -gt 0) {
            $hasTeams = $true
        }
    }

    if (-not $hasTeams -and -not [string]::IsNullOrWhiteSpace([string]$wingetExe)) {
        Write-Host "Running: winget list Microsoft Teams"
        $listOutput = & $wingetExe list "Microsoft Teams"
        $listText = [string]($listOutput | Out-String)
        if (-not [string]::IsNullOrWhiteSpace($listText) -and $listText.ToLowerInvariant().Contains("teams")) {
            $hasTeams = $true
        }
    }

    return $hasTeams
}

Refresh-SessionPath
$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    throw "winget command is not available."
}

Write-Host "Resolved winget executable: $wingetExe"
if (Test-TeamsInstalled) {
    Write-Host "Existing Microsoft Teams installation is already healthy. Skipping winget install."
    Write-Host "install-teams-system-completed"
    Write-Host "Update task completed: install-teams-system"
    return
}

Write-Host "Running: winget install Microsoft Teams -s msstore --accept-source-agreements --accept-package-agreements --silent --disable-interactivity"
& $wingetExe install "Microsoft Teams" -s msstore --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
$installExit = [int]$LASTEXITCODE
if ($installExit -ne 0 -and $installExit -ne -1978335189) {
    throw "winget install Microsoft Teams failed with exit code $installExit."
}

if (-not (Test-TeamsInstalled)) {
    throw "Microsoft Teams install could not be verified."
}

Write-Host "install-teams-system-completed"
Write-Host "Update task completed: install-teams-system"
