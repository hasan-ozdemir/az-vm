$ErrorActionPreference = "Stop"
Write-Host "Init task started: install-openssh-service"

if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (-not (Test-Path -LiteralPath $chocoExe)) {
        throw "Chocolatey is required for OpenSSH installation."
    }

    & $chocoExe upgrade openssh -y --no-progress
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
        throw "choco upgrade openssh failed with exit code $LASTEXITCODE."
    }
}

if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    $openSshInstallScriptCandidates = @(
        "C:\Program Files\OpenSSH-Win64\install-sshd.ps1",
        "C:\Program Files\OpenSSH\install-sshd.ps1"
    )
    $installScript = $openSshInstallScriptCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($installScript) {
        Write-Host "Running OpenSSH service installer: $installScript"
        powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installScript
        if ($LASTEXITCODE -ne 0) {
            throw "OpenSSH install-sshd.ps1 failed with exit code $LASTEXITCODE."
        }
    }
}

if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    throw "OpenSSH setup completed but sshd service was not found."
}

Set-Service -Name sshd -StartupType Automatic
if (Get-Service ssh-agent -ErrorAction SilentlyContinue) {
    Set-Service -Name ssh-agent -StartupType Automatic
}

Write-Host "openssh-ready"
Write-Host "Init task completed: install-openssh-service"
