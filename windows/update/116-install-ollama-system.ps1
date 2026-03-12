$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-ollama-system"

$taskConfig = [ordered]@{
    PortableWingetPath = 'C:\ProgramData\az-vm\tools\winget-x64\winget.exe'
    OllamaPackageId = 'Ollama.Ollama'
    OllamaExecutableFallbackCandidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
        'C:\Program Files\Ollama\ollama.exe'
    )
    OllamaApiVersionUri = 'http://127.0.0.1:11434/api/version'
    OllamaApiPort = 11434
    InstallerCommandLineRegex = 'ProgramData\\az-vm\\tools\\winget-x64|WinGet\\defaultState|Docker\.DockerDesktop|Ollama\.Ollama|Microsoft Teams|microsoft\.azd|windscribe|whatsapp|anydesk|vscode'
    InstallerNameRegex = '^(winget|msiexec|MSTeamsSetupx64|AppInstallerCLI|WindowsPackageManagerServer)\.exe$'
    WingetInstallTimeoutSeconds = 600
    OllamaApiWaitTimeoutSeconds = 90
    OllamaApiRetryCount = 2
    OllamaApiRetryBackoffSeconds = 10
    OllamaServeEarlyExitCheckSeconds = 5
    InstallerSettleTimeoutSeconds = 30
    LogTailLineCount = 12
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
    $portableCandidate = [string]$taskConfig.PortableWingetPath
    if (Test-Path -LiteralPath $portableCandidate) {
        return $portableCandidate
    }

    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        return [string]$cmd.Source
    }

    return ""
}

function Resolve-OllamaExe {
    $commandCandidates = @('ollama.exe', 'ollama')
    foreach ($commandName in @($commandCandidates)) {
        $cmd = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            return [string]$cmd.Source
        }
    }

    $pathCandidates = @($taskConfig.OllamaExecutableFallbackCandidates)
    foreach ($candidate in @($pathCandidates)) {
        if (Test-Path -LiteralPath $candidate) {
            return [string]$candidate
        }
    }

    return ''
}

function Get-OllamaApiVersion {
    param(
        [int]$TimeoutSeconds = 5
    )

    try {
        $response = Invoke-RestMethod -Method Get -Uri ([string]$taskConfig.OllamaApiVersionUri) -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        if ($null -ne $response -and -not [string]::IsNullOrWhiteSpace([string]$response.version)) {
            return [string]$response.version
        }
    }
    catch {
    }

    return ''
}

function Wait-OllamaApiReady {
    param(
        [int]$TimeoutSeconds = 90
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $version = Get-OllamaApiVersion -TimeoutSeconds 5
        if (-not [string]::IsNullOrWhiteSpace([string]$version)) {
            return [string]$version
        }

        Start-Sleep -Seconds 2
    }

    return ''
}

function Get-StaleInstallerProcesses {
    $commandLineRegex = [string]$taskConfig.InstallerCommandLineRegex
    $nameRegex = [string]$taskConfig.InstallerNameRegex

    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $name = [string]$_.Name
        $commandLine = [string]$_.CommandLine
        ($name -match $nameRegex) -or ($commandLine -match $commandLineRegex)
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
    param(
        [string]$CurrentPackageId = ''
    )

    $staleProcesses = Get-StaleInstallerProcesses | Where-Object {
        $commandLine = [string]$_.CommandLine
        if ([string]::IsNullOrWhiteSpace([string]$CurrentPackageId)) {
            return $true
        }

        return ($commandLine -notmatch [regex]::Escape($CurrentPackageId))
    }

    if (@($staleProcesses).Count -eq 0) {
        return @()
    }

    Write-Host ("Stopping stale installer processes before Ollama install: {0}" -f (Format-InstallerProcessSummary -Processes $staleProcesses))
    foreach ($proc in @($staleProcesses | Sort-Object ProcessId -Descending)) {
        try {
            Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction Stop
        }
        catch {
        }
    }

    Start-Sleep -Seconds 3
    $remaining = Get-StaleInstallerProcesses | Where-Object {
        $commandLine = [string]$_.CommandLine
        if ([string]::IsNullOrWhiteSpace([string]$CurrentPackageId)) {
            return $true
        }

        return ($commandLine -notmatch [regex]::Escape($CurrentPackageId))
    }
    if (@($remaining).Count -gt 0) {
        throw ("Stale installer processes still active before Ollama install: {0}" -f (Format-InstallerProcessSummary -Processes $remaining))
    }

    return @($staleProcesses)
}

function Wait-InstallerProcessesSettled {
    param(
        [int]$TimeoutSeconds = 30
    )

    if ($TimeoutSeconds -lt 5) {
        $TimeoutSeconds = 5
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $activeInstallers = @(Get-StaleInstallerProcesses)
        if (@($activeInstallers).Count -eq 0) {
            return $true
        }

        Write-Host ("Waiting for installer descendants to settle before Ollama readiness check: {0}" -f (Format-InstallerProcessSummary -Processes $activeInstallers))
        Start-Sleep -Seconds 5
    }

    $remaining = @(Get-StaleInstallerProcesses)
    if (@($remaining).Count -gt 0) {
        Write-Warning ("Installer descendants are still active before Ollama readiness check: {0}" -f (Format-InstallerProcessSummary -Processes $remaining))
    }

    return $false
}

function Invoke-ProcessWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,
        [int]$TimeoutSeconds = 600,
        [string]$Label = 'process'
    )

    $logRoot = Join-Path $env:TEMP 'az-vm-ollama'
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

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
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

        try {
            Stop-Process -Id ([int]$process.Id) -Force -ErrorAction Stop
        }
        catch {
        }

        throw ("{0} timed out after {1} seconds. stdoutLog={2}; stderrLog={3}; activeInstallerProcesses={4}" -f `
            $Label, `
            $TimeoutSeconds, `
            $stdoutLog, `
            $stderrLog, `
            (Format-InstallerProcessSummary -Processes $activeInstallers))
    }

    return [pscustomobject]@{
        ProcessId = [int]$process.Id
        ExitCode = [int]$process.ExitCode
        StdoutLog = [string]$stdoutLog
        StderrLog = [string]$stderrLog
    }
}

function Start-OllamaServeDetached {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OllamaExe
    )

    $logRoot = Join-Path $env:TEMP 'az-vm-ollama'
    [void](New-Item -ItemType Directory -Path $logRoot -Force)
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $stdoutLog = Join-Path $logRoot ("ollama-serve-{0}.stdout.log" -f $stamp)
    $stderrLog = Join-Path $logRoot ("ollama-serve-{0}.stderr.log" -f $stamp)
    $process = Start-Process `
        -FilePath $OllamaExe `
        -ArgumentList 'serve' `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -PassThru

    return [pscustomobject]@{
        Process = $process
        StdoutLog = [string]$stdoutLog
        StderrLog = [string]$stderrLog
    }
}

function Get-LogTailText {
    param(
        [string]$Path,
        [int]$LineCount = 12
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    try {
        $tailLines = @(Get-Content -LiteralPath $Path -Tail $LineCount -ErrorAction Stop)
        if (@($tailLines).Count -eq 0) {
            return ''
        }

        return ([string](($tailLines -join ' | ') -replace '\s+', ' ')).Trim()
    }
    catch {
        return ''
    }
}

function Stop-OllamaServeLaunch {
    param(
        [AllowNull()]
        [object]$ServeLaunch
    )

    if ($null -eq $ServeLaunch -or $null -eq $ServeLaunch.Process) {
        return
    }

    try {
        if (-not $ServeLaunch.Process.HasExited) {
            Stop-Process -Id ([int]$ServeLaunch.Process.Id) -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
    }
}

function Get-OllamaServeFailureDetail {
    param(
        [AllowNull()]
        [object]$ServeLaunch
    )

    if ($null -eq $ServeLaunch) {
        return ''
    }

    $parts = @()
    if ($null -ne $ServeLaunch.Process) {
        $parts += ("servePid={0}" -f [int]$ServeLaunch.Process.Id)
        try {
            if ($ServeLaunch.Process.HasExited) {
                $parts += ("serveExitCode={0}" -f [int]$ServeLaunch.Process.ExitCode)
            }
            else {
                $parts += 'serveExitCode=running'
            }
        }
        catch {
        }
    }

    $stdoutTail = Get-LogTailText -Path ([string]$ServeLaunch.StdoutLog) -LineCount ([int]$taskConfig.LogTailLineCount)
    if (-not [string]::IsNullOrWhiteSpace([string]$stdoutTail)) {
        $parts += ("stdoutTail={0}" -f $stdoutTail)
    }

    $stderrTail = Get-LogTailText -Path ([string]$ServeLaunch.StderrLog) -LineCount ([int]$taskConfig.LogTailLineCount)
    if (-not [string]::IsNullOrWhiteSpace([string]$stderrTail)) {
        $parts += ("stderrTail={0}" -f $stderrTail)
    }

    return ($parts -join '; ')
}

function Ensure-OllamaApiReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OllamaExe,
        [string]$Reason = ("Ollama API is not responding on 127.0.0.1:{0} yet." -f [int]$taskConfig.OllamaApiPort)
    )

    $ollamaVersion = Get-OllamaApiVersion -TimeoutSeconds 5
    $serveLaunch = $null
    $failureDetail = ''
    if ([string]::IsNullOrWhiteSpace([string]$ollamaVersion)) {
        $attemptCount = [Math]::Max(1, [int]$taskConfig.OllamaApiRetryCount)
        for ($attempt = 1; $attempt -le $attemptCount; $attempt++) {
            if ($attempt -eq 1) {
                Write-Host ("{0} Starting 'ollama serve' (attempt {1}/{2})." -f $Reason, $attempt, $attemptCount)
            }
            else {
                Write-Host ("Ollama API is still not responding on 127.0.0.1:{0}. Restarting 'ollama serve' (attempt {1}/{2})." -f [int]$taskConfig.OllamaApiPort, $attempt, $attemptCount)
            }

            $serveLaunch = Start-OllamaServeDetached -OllamaExe $OllamaExe
            Start-Sleep -Seconds ([int]$taskConfig.OllamaServeEarlyExitCheckSeconds)
            $ollamaVersion = Wait-OllamaApiReady -TimeoutSeconds ([int]$taskConfig.OllamaApiWaitTimeoutSeconds)
            if (-not [string]::IsNullOrWhiteSpace([string]$ollamaVersion)) {
                break
            }

            $failureDetail = Get-OllamaServeFailureDetail -ServeLaunch $serveLaunch
            if ($attempt -lt $attemptCount) {
                Write-Warning ("Ollama API is still not ready after serve attempt {0}/{1}. Retrying after {2} seconds. {3}" -f `
                    $attempt, `
                    $attemptCount, `
                    [int]$taskConfig.OllamaApiRetryBackoffSeconds, `
                    $failureDetail)
                Stop-OllamaServeLaunch -ServeLaunch $serveLaunch
                Start-Sleep -Seconds ([int]$taskConfig.OllamaApiRetryBackoffSeconds)
            }
        }
    }

    return [pscustomobject]@{
        Version = [string]$ollamaVersion
        ServeLaunch = $serveLaunch
        FailureDetail = [string]$failureDetail
    }
}

Refresh-SessionPath

$ollamaExe = Resolve-OllamaExe
if (-not [string]::IsNullOrWhiteSpace([string]$ollamaExe)) {
    Write-Host "Resolved existing Ollama executable: $ollamaExe"
    & $ollamaExe --version
    $existingVersionExit = [int]$LASTEXITCODE
    if ($existingVersionExit -eq 0) {
        $existingReadiness = Ensure-OllamaApiReady -OllamaExe $ollamaExe -Reason ("Existing Ollama API is not responding on 127.0.0.1:{0} yet." -f [int]$taskConfig.OllamaApiPort)
        if (-not [string]::IsNullOrWhiteSpace([string]$existingReadiness.Version)) {
            if ($null -ne $existingReadiness.ServeLaunch) {
                Write-Host ("ollama-api-ready: version={0}; port={1}; startedPid={2}; stdoutLog={3}; stderrLog={4}" -f `
                    [string]$existingReadiness.Version, `
                    [int]$taskConfig.OllamaApiPort, `
                    [int]$existingReadiness.ServeLaunch.Process.Id, `
                    [string]$existingReadiness.ServeLaunch.StdoutLog, `
                    [string]$existingReadiness.ServeLaunch.StderrLog)
            }
            else {
                Write-Host ("ollama-api-ready: version={0}; port={1}" -f [string]$existingReadiness.Version, [int]$taskConfig.OllamaApiPort)
            }

            Write-Host "Existing Ollama installation is already healthy. Skipping winget install."
            Write-Host "Update task completed: install-ollama-system"
            return
        }

        if ($null -ne $existingReadiness.ServeLaunch -and -not $existingReadiness.ServeLaunch.Process.HasExited) {
            Stop-Process -Id $existingReadiness.ServeLaunch.Process.Id -Force -ErrorAction SilentlyContinue
        }

        Write-Host "Existing Ollama installation did not become healthy. Reinstall will be attempted."
    }
    else {
        Write-Host ("Existing Ollama executable failed version check with exit code {0}. Reinstall will be attempted." -f $existingVersionExit)
    }
}

$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    throw "winget command is not available."
}

Stop-StaleInstallerProcesses -CurrentPackageId ([string]$taskConfig.OllamaPackageId) | Out-Null

Write-Host "Resolved winget executable: $wingetExe"
Write-Host ("Running: winget install --id {0} --accept-source-agreements --accept-package-agreements --silent --disable-interactivity" -f [string]$taskConfig.OllamaPackageId)
$wingetResult = Invoke-ProcessWithTimeout `
    -FilePath $wingetExe `
    -ArgumentList @('install', '--id', ([string]$taskConfig.OllamaPackageId), '--accept-source-agreements', '--accept-package-agreements', '--silent', '--disable-interactivity') `
    -TimeoutSeconds ([int]$taskConfig.WingetInstallTimeoutSeconds) `
    -Label 'winget-install-ollama-system'
$wingetExit = [int]$wingetResult.ExitCode
if ($wingetExit -ne 0 -and $wingetExit -ne -1978335189) {
    throw ("winget install {0} failed with exit code {1}. stdoutLog={2}; stderrLog={3}" -f `
        [string]$taskConfig.OllamaPackageId, `
        $wingetExit, `
        [string]$wingetResult.StdoutLog, `
        [string]$wingetResult.StderrLog)
}
if ($wingetExit -eq -1978335189) {
    Write-Host "winget reported Ollama is already installed and no newer version is available."
}

Refresh-SessionPath
Wait-InstallerProcessesSettled -TimeoutSeconds ([int]$taskConfig.InstallerSettleTimeoutSeconds) | Out-Null

$ollamaExe = Resolve-OllamaExe
if ([string]::IsNullOrWhiteSpace([string]$ollamaExe)) {
    throw "ollama executable was not found after install."
}

Write-Host "Resolved Ollama executable: $ollamaExe"
& $ollamaExe --version
if ($LASTEXITCODE -ne 0) {
    throw "ollama --version failed with exit code $LASTEXITCODE."
}

$readiness = Ensure-OllamaApiReady -OllamaExe $ollamaExe
$ollamaVersion = [string]$readiness.Version
$serveLaunch = $readiness.ServeLaunch
$failureDetail = [string]$readiness.FailureDetail

if ([string]::IsNullOrWhiteSpace([string]$ollamaVersion)) {
    Stop-OllamaServeLaunch -ServeLaunch $serveLaunch

    $logHint = ''
    if ($null -ne $serveLaunch) {
        $logHint = (" stdoutLog={0}; stderrLog={1}" -f [string]$serveLaunch.StdoutLog, [string]$serveLaunch.StderrLog)
    }
    $detailHint = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$failureDetail)) {
        $detailHint = (" detail={0}" -f $failureDetail)
    }
    throw ("Ollama API did not respond on 127.0.0.1:{0} after install.{1}{2}" -f [int]$taskConfig.OllamaApiPort, $logHint, $detailHint)
}

if ($null -ne $serveLaunch) {
    Write-Host ("ollama-api-ready: version={0}; port={1}; startedPid={2}; stdoutLog={3}; stderrLog={4}" -f `
        $ollamaVersion, `
        [int]$taskConfig.OllamaApiPort, `
        [int]$serveLaunch.Process.Id, `
        [string]$serveLaunch.StdoutLog, `
        [string]$serveLaunch.StderrLog)
}
else {
    Write-Host ("ollama-api-ready: version={0}; port={1}" -f $ollamaVersion, [int]$taskConfig.OllamaApiPort)
}

Write-Host "Update task completed: install-ollama-system"
