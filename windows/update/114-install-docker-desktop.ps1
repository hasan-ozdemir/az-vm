$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-docker-desktop"

$taskConfig = [ordered]@{
    PortableWingetPath = 'C:\ProgramData\az-vm\tools\winget-x64\winget.exe'
    DockerDesktopPackageId = 'Docker.DockerDesktop'
    DockerDesktopExecutablePath = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
    DockerServiceName = 'com.docker.service'
    DockerUsersGroupName = 'docker-users'
    DockerUsersGroupDescription = 'Docker Desktop Users'
    DockerMachinePathEntry = 'C:\Program Files\Docker\Docker\resources\bin'
    DockerStartupShortcutPath = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\Docker Desktop.lnk'
    DockerInstallTimeoutSeconds = 900
    DockerVersionTimeoutSeconds = 8
    DockerDaemonReadyTimeoutSeconds = 8
    DockerDaemonProbeAttempts = 2
    DockerDaemonProbeDelaySeconds = 3
    DockerLocalUsers = @('__VM_ADMIN_USER__', '__ASSISTANT_USER__')
}

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
    $portableCandidate = [string]$taskConfig.PortableWingetPath
    if (Test-Path -LiteralPath $portableCandidate) {
        return [string]$portableCandidate
    }

    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        return [string]$cmd.Source
    }

    return ""
}

function Get-StaleInstallerProcesses {
    $nameRegex = '^(winget|msiexec|MSTeamsSetupx64|AppInstallerCLI|WindowsPackageManagerServer)\.exe$'
    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $name = [string]$_.Name
        $commandLine = [string]$_.CommandLine
        ($name -match $nameRegex) -or ($commandLine -match 'ProgramData\\az-vm\\tools\\winget-x64|WinGet\\defaultState')
    } | Select-Object ProcessId, Name, CommandLine

    return @($processes)
}

function Format-InstallerProcessSummary {
    param(
        [object[]]$Processes
    )

    if ($null -eq $Processes -or @($Processes).Count -eq 0) {
        return '(none)'
    }

    return (@($Processes) | ForEach-Object {
        $commandLine = [string]$_.CommandLine
        if ($commandLine.Length -gt 160) {
            $commandLine = $commandLine.Substring(0, 160) + '...'
        }

        return ("{0}:{1}:{2}" -f [int]$_.ProcessId, [string]$_.Name, $commandLine)
    }) -join ' | '
}

function Stop-StaleInstallerProcesses {
    $staleProcesses = Get-StaleInstallerProcesses
    if (@($staleProcesses).Count -eq 0) {
        return @()
    }

    Write-Host ("Stopping stale installer processes before Docker Desktop install: {0}" -f (Format-InstallerProcessSummary -Processes $staleProcesses))
    foreach ($proc in @($staleProcesses | Sort-Object ProcessId -Descending)) {
        try {
            Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction Stop
        }
        catch {
        }
    }

    Start-Sleep -Seconds 1
    $remaining = Get-StaleInstallerProcesses
    if (@($remaining).Count -gt 0) {
        throw ("Stale installer processes still active before Docker Desktop install: {0}" -f (Format-InstallerProcessSummary -Processes $remaining))
    }

    return @($staleProcesses)
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

function Ensure-LocalGroupMembership {
    param(
        [string]$GroupName,
        [string]$MemberName
    )

    if (-not (Get-LocalGroup -Name $GroupName -ErrorAction SilentlyContinue)) {
        New-LocalGroup -Name $GroupName -Description ([string]$taskConfig.DockerUsersGroupDescription) -ErrorAction Stop | Out-Null
    }

    try {
        Add-LocalGroupMember -Group $GroupName -Member $MemberName -ErrorAction Stop
        Write-Host "docker-step-ok: docker-users membership added for $MemberName"
    }
    catch {
        if ($_.Exception.Message -match '(?i)already a member') {
            Write-Host "docker-step-ok: docker-users membership already exists for $MemberName"
            return
        }

        throw
    }
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
        $activeInstallers = Get-StaleInstallerProcesses
        if (@($activeInstallers).Count -gt 0) {
            Write-Host ("Stopping installer processes after timeout: {0}" -f (Format-InstallerProcessSummary -Processes $activeInstallers))
            foreach ($installerProc in @($activeInstallers | Sort-Object ProcessId -Descending)) {
                try {
                    Stop-Process -Id ([int]$installerProc.ProcessId) -Force -ErrorAction Stop
                }
                catch {
                }
            }
        }
        try { $proc.Kill() } catch { }
        try { [void]$proc.WaitForExit() } catch { }
        Write-Warning ("{0} did not complete in time. Active installer processes: {1}" -f $Label, (Format-InstallerProcessSummary -Processes $activeInstallers))
        return [pscustomobject]@{ Success = $false; ExitCode = 124; TimedOut = $true; StdOut = ""; StdErr = ""; ActiveInstallerProcesses = @($activeInstallers) }
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
        ActiveInstallerProcesses = @()
    }
}

function Start-DockerDesktopProcess {
    param([string]$DockerDesktopExe)

    $running = @(Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue)
    if (@($running).Count -gt 0) {
        Write-Host "docker-step-ok: docker-desktop-process-already-running"
        return
    }

    Start-Process -FilePath $DockerDesktopExe -ArgumentList "--minimized" -WindowStyle Hidden
    Write-Host "docker-step-ok: docker-desktop-process-started"
}

function Wait-DockerDaemonReady {
    param(
        [string]$DockerExe = "docker",
        [int]$ProbeAttempts = 2,
        [int]$ProbeDelaySeconds = 3,
        [int]$CommandTimeoutSeconds = 8
    )

    if ($ProbeAttempts -lt 1) { $ProbeAttempts = 1 }
    if ($ProbeDelaySeconds -lt 0) { $ProbeDelaySeconds = 0 }
    if ($CommandTimeoutSeconds -lt 5) { $CommandTimeoutSeconds = 5 }

    foreach ($attempt in 1..$ProbeAttempts) {
        $daemonResult = Invoke-ProcessWithTimeout `
            -Label ("docker version (daemon probe {0}/{1})" -f $attempt, $ProbeAttempts) `
            -FilePath $DockerExe `
            -Arguments @("version") `
            -TimeoutSeconds $CommandTimeoutSeconds
        if ($daemonResult.Success) {
            $global:LASTEXITCODE = 0
            Write-Host "docker-step-ok: docker-daemon-version"
            return $true
        }

        $global:LASTEXITCODE = 0
        if ($attempt -lt $ProbeAttempts -and $ProbeDelaySeconds -gt 0) {
            Write-Host ("Docker daemon is not ready in the current noninteractive session. Retrying one quick probe ({0}/{1})." -f ($attempt + 1), $ProbeAttempts) -ForegroundColor Yellow
            Start-Sleep -Seconds $ProbeDelaySeconds
        }
    }

    $global:LASTEXITCODE = 0
    return $false
}

function Register-DockerDesktopDeferredStart {
    param([string]$DockerDesktopExe)

    $runOncePath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
    if (-not (Test-Path -LiteralPath $runOncePath)) {
        New-Item -Path $runOncePath -Force | Out-Null
    }

    $commandValue = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Process -FilePath ''{0}'' -ArgumentList ''--minimized'' -WindowStyle Hidden"' -f $DockerDesktopExe)
    Set-ItemProperty -Path $runOncePath -Name "AzVmStartDockerDesktop" -Value $commandValue -Type String
}

Refresh-SessionPath

$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace($wingetExe)) {
    throw "winget command is not available. Docker Desktop install requires winget."
}
Write-Host "Resolved winget executable: $wingetExe"

$dockerDesktopExe = [string]$taskConfig.DockerDesktopExecutablePath
$dockerServiceExists = $null -ne (Get-Service -Name ([string]$taskConfig.DockerServiceName) -ErrorAction SilentlyContinue)
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
    Stop-StaleInstallerProcesses | Out-Null
    Write-Host ("Running: winget install -e --id {0} --accept-source-agreements --accept-package-agreements --silent --disable-interactivity" -f [string]$taskConfig.DockerDesktopPackageId)
    $dockerInstallResult = Invoke-ProcessWithTimeout `
        -Label ("winget install {0}" -f [string]$taskConfig.DockerDesktopPackageId) `
        -FilePath $wingetExe `
        -Arguments @('install', '-e', '--id', ([string]$taskConfig.DockerDesktopPackageId), '--accept-source-agreements', '--accept-package-agreements', '--silent', '--disable-interactivity') `
        -TimeoutSeconds ([int]$taskConfig.DockerInstallTimeoutSeconds)
    if (-not $dockerInstallResult.Success) {
        if ($dockerInstallResult.TimedOut) {
            throw ("winget install {0} timed out after stale-installer cleanup. Active installer processes: {1}" -f `
                [string]$taskConfig.DockerDesktopPackageId, `
                (Format-InstallerProcessSummary -Processes $dockerInstallResult.ActiveInstallerProcesses))
        }

        throw ("winget install {0} failed with exit code {1}." -f [string]$taskConfig.DockerDesktopPackageId, $dockerInstallResult.ExitCode)
    }
}

Refresh-SessionPath
Ensure-MachinePathEntry -Entry ([string]$taskConfig.DockerMachinePathEntry)
Refresh-SessionPath

if (Get-Service -Name ([string]$taskConfig.DockerServiceName) -ErrorAction SilentlyContinue) {
    Set-Service -Name ([string]$taskConfig.DockerServiceName) -StartupType Automatic
    Start-Service -Name ([string]$taskConfig.DockerServiceName) -ErrorAction SilentlyContinue
    Write-Host "docker-step-ok: service-config"
}
else {
    throw ("{0} was not found after installation." -f [string]$taskConfig.DockerServiceName)
}

if (Test-Path -LiteralPath $dockerDesktopExe) {
    $startupPath = [string]$taskConfig.DockerStartupShortcutPath
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

foreach ($localUser in @($taskConfig.DockerLocalUsers)) {
    Ensure-LocalGroupMembership -GroupName ([string]$taskConfig.DockerUsersGroupName) -MemberName $localUser
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker command is not available after installation."
}

$dockerVersionResult = Invoke-ProcessWithTimeout -Label "docker --version" -FilePath "docker" -Arguments @("--version") -TimeoutSeconds ([int]$taskConfig.DockerVersionTimeoutSeconds)
if ($dockerVersionResult.Success) {
    Write-Host "docker-step-ok: docker-client-version"
}
else {
    throw ("docker --version did not complete successfully (exit={0})." -f $dockerVersionResult.ExitCode)
}

Start-DockerDesktopProcess -DockerDesktopExe $dockerDesktopExe
if (-not (Wait-DockerDaemonReady `
    -DockerExe "docker" `
    -ProbeAttempts ([int]$taskConfig.DockerDaemonProbeAttempts) `
    -ProbeDelaySeconds ([int]$taskConfig.DockerDaemonProbeDelaySeconds) `
    -CommandTimeoutSeconds ([int]$taskConfig.DockerDaemonReadyTimeoutSeconds))) {
    Register-DockerDesktopDeferredStart -DockerDesktopExe $dockerDesktopExe
    Write-Warning "Docker Desktop engine is not expected to become fully ready in every noninteractive SSH session. A RunOnce start was registered for the next interactive sign-in."
    Write-Host "docker-step-deferred: interactive-sign-in-required"
}

$global:LASTEXITCODE = 0
Write-Host "install-docker-desktop-completed"
Write-Host "Update task completed: install-docker-desktop"
