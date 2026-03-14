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
    DockerStatusTimeoutSeconds = 20
    DockerInfoTimeoutSeconds = 20
    DockerLocalUsers = @('__VM_ADMIN_USER__', '__ASSISTANT_USER__')
}

function Refresh-SessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path -LiteralPath $refreshEnvCmd) {
        cmd.exe /d /c "`"$refreshEnvCmd`" >nul 2>&1" | Out-Null
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
        return $false
    }

    $normalizedEntry = [string]$Entry.Trim()
    if (-not (Test-Path -LiteralPath $normalizedEntry)) {
        return $false
    }

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $parts = @($machinePath -split ";" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($part in @($parts)) {
        if ([string]::Equals($part, $normalizedEntry, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }

    $newPath = if ([string]::IsNullOrWhiteSpace($machinePath)) { $normalizedEntry } else { "$machinePath;$normalizedEntry" }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
    return $true
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
        return [pscustomobject]@{
            AlreadyRunning = $true
            StartedNow = $false
        }
    }

    Start-Process -FilePath $DockerDesktopExe -ArgumentList "--minimized" -WindowStyle Hidden
    Write-Host "docker-step-ok: docker-desktop-process-started"
    return [pscustomobject]@{
        AlreadyRunning = $false
        StartedNow = $true
    }
}

function Get-ShortcutContract {
    param([string]$ShortcutPath)

    if ([string]::IsNullOrWhiteSpace([string]$ShortcutPath) -or -not (Test-Path -LiteralPath $ShortcutPath)) {
        return $null
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    return [pscustomobject]@{
        TargetPath = [string]$shortcut.TargetPath
        Arguments = [string]$shortcut.Arguments
        WorkingDirectory = [string]$shortcut.WorkingDirectory
        IconLocation = [string]$shortcut.IconLocation
    }
}

function Test-ShortcutMatches {
    param(
        [string]$ShortcutPath,
        [string]$TargetPath,
        [string]$Arguments = '',
        [string]$WorkingDirectory = '',
        [string]$IconLocation = ''
    )

    $contract = Get-ShortcutContract -ShortcutPath $ShortcutPath
    if ($null -eq $contract) {
        return $false
    }

    return (
        [string]::Equals([string]$contract.TargetPath, [string]$TargetPath, [System.StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$contract.Arguments, [string]$Arguments, [System.StringComparison]::Ordinal) -and
        [string]::Equals([string]$contract.WorkingDirectory, [string]$WorkingDirectory, [System.StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$contract.IconLocation, [string]$IconLocation, [System.StringComparison]::OrdinalIgnoreCase)
    )
}

function Ensure-DockerStartupShortcut {
    param([string]$DockerDesktopExe)

    $startupPath = [string]$taskConfig.DockerStartupShortcutPath
    $workingDirectory = Split-Path -Path $DockerDesktopExe -Parent
    $iconLocation = "$DockerDesktopExe,0"
    if (Test-ShortcutMatches -ShortcutPath $startupPath -TargetPath $DockerDesktopExe -Arguments '--minimized' -WorkingDirectory $workingDirectory -IconLocation $iconLocation) {
        Write-Host "docker-step-ok: startup-shortcut-already-configured"
        return
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($startupPath)
    $shortcut.TargetPath = $DockerDesktopExe
    $shortcut.Arguments = '--minimized'
    $shortcut.WorkingDirectory = $workingDirectory
    $shortcut.IconLocation = $iconLocation
    $shortcut.Save()

    if (-not (Test-ShortcutMatches -ShortcutPath $startupPath -TargetPath $DockerDesktopExe -Arguments '--minimized' -WorkingDirectory $workingDirectory -IconLocation $iconLocation)) {
        throw ("Docker Desktop startup shortcut validation failed: {0}" -f $startupPath)
    }

    Write-Host "docker-step-ok: startup-shortcut"
}

function Resolve-DockerServices {
    $services = @(Get-Service -Name 'com.docker*' -ErrorAction SilentlyContinue | Sort-Object Name)
    if (@($services).Count -eq 0) {
        $primaryService = Get-Service -Name ([string]$taskConfig.DockerServiceName) -ErrorAction SilentlyContinue
        if ($null -ne $primaryService) {
            $services = @($primaryService)
        }
    }

    return @($services)
}

function Ensure-DockerServicesStarted {
    $services = @(Resolve-DockerServices)
    if (@($services).Count -eq 0) {
        throw ("{0} was not found after installation." -f [string]$taskConfig.DockerServiceName)
    }

    foreach ($service in @($services)) {
        try {
            Set-Service -Name ([string]$service.Name) -StartupType Automatic -ErrorAction Stop
        }
        catch {
            Write-Warning ("docker-step-warning: failed to set service startup type for {0}: {1}" -f [string]$service.Name, $_.Exception.Message)
        }

        try {
            if ([string]$service.Status -ne 'Running') {
                Start-Service -Name ([string]$service.Name) -ErrorAction Stop
            }
        }
        catch {
            Write-Warning ("docker-step-warning: failed to start service {0}: {1}" -f [string]$service.Name, $_.Exception.Message)
        }
    }

    Start-Sleep -Seconds 2
    $resolvedServices = @(Resolve-DockerServices)
    $runningServices = @($resolvedServices | Where-Object { [string]$_.Status -eq 'Running' })
    Write-Host ("docker-step-ok: service-config => total={0}; running={1}" -f @($resolvedServices).Count, @($runningServices).Count)
}

function Test-DockerDesktopProcessRunning {
    param([string]$DockerDesktopExe = '')

    $nameMatches = @(Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)
    if (@($nameMatches).Count -gt 0) {
        return $true
    }

    $candidatePath = [string]$DockerDesktopExe
    if ([string]::IsNullOrWhiteSpace([string]$candidatePath)) {
        return $false
    }

    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        [string]::Equals([string]$_.ExecutablePath, $candidatePath, [System.StringComparison]::OrdinalIgnoreCase)
    })
    return (@($processes).Count -gt 0)
}

function Remove-DockerDesktopDeferredStart {
    $runOncePath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
    if (-not (Test-Path -LiteralPath $runOncePath)) {
        return $false
    }

    $existingValue = [string](Get-ItemProperty -Path $runOncePath -Name 'AzVmStartDockerDesktop' -ErrorAction SilentlyContinue).AzVmStartDockerDesktop
    if ([string]::IsNullOrWhiteSpace([string]$existingValue)) {
        return $false
    }

    Remove-ItemProperty -Path $runOncePath -Name 'AzVmStartDockerDesktop' -ErrorAction SilentlyContinue
    $remainingValue = [string](Get-ItemProperty -Path $runOncePath -Name 'AzVmStartDockerDesktop' -ErrorAction SilentlyContinue).AzVmStartDockerDesktop
    if (-not [string]::IsNullOrWhiteSpace([string]$remainingValue)) {
        throw 'Docker Desktop stale RunOnce entry cleanup failed.'
    }

    return $true
}

Refresh-SessionPath

if (Remove-DockerDesktopDeferredStart) {
    Write-Host 'docker-step-cleanup: removed-stale-run-once'
}

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

    Refresh-SessionPath
}

$machinePathChanged = Ensure-MachinePathEntry -Entry ([string]$taskConfig.DockerMachinePathEntry)
if ($machinePathChanged) {
    Refresh-SessionPath
}

Ensure-DockerServicesStarted

if (Test-Path -LiteralPath $dockerDesktopExe) {
    Ensure-DockerStartupShortcut -DockerDesktopExe $dockerDesktopExe
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

$dockerDesktopLaunchState = Start-DockerDesktopProcess -DockerDesktopExe $dockerDesktopExe
if ($null -ne $dockerDesktopLaunchState -and [bool]$dockerDesktopLaunchState.StartedNow) {
    Write-Host "docker-step-ok: desktop-launch-requested"
}

Ensure-DockerServicesStarted

Start-Sleep -Seconds 5
if (Test-DockerDesktopProcessRunning -DockerDesktopExe $dockerDesktopExe) {
    Write-Host "docker-step-ok: docker-desktop-process"
}
else {
    Write-Warning "docker-step-warning: Docker Desktop process is not visible yet after launch."
}

$dockerDesktopStatusResult = Invoke-ProcessWithTimeout -Label "docker desktop status" -FilePath "docker" -Arguments @("desktop", "status") -TimeoutSeconds ([int]$taskConfig.DockerStatusTimeoutSeconds)
if ($dockerDesktopStatusResult.Success -and $dockerDesktopStatusResult.ExitCode -eq 0) {
    Write-Host "docker-step-ok: docker-desktop-status"
}
else {
    Write-Warning ("docker-step-warning: docker desktop status is not healthy yet (exit={0}). No next-boot follow-up was scheduled; a later explicit rerun may still be required." -f [int]$dockerDesktopStatusResult.ExitCode)
}

$dockerInfoResult = Invoke-ProcessWithTimeout -Label "docker info" -FilePath "docker" -Arguments @("info") -TimeoutSeconds ([int]$taskConfig.DockerInfoTimeoutSeconds)
if ($dockerInfoResult.Success -and $dockerInfoResult.ExitCode -eq 0) {
    Write-Host "docker-step-ok: docker-engine-ready"
}
else {
    Write-Warning ("docker-step-warning: docker info is not healthy yet (exit={0}). The Docker client is installed, but this task leaves no deferred boot-time repair behind." -f [int]$dockerInfoResult.ExitCode)
}

$global:LASTEXITCODE = 0
Write-Host "install-docker-desktop-completed"
Write-Host "Update task completed: install-docker-desktop"
