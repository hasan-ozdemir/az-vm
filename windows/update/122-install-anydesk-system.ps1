$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-anydesk-system"

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

function Test-AnyDeskInstalled {
    $anyDeskPathCandidates = @(
        "C:\Program Files (x86)\AnyDesk\AnyDesk.exe",
        "C:\Program Files\AnyDesk\AnyDesk.exe"
    )
    foreach ($candidate in @($anyDeskPathCandidates)) {
        if (Test-Path -LiteralPath $candidate) {
            return [pscustomobject]@{
                Installed = $true
                Path = [string]$candidate
            }
        }
    }

    Write-Host "Running: winget list anydesk.anydesk"
    $listOutput = & $wingetExe list anydesk.anydesk
    $listExit = [int]$LASTEXITCODE
    $listText = [string]($listOutput | Out-String)
    if ($listExit -eq 0 -and -not [string]::IsNullOrWhiteSpace($listText) -and $listText.ToLowerInvariant().Contains("anydesk")) {
        return [pscustomobject]@{
            Installed = $true
            Path = ""
        }
    }

    return [pscustomobject]@{
        Installed = $false
        Path = ""
    }
}

Refresh-SessionPath
$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    throw "winget command is not available."
}

Write-Host "Resolved winget executable: $wingetExe"
$existingAnyDesk = Test-AnyDeskInstalled
if ([bool]$existingAnyDesk.Installed) {
    if (-not [string]::IsNullOrWhiteSpace([string]$existingAnyDesk.Path)) {
        Write-Host ("Existing AnyDesk installation is already healthy: {0}" -f [string]$existingAnyDesk.Path)
    }
    else {
        Write-Host "Existing AnyDesk installation is already healthy. Skipping winget install."
    }
    Write-Host "install-anydesk-system-completed"
    Write-Host "Update task completed: install-anydesk-system"
    return
}

Write-Host "Running: winget install anydesk.anydesk --accept-source-agreements --accept-package-agreements --silent --disable-interactivity"
& $wingetExe install anydesk.anydesk --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
$installExit = [int]$LASTEXITCODE
$needsPostInstallVerification = $false
if ($installExit -ne 0 -and $installExit -ne -1978335189) {
    Write-Warning ("winget install anydesk.anydesk returned exit code {0}; post-install verification will determine whether the package is usable." -f $installExit)
    $needsPostInstallVerification = $true
}

    $verifiedAnyDesk = Test-AnyDeskInstalled
if (-not [bool]$verifiedAnyDesk.Installed) {
    throw "AnyDesk install could not be verified."
}

if ([string]::IsNullOrWhiteSpace([string]$verifiedAnyDesk.Path)) {
    Write-Host ("install-anydesk-system-verified: winget-list (install-exit={0})" -f $installExit)
}
else {
    Write-Host ("install-anydesk-system-verified: executable => {0} (install-exit={1})" -f [string]$verifiedAnyDesk.Path, $installExit)
}

$global:LASTEXITCODE = 0
Write-Host "install-anydesk-system-completed"
Write-Host "Update task completed: install-anydesk-system"
