$ErrorActionPreference = "Stop"
Write-Host "Update task started: docker-desktop-install-and-configure"

function Invoke-CommandWithTimeout {
    param(
        [scriptblock]$Action,
        [int]$TimeoutSeconds = 30
    )

    $job = Start-Job -ScriptBlock $Action
    $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if (-not $completed) {
        Stop-Job -Job $job -Force
        Remove-Job -Job $job -Force
        return [pscustomobject]@{ Success = $false; TimedOut = $true }
    }

    $output = Receive-Job -Job $job
    if ($output) { $output | ForEach-Object { Write-Host ([string]$_) } }

    $state = $job.ChildJobs[0].JobStateInfo.State
    $hadErrors = @($job.ChildJobs[0].Error).Count -gt 0
    Remove-Job -Job $job -Force

    return [pscustomobject]@{ Success = ($state -ne 'Failed' -and -not $hadErrors); TimedOut = $false }
}

function Refresh-SessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path -LiteralPath $refreshEnvCmd) { cmd.exe /d /c "`"$refreshEnvCmd`"" }
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
}

function Resolve-WingetCommand {
    $candidates = @()
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) { $candidates += [string]$cmd.Source }

    foreach ($candidate in @(
        "$env:ProgramData\chocolatey\bin\winget.exe",
        "$env:ProgramData\chocolatey\lib\winget\tools\winget.exe",
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe")
    )) {
        if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        try {
            & $candidate --version
            if ($LASTEXITCODE -eq 0) { return [string]$candidate }
        }
        catch {
            Write-Warning "winget candidate rejected: $candidate => $($_.Exception.Message)"
        }
    }

    return ""
}

$installed = $false
$wingetExe = Resolve-WingetCommand
if (-not [string]::IsNullOrWhiteSpace($wingetExe)) {
    Write-Host "Running: winget install -e --id Docker.DockerDesktop"
    & $wingetExe install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements --disable-interactivity
    if ($LASTEXITCODE -eq 0) {
        $installed = $true
    }
    else {
        Write-Warning "winget install Docker.DockerDesktop failed with exit code $LASTEXITCODE."
    }
}

if (-not $installed) {
    $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (-not (Test-Path -LiteralPath $chocoExe)) {
        throw "Neither winget nor choco is available for Docker Desktop installation."
    }

    Write-Host "Running: choco upgrade docker-desktop"
    & $chocoExe upgrade docker-desktop -y --no-progress --ignore-detected-reboot
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
        throw "choco upgrade docker-desktop failed with exit code $LASTEXITCODE."
    }
}

Refresh-SessionPath

if (Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue) {
    Set-Service -Name "com.docker.service" -StartupType Automatic
    Start-Service -Name "com.docker.service"
    Write-Host "docker-step-ok: service-config"
}
else {
    Write-Warning "com.docker.service was not found."
}

$dockerDesktopExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
if (Test-Path -LiteralPath $dockerDesktopExe) {
    $startupPath = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\Docker Desktop.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($startupPath)
    $shortcut.TargetPath = $dockerDesktopExe
    $shortcut.Arguments = "--minimized"
    $shortcut.WorkingDirectory = (Split-Path -Path $dockerDesktopExe -Parent)
    $shortcut.IconLocation = "$dockerDesktopExe,0"
    $shortcut.Save()
    Write-Host "docker-step-ok: startup-shortcut"
}
else {
    Write-Warning "Docker Desktop executable not found at expected path."
}

foreach ($localUser in @("__VM_USER__", "__ASSISTANT_USER__")) {
    if ([string]::IsNullOrWhiteSpace([string]$localUser)) { continue }
    if (-not (Get-LocalGroup -Name "docker-users" -ErrorAction SilentlyContinue)) {
        New-LocalGroup -Name "docker-users" -Description "Docker Desktop Users" -ErrorAction SilentlyContinue
    }
    try {
        Add-LocalGroupMember -Group "docker-users" -Member $localUser -ErrorAction Stop
        Write-Host "docker-step-ok: docker-users membership added for $localUser"
    }
    catch {
        if ($_.Exception.Message -match '(?i)already a member') {
            Write-Host "docker-step-ok: docker-users membership already exists for $localUser"
        }
        else {
            Write-Warning "docker-users membership failed for '$localUser': $($_.Exception.Message)"
        }
    }
}

if (Get-Command docker -ErrorAction SilentlyContinue) {
    Write-Host "Running: docker --version"
    $cliStatus = Invoke-CommandWithTimeout -TimeoutSeconds 20 -Action { docker --version }
    if ($cliStatus.Success) {
        Write-Host "docker-step-ok: docker-client-version"
    }
    else {
        Write-Warning "docker --version check failed or timed out."
    }

    Write-Host "Running: docker version (best effort)"
    $daemonStatus = Invoke-CommandWithTimeout -TimeoutSeconds 20 -Action { docker version }
    if ($daemonStatus.Success) {
        Write-Host "docker-step-ok: docker-daemon-version"
    }
    else {
        Write-Warning "docker daemon is not ready yet (fast mode)."
    }
}
else {
    Write-Warning "docker command is not available after installation."
}

Write-Host "docker-desktop-install-and-configure-completed"
Write-Host "Update task completed: docker-desktop-install-and-configure"
