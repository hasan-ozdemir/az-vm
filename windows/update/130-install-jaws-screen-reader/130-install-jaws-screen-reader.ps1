$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-jaws-screen-reader"

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

function Resolve-JawsExe {
    foreach ($candidate in @(
        "C:\Program Files\Freedom Scientific\JAWS\2025\jfw.exe",
        "C:\Program Files (x86)\Freedom Scientific\JAWS\2025\jfw.exe"
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return [string]$candidate
        }
    }

    return ""
}

Refresh-SessionPath
$existingExe = Resolve-JawsExe
if (-not [string]::IsNullOrWhiteSpace([string]$existingExe)) {
    Write-Host ("Existing JAWS installation is already healthy. Skipping winget install. exe={0}" -f $existingExe)
    Write-Host "install-jaws-screen-reader-completed"
    Write-Host "Update task completed: install-jaws-screen-reader"
    return
}

$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    throw "winget command is not available."
}

$packageId = 'FreedomScientific.JAWS.2025'
Write-Host "Resolved winget executable: $wingetExe"
Write-Host ("Running: winget install --id {0} --exact --accept-source-agreements --accept-package-agreements --silent --disable-interactivity" -f $packageId)
& $wingetExe install --id $packageId --exact --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
$installExit = [int]$LASTEXITCODE
if ($installExit -ne 0 -and $installExit -ne -1978335189) {
    throw ("winget install {0} failed with exit code {1}." -f $packageId, $installExit)
}

Refresh-SessionPath
$installedExe = Resolve-JawsExe
if ([string]::IsNullOrWhiteSpace([string]$installedExe)) {
    Write-Host ("Running: winget list --id {0} --exact" -f $packageId)
    $listOutput = & $wingetExe list --id $packageId --exact
    $listText = [string]($listOutput | Out-String)
    if ([string]::IsNullOrWhiteSpace($listText) -or -not $listText.ToLowerInvariant().Contains("jaws")) {
        throw "JAWS install could not be verified."
    }
}

Write-Host "install-jaws-screen-reader-completed"
Write-Host "Update task completed: install-jaws-screen-reader"
