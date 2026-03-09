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

$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    throw "winget command is not available."
}

Write-Host "Resolved winget executable: $wingetExe"
Write-Host "Running: winget install --id Ollama.Ollama --accept-source-agreements --accept-package-agreements --silent --disable-interactivity --force"
& $wingetExe install --id Ollama.Ollama --accept-source-agreements --accept-package-agreements --silent --disable-interactivity --force
$wingetExit = [int]$LASTEXITCODE
if ($wingetExit -ne 0 -and $wingetExit -ne -1978335189) {
    throw "winget install Ollama.Ollama failed with exit code $wingetExit."
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

$ollamaVersion = Get-OllamaApiVersion -TimeoutSeconds 5
$serveProcess = $null
if ([string]::IsNullOrWhiteSpace([string]$ollamaVersion)) {
    Write-Host "Ollama API is not responding on 127.0.0.1:11434 yet. Starting 'ollama serve'."
    $serveProcess = Start-Process -FilePath $ollamaExe -ArgumentList 'serve' -WindowStyle Hidden -PassThru
    $ollamaVersion = Wait-OllamaApiReady -TimeoutSeconds 90
}

if ([string]::IsNullOrWhiteSpace([string]$ollamaVersion)) {
    if ($null -ne $serveProcess -and -not $serveProcess.HasExited) {
        Stop-Process -Id $serveProcess.Id -Force -ErrorAction SilentlyContinue
    }

    throw "Ollama API did not respond on 127.0.0.1:11434 after install."
}

if ($null -ne $serveProcess) {
    Write-Host ("ollama-api-ready: version={0}; port=11434; startedPid={1}" -f $ollamaVersion, [int]$serveProcess.Id)
}
else {
    Write-Host ("ollama-api-ready: version={0}; port=11434" -f $ollamaVersion)
}

Write-Host "Update task completed: install-ollama"
