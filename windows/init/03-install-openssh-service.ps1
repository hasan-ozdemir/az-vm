$ErrorActionPreference = "Stop"
Write-Host "Init task started: install-openssh-service"

function Get-OpenSshService {
    return (Get-Service sshd -ErrorAction SilentlyContinue)
}

function Get-OpenSshInstallScriptPath {
    $openSshInstallScriptCandidates = @(
        "C:\Program Files\OpenSSH-Win64\install-sshd.ps1",
        "C:\Program Files\OpenSSH\install-sshd.ps1"
    )

    return ($openSshInstallScriptCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
}

function Wait-OpenSshServiceRegistration {
    param(
        [int]$TimeoutSeconds = 30
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $service = Get-OpenSshService
        if ($null -ne $service) {
            return $service
        }

        Start-Sleep -Seconds 1
    }

    return $null
}

if (-not (Get-OpenSshService)) {
    $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (-not (Test-Path -LiteralPath $chocoExe)) {
        throw "Chocolatey is required for OpenSSH installation."
    }

    & $chocoExe upgrade openssh -y --no-progress
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
        throw "choco upgrade openssh failed with exit code $LASTEXITCODE."
    }
}

if (-not (Get-OpenSshService)) {
    $installScript = Get-OpenSshInstallScriptPath
    if ($installScript) {
        Write-Host "Running OpenSSH service installer: $installScript"
        powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installScript
        if ($LASTEXITCODE -ne 0) {
            throw "OpenSSH install-sshd.ps1 failed with exit code $LASTEXITCODE."
        }
    }
}

$installScript = Get-OpenSshInstallScriptPath
$sshdService = Wait-OpenSshServiceRegistration -TimeoutSeconds 30
if ($null -eq $sshdService) {
    throw ("OpenSSH setup completed but sshd service was not found. install-script={0}" -f $(if ([string]::IsNullOrWhiteSpace([string]$installScript)) { 'missing' } else { [string]$installScript }))
}

Set-Service -Name sshd -StartupType Automatic
if (Get-Service ssh-agent -ErrorAction SilentlyContinue) {
    Set-Service -Name ssh-agent -StartupType Automatic
}

Write-Host ("openssh-service-ready: status={0}; start-type={1}" -f [string]$sshdService.Status, [string]$sshdService.StartType)
Write-Host "openssh-ready"
Write-Host "Init task completed: install-openssh-service"
