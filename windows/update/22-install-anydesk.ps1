$ErrorActionPreference = "Stop"
# AZ_VM_TASK_TIMEOUT_SECONDS=1800
Write-Host "Update task started: install-anydesk"

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
Write-Host "Running: winget install anydesk.anydesk --accept-source-agreements --accept-package-agreements --silent --disable-interactivity --force"
& $wingetExe install anydesk.anydesk --accept-source-agreements --accept-package-agreements --silent --disable-interactivity --force
$installExit = [int]$LASTEXITCODE
if ($installExit -ne 0 -and $installExit -ne -1978335189) {
    throw "winget install anydesk.anydesk failed with exit code $installExit."
}

$anyDeskPathCandidates = @(
    "C:\Program Files (x86)\AnyDesk\AnyDesk.exe",
    "C:\Program Files\AnyDesk\AnyDesk.exe"
)
$anyDeskPath = ""
foreach ($candidate in @($anyDeskPathCandidates)) {
    if (Test-Path -LiteralPath $candidate) {
        $anyDeskPath = [string]$candidate
        break
    }
}
if ([string]::IsNullOrWhiteSpace([string]$anyDeskPath)) {
    Write-Host "Running: winget list anydesk.anydesk"
    $listOutput = & $wingetExe list anydesk.anydesk
    $listText = [string]($listOutput | Out-String)
    if ([string]::IsNullOrWhiteSpace($listText) -or -not $listText.ToLowerInvariant().Contains("anydesk")) {
        throw "AnyDesk install could not be verified."
    }
}

Write-Host "install-anydesk-completed"
Write-Host "Update task completed: install-anydesk"
