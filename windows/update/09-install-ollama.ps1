$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-ollama"

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

    $pathCandidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
        'C:\Program Files\Ollama\ollama.exe'
    )
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
        $response = Invoke-RestMethod -Method Get -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec $TimeoutSeconds -ErrorAction Stop
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
    $commandLineRegex = 'ProgramData\\az-vm\\tools\\winget-x64|WinGet\\defaultState|Docker\.DockerDesktop|Ollama\.Ollama|Microsoft Teams|microsoft\.azd|windscribe|whatsapp|anydesk|vscode'
    $nameRegex = '^(winget|msiexec|MSTeamsSetupx64|AppInstallerCLI|WindowsPackageManagerServer)\.exe$'

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

function Ensure-OllamaApiReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OllamaExe,
        [string]$Reason = 'Ollama API is not responding on 127.0.0.1:11434 yet.'
    )

    $ollamaVersion = Get-OllamaApiVersion -TimeoutSeconds 5
    $serveLaunch = $null
    if ([string]::IsNullOrWhiteSpace([string]$ollamaVersion)) {
        Write-Host ("{0} Starting 'ollama serve'." -f $Reason)
        $serveLaunch = Start-OllamaServeDetached -OllamaExe $OllamaExe
        $ollamaVersion = Wait-OllamaApiReady -TimeoutSeconds 90
    }

    return [pscustomobject]@{
        Version = [string]$ollamaVersion
        ServeLaunch = $serveLaunch
    }
}

Refresh-SessionPath

$ollamaExe = Resolve-OllamaExe
if (-not [string]::IsNullOrWhiteSpace([string]$ollamaExe)) {
    Write-Host "Resolved existing Ollama executable: $ollamaExe"
    & $ollamaExe --version
    $existingVersionExit = [int]$LASTEXITCODE
    if ($existingVersionExit -eq 0) {
        $existingReadiness = Ensure-OllamaApiReady -OllamaExe $ollamaExe -Reason 'Existing Ollama API is not responding on 127.0.0.1:11434 yet.'
        if (-not [string]::IsNullOrWhiteSpace([string]$existingReadiness.Version)) {
            if ($null -ne $existingReadiness.ServeLaunch) {
                Write-Host ("ollama-api-ready: version={0}; port=11434; startedPid={1}; stdoutLog={2}; stderrLog={3}" -f `
                    [string]$existingReadiness.Version, `
                    [int]$existingReadiness.ServeLaunch.Process.Id, `
                    [string]$existingReadiness.ServeLaunch.StdoutLog, `
                    [string]$existingReadiness.ServeLaunch.StderrLog)
            }
            else {
                Write-Host ("ollama-api-ready: version={0}; port=11434" -f [string]$existingReadiness.Version)
            }

            Write-Host "Existing Ollama installation is already healthy. Skipping winget install."
            Write-Host "Update task completed: install-ollama"
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

Stop-StaleInstallerProcesses -CurrentPackageId 'Ollama.Ollama' | Out-Null

Write-Host "Resolved winget executable: $wingetExe"
Write-Host "Running: winget install --id Ollama.Ollama --accept-source-agreements --accept-package-agreements --silent --disable-interactivity --force"
$wingetResult = Invoke-ProcessWithTimeout `
    -FilePath $wingetExe `
    -ArgumentList @('install', '--id', 'Ollama.Ollama', '--accept-source-agreements', '--accept-package-agreements', '--silent', '--disable-interactivity', '--force') `
    -TimeoutSeconds 600 `
    -Label 'winget-install-ollama'
$wingetExit = [int]$wingetResult.ExitCode
if ($wingetExit -ne 0 -and $wingetExit -ne -1978335189) {
    throw ("winget install Ollama.Ollama failed with exit code {0}. stdoutLog={1}; stderrLog={2}" -f `
        $wingetExit, `
        [string]$wingetResult.StdoutLog, `
        [string]$wingetResult.StderrLog)
}
if ($wingetExit -eq -1978335189) {
    Write-Host "winget reported Ollama is already installed and no newer version is available."
}

Refresh-SessionPath

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

if ([string]::IsNullOrWhiteSpace([string]$ollamaVersion)) {
    if ($null -ne $serveLaunch -and -not $serveLaunch.Process.HasExited) {
        Stop-Process -Id $serveLaunch.Process.Id -Force -ErrorAction SilentlyContinue
    }

    $logHint = ''
    if ($null -ne $serveLaunch) {
        $logHint = (" stdoutLog={0}; stderrLog={1}" -f [string]$serveLaunch.StdoutLog, [string]$serveLaunch.StderrLog)
    }
    throw ("Ollama API did not respond on 127.0.0.1:11434 after install.{0}" -f $logHint)
}

if ($null -ne $serveLaunch) {
    Write-Host ("ollama-api-ready: version={0}; port=11434; startedPid={1}; stdoutLog={2}; stderrLog={3}" -f `
        $ollamaVersion, `
        [int]$serveLaunch.Process.Id, `
        [string]$serveLaunch.StdoutLog, `
        [string]$serveLaunch.StderrLog)
}
else {
    Write-Host ("ollama-api-ready: version={0}; port=11434" -f $ollamaVersion)
}

Write-Host "Update task completed: install-ollama"
