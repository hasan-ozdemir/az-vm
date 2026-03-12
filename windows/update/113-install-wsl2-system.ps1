$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-wsl2-system"

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

function Invoke-NativeStep {
    param(
        [string]$Label,
        [scriptblock]$Action,
        [int[]]$AcceptedExitCodes = @(0)
    )

    Write-Host ("Running: {0}" -f $Label)
    $commandOutput = @(& $Action)
    $exitCode = [int]$LASTEXITCODE
    foreach ($line in @($commandOutput)) {
        $lineText = [string]$line
        if (-not [string]::IsNullOrWhiteSpace([string]$lineText)) {
            Write-Host $lineText
        }
    }
    if (-not ($AcceptedExitCodes -contains $exitCode)) {
        Write-Warning ("{0} returned exit code {1}." -f $Label, $exitCode)
    }
    else {
        Write-Host ("{0} exit code: {1}" -f $Label, $exitCode)
    }
    return $exitCode
}

function Test-WslPackageInstalled {
    $package = @(Get-AppxPackage -AllUsers -Name "MicrosoftCorporationII.WindowsSubsystemForLinux" -ErrorAction SilentlyContinue)
    return (@($package).Count -gt 0)
}

function Test-WslReady {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return $false
    }

    & wsl.exe --version
    return ([int]$LASTEXITCODE -eq 0)
}

Refresh-SessionPath

$rebootRequired = $false

if ((Invoke-NativeStep -Label "dism enable-feature Microsoft-Windows-Subsystem-Linux" -AcceptedExitCodes @(0,3010) -Action {
    dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
}) -eq 3010) {
    $rebootRequired = $true
}

if ((Invoke-NativeStep -Label "dism enable-feature VirtualMachinePlatform" -AcceptedExitCodes @(0,3010) -Action {
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
}) -eq 3010) {
    $rebootRequired = $true
}

$wslReadyBeforeBootstrap = Test-WslReady
$wslPackageInstalled = Test-WslPackageInstalled
if (-not $wslReadyBeforeBootstrap -or -not $wslPackageInstalled) {
    $wingetExe = Resolve-WingetExe
    if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
        throw "winget command is not available. WSL bootstrap requires winget."
    }

    Write-Host "Resolved winget executable: $wingetExe"
    Write-Host "Running: winget install --id Microsoft.WSL --accept-source-agreements --accept-package-agreements --silent --disable-interactivity"
    & $wingetExe install --id Microsoft.WSL --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
    $wingetExit = [int]$LASTEXITCODE
    if ($wingetExit -ne 0 -and $wingetExit -ne -1978335189) {
        throw "winget install Microsoft.WSL failed with exit code $wingetExit."
    }

    Refresh-SessionPath
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "wsl command is not available after bootstrap."
}

$wslUpdateExit = Invoke-NativeStep -Label "wsl --update" -AcceptedExitCodes @(0,3010) -Action {
    wsl.exe --update
}
if ($wslUpdateExit -eq 3010) {
    $rebootRequired = $true
}

$versionExit = Invoke-NativeStep -Label "wsl --version" -AcceptedExitCodes @(0) -Action {
    wsl.exe --version
}

if ($versionExit -eq 0) {
    [void](Invoke-NativeStep -Label "wsl --status" -AcceptedExitCodes @(0) -Action {
        wsl.exe --status
    })
    Write-Host "wsl-step-ok: wsl-version"
}
else {
    if ($rebootRequired) {
        Write-Warning "WSL verification is deferred until the next reboot."
    }
    else {
        throw "WSL is still unavailable after bootstrap and update."
    }
}

if ($rebootRequired) {
    Write-Host "TASK_REBOOT_REQUIRED:install-wsl2-system"
}

Write-Host "install-wsl2-system-completed"
Write-Host "Update task completed: install-wsl2-system"
