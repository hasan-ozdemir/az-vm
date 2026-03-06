$ErrorActionPreference = "Stop"
# AZ_VM_TASK_TIMEOUT_SECONDS=3600
Write-Host "Update task started: docker-desktop-install-and-configure"

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

function Ensure-MachinePathEntry {
    param([string]$Entry)

    if ([string]::IsNullOrWhiteSpace([string]$Entry)) {
        return
    }

    $normalizedEntry = [string]$Entry.Trim()
    if (-not (Test-Path -LiteralPath $normalizedEntry)) {
        return
    }

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $parts = @($machinePath -split ";" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($part in @($parts)) {
        if ([string]::Equals($part, $normalizedEntry, [System.StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }

    $newPath = if ([string]::IsNullOrWhiteSpace($machinePath)) { $normalizedEntry } else { "$machinePath;$normalizedEntry" }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
}

function Invoke-ProcessWithTimeout {
    param(
        [string]$Label,
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 30
    )

    if ($TimeoutSeconds -lt 5) { $TimeoutSeconds = 5 }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    Write-Host ("Running: {0}" -f $Label)
    [void]$proc.Start()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $completed = $proc.WaitForExit([int]($TimeoutSeconds * 1000))
    if (-not $completed) {
        try { $proc.Kill() } catch { }
        try { [void]$proc.WaitForExit() } catch { }
        Write-Warning ("{0} timed out after {1} second(s)." -f $Label, $TimeoutSeconds)
        return [pscustomobject]@{ Success = $false; ExitCode = 124; TimedOut = $true; StdOut = ""; StdErr = "" }
    }

    [void]$proc.WaitForExit()
    $stdOut = ""
    $stdErr = ""
    try { $stdOut = [string]$stdoutTask.Result } catch { }
    try { $stdErr = [string]$stderrTask.Result } catch { }

    if (-not [string]::IsNullOrWhiteSpace($stdOut)) { Write-Host $stdOut.TrimEnd() }
    if (-not [string]::IsNullOrWhiteSpace($stdErr)) { Write-Host $stdErr.TrimEnd() }

    return [pscustomobject]@{
        Success = ($proc.ExitCode -eq 0)
        ExitCode = [int]$proc.ExitCode
        TimedOut = $false
        StdOut = [string]$stdOut
        StdErr = [string]$stdErr
    }
}

Refresh-SessionPath

$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace($wingetExe)) {
    throw "winget command is not available. Docker Desktop install requires winget."
}
Write-Host "Resolved winget executable: $wingetExe"

$dockerDesktopExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
$dockerServiceExists = $null -ne (Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue)
$dockerAlreadyInstalled = (Test-Path -LiteralPath $dockerDesktopExe) -or $dockerServiceExists

Write-Host "Running: winget source list"
& $wingetExe source list
if ($LASTEXITCODE -ne 0) {
    throw "winget source list failed with exit code $LASTEXITCODE."
}

if ($dockerAlreadyInstalled) {
    Write-Host "Docker Desktop is already installed. Winget install step is skipped."
}
else {
    Write-Host "Running: winget install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements --silent --disable-interactivity --force"
    & $wingetExe install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements --silent --disable-interactivity --force
    if ($LASTEXITCODE -ne 0) {
        throw "winget install Docker.DockerDesktop failed with exit code $LASTEXITCODE."
    }
}

Refresh-SessionPath
Ensure-MachinePathEntry -Entry "C:\Program Files\Docker\Docker\resources\bin"
Refresh-SessionPath

if (Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue) {
    Set-Service -Name "com.docker.service" -StartupType Automatic
    Start-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
    Write-Host "docker-step-ok: service-config"
}
else {
    throw "com.docker.service was not found after installation."
}

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
    throw "Docker Desktop executable not found at expected path."
}

foreach ($localUser in @("__VM_USER__", "__ASSISTANT_USER__")) {
    if (-not (Get-LocalGroup -Name "docker-users" -ErrorAction SilentlyContinue)) {
        New-LocalGroup -Name "docker-users" -Description "Docker Desktop Users" -ErrorAction Stop
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
            throw "docker-users membership failed for '$localUser'. $($_.Exception.Message)"
        }
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker command is not available after installation."
}

$dockerVersionResult = Invoke-ProcessWithTimeout -Label "docker --version" -FilePath "docker" -Arguments @("--version") -TimeoutSeconds 20
if ($dockerVersionResult.Success) {
    Write-Host "docker-step-ok: docker-client-version"
}
else {
    Write-Warning ("docker --version did not complete successfully (exit={0})." -f $dockerVersionResult.ExitCode)
}

$dockerDaemonResult = Invoke-ProcessWithTimeout -Label "docker version" -FilePath "docker" -Arguments @("version") -TimeoutSeconds 20
if ($dockerDaemonResult.Success) {
    Write-Host "docker-step-ok: docker-daemon-version"
}
else {
    Write-Warning ("docker version did not complete successfully (exit={0})." -f $dockerDaemonResult.ExitCode)
}

Write-Host "docker-desktop-install-and-configure-completed"
Write-Host "Update task completed: docker-desktop-install-and-configure"
