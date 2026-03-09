$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-onedrive"

$managerUser = "__VM_ADMIN_USER__"
$assistantUser = "__ASSISTANT_USER__"

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

function Resolve-OneDriveExe {
    foreach ($candidate in @(
        "C:\Program Files\Microsoft OneDrive\OneDrive.exe",
        ("C:\Users\{0}\AppData\Local\Microsoft\OneDrive\OneDrive.exe" -f $managerUser),
        ("C:\Users\{0}\AppData\Local\Microsoft\OneDrive\OneDrive.exe" -f $assistantUser)
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return [string]$candidate
        }
    }

    return ""
}

Refresh-SessionPath
$existingExe = Resolve-OneDriveExe
if (-not [string]::IsNullOrWhiteSpace([string]$existingExe)) {
    Write-Host ("OneDrive executable already exists: {0}" -f $existingExe)
    Write-Host "install-onedrive-completed"
    Write-Host "Update task completed: install-onedrive"
    return
}

$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    throw "winget command is not available."
}

Write-Host "Resolved winget executable: $wingetExe"
Write-Host "Running: winget install --id Microsoft.OneDrive --accept-source-agreements --accept-package-agreements --silent --disable-interactivity --force"
& $wingetExe install --id Microsoft.OneDrive --accept-source-agreements --accept-package-agreements --silent --disable-interactivity --force
$installExit = [int]$LASTEXITCODE
if ($installExit -ne 0 -and $installExit -ne -1978335189) {
    throw "winget install Microsoft.OneDrive failed with exit code $installExit."
}

Refresh-SessionPath
$installedExe = Resolve-OneDriveExe
if ([string]::IsNullOrWhiteSpace([string]$installedExe)) {
    Write-Host "Running: winget list --id Microsoft.OneDrive"
    $listOutput = & $wingetExe list --id Microsoft.OneDrive
    $listText = [string]($listOutput | Out-String)
    if ([string]::IsNullOrWhiteSpace($listText) -or -not $listText.ToLowerInvariant().Contains("onedrive")) {
        throw "OneDrive install could not be verified."
    }
}

Write-Host "install-onedrive-completed"
Write-Host "Update task completed: install-onedrive"
