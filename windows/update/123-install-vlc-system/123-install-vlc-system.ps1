$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-vlc-system"

$taskConfig = [ordered]@{
    WingetInstallTimeoutSeconds = 120
    LogTailLineCount = 20
}

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

function Resolve-VlcExe {
    foreach ($candidate in @(
        "C:\Program Files\VideoLAN\VLC\vlc.exe",
        "C:\Program Files (x86)\VideoLAN\VLC\vlc.exe"
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return [string]$candidate
        }
    }

    return ""
}

function Get-LogTailText {
    param(
        [string]$Path,
        [int]$LineCount = 20
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    try {
        $tailLines = @(Get-Content -LiteralPath $Path -Tail $LineCount -ErrorAction Stop)
        if (@($tailLines).Count -eq 0) {
            return ''
        }

        return ([string](($tailLines -join [Environment]::NewLine))).Trim()
    }
    catch {
        return ''
    }
}

function Invoke-ProcessWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,
        [int]$TimeoutSeconds = 120,
        [string]$Label = 'process'
    )

    $logRoot = Join-Path $env:TEMP 'az-vm-vlc'
    [void](New-Item -ItemType Directory -Path $logRoot -Force)
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $stdoutLog = Join-Path $logRoot ("{0}-{1}.stdout.log" -f $Label.Replace(' ', '-'), $stamp)
    $stderrLog = Join-Path $logRoot ("{0}-{1}.stderr.log" -f $Label.Replace(' ', '-'), $stamp)
    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $ArgumentList `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -PassThru

    $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        try {
            Stop-Process -Id ([int]$process.Id) -Force -ErrorAction Stop
        }
        catch {
        }
    }

    return [pscustomobject]@{
        TimedOut = [bool]$timedOut
        ExitCode = if ($timedOut) { 124 } else { [int]$process.ExitCode }
        StdoutLog = [string]$stdoutLog
        StderrLog = [string]$stderrLog
        StdoutText = [string](Get-LogTailText -Path $stdoutLog -LineCount ([int]$taskConfig.LogTailLineCount))
        StderrText = [string](Get-LogTailText -Path $stderrLog -LineCount ([int]$taskConfig.LogTailLineCount))
    }
}

Refresh-SessionPath
$existingExe = Resolve-VlcExe
if (-not [string]::IsNullOrWhiteSpace([string]$existingExe)) {
    Write-Host ("VLC executable already exists: {0}" -f $existingExe)
    Write-Host "install-vlc-system-completed"
    Write-Host "Update task completed: install-vlc-system"
    return
}

$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    throw "winget command is not available."
}

Write-Host "Resolved winget executable: $wingetExe"
Write-Host "Running: winget install --id VideoLAN.VLC --accept-source-agreements --accept-package-agreements --silent --disable-interactivity"
$installResult = Invoke-ProcessWithTimeout `
    -FilePath $wingetExe `
    -ArgumentList @('install', '--id', 'VideoLAN.VLC', '--accept-source-agreements', '--accept-package-agreements', '--silent', '--disable-interactivity') `
    -TimeoutSeconds ([int]$taskConfig.WingetInstallTimeoutSeconds) `
    -Label 'winget-install-vlc-system'
$installExit = [int]$installResult.ExitCode
$needsPostInstallVerification = $false
if ([bool]$installResult.TimedOut) {
    Write-Warning ("winget install VideoLAN.VLC exceeded the bounded wait ({0}s); post-install verification will determine whether the package is usable." -f [int]$taskConfig.WingetInstallTimeoutSeconds)
    $needsPostInstallVerification = $true
}
elseif ($installExit -ne 0 -and $installExit -ne -1978335189) {
    Write-Warning ("winget install VideoLAN.VLC returned exit code {0}; post-install verification will determine whether the package is usable." -f $installExit)
    $needsPostInstallVerification = $true
}

Refresh-SessionPath
$installedExe = Resolve-VlcExe
if ([string]::IsNullOrWhiteSpace([string]$installedExe)) {
    Write-Host "Running: winget list --id VideoLAN.VLC"
    $listOutput = & $wingetExe list --id VideoLAN.VLC
    $listText = [string]($listOutput | Out-String)
    if ([string]::IsNullOrWhiteSpace($listText) -or -not $listText.ToLowerInvariant().Contains("vlc")) {
        throw ("VLC install could not be verified. stdoutLog={0}; stderrLog={1}" -f [string]$installResult.StdoutLog, [string]$installResult.StderrLog)
    }

    Write-Host ("install-vlc-system-verified: winget-list (install-exit={0})" -f $installExit)
}
else {
    if ($needsPostInstallVerification) {
        Write-Host ("install-vlc-system-verified: executable => {0} (install-exit={1})" -f [string]$installedExe, $installExit)
    }
    else {
        Write-Host ("install-vlc-system-verified: executable => {0}" -f [string]$installedExe)
    }
}

$global:LASTEXITCODE = 0
Write-Host "install-vlc-system-completed"
Write-Host "Update task completed: install-vlc-system"

