$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-edge-browser"

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

function Resolve-EdgeExe {
    foreach ($candidate in @(
        "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return [string]$candidate
        }
    }

    return ""
}

function Test-EdgeInstalled {
    param([string]$WingetExe = "")

    $edgeExe = Resolve-EdgeExe
    if (-not [string]::IsNullOrWhiteSpace([string]$edgeExe)) {
        return [pscustomobject]@{
            Installed = $true
            Path = [string]$edgeExe
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$WingetExe)) {
        Write-Host "Running: winget list --id Microsoft.Edge"
        $listOutput = & $WingetExe list --id Microsoft.Edge
        $listText = [string]($listOutput | Out-String)
        if (-not [string]::IsNullOrWhiteSpace([string]$listText) -and $listText.ToLowerInvariant().Contains("edge")) {
            return [pscustomobject]@{
                Installed = $true
                Path = ""
            }
        }
    }

    return [pscustomobject]@{
        Installed = $false
        Path = ""
    }
}

function Wait-EdgeInstalled {
    param(
        [string]$WingetExe = "",
        [int]$TimeoutSeconds = 45,
        [int]$PollSeconds = 2
    )

    if ($TimeoutSeconds -lt 1) {
        $TimeoutSeconds = 1
    }
    if ($PollSeconds -lt 1) {
        $PollSeconds = 1
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        Refresh-SessionPath
        $edgeState = Test-EdgeInstalled -WingetExe $WingetExe
        if ([bool]$edgeState.Installed) {
            return $edgeState
        }

        Start-Sleep -Seconds $PollSeconds
    }

    Refresh-SessionPath
    return (Test-EdgeInstalled -WingetExe $WingetExe)
}

Refresh-SessionPath
$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    throw "winget command is not available."
}

$existingEdge = Test-EdgeInstalled -WingetExe $wingetExe
if ([bool]$existingEdge.Installed) {
    if (-not [string]::IsNullOrWhiteSpace([string]$existingEdge.Path)) {
        Write-Host ("Microsoft Edge executable already exists: {0}" -f [string]$existingEdge.Path)
    }
    else {
        Write-Host "Existing Microsoft Edge installation is already healthy. Skipping winget install."
    }
    Write-Host "install-edge-browser-completed"
    Write-Host "Update task completed: install-edge-browser"
    return
}

Write-Host "Resolved winget executable: $wingetExe"
Write-Host "Running: winget install --id Microsoft.Edge --accept-source-agreements --accept-package-agreements --silent --disable-interactivity"
& $wingetExe install --id Microsoft.Edge --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
$installExit = [int]$LASTEXITCODE
if ($installExit -ne 0 -and $installExit -ne -1978335189) {
    throw "winget install Microsoft.Edge failed with exit code $installExit."
}

$verifiedEdge = Wait-EdgeInstalled -WingetExe $wingetExe -TimeoutSeconds 45 -PollSeconds 2
if (-not [bool]$verifiedEdge.Installed) {
    throw "Microsoft Edge install could not be verified."
}

if (-not [string]::IsNullOrWhiteSpace([string]$verifiedEdge.Path)) {
    Write-Host ("install-edge-browser-verified: executable => {0} (install-exit={1})" -f [string]$verifiedEdge.Path, $installExit)
}
else {
    Write-Host ("install-edge-browser-verified: winget-list (install-exit={0})" -f $installExit)
}
Write-Host "install-edge-browser-completed"
Write-Host "Update task completed: install-edge-browser"
