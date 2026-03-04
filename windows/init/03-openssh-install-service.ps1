$ErrorActionPreference = "Stop"
Write-Host "Init task started: openssh-install-service"

if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (-not (Test-Path -LiteralPath $chocoExe)) {
        throw "Chocolatey is required for OpenSSH installation."
    }

    & $chocoExe upgrade openssh -y --no-progress
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
        throw "choco upgrade openssh failed with exit code $LASTEXITCODE."
    }

    if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
        foreach ($installScript in @(
            "C:\Program Files\OpenSSH-Win64\install-sshd.ps1",
            "C:\ProgramData\chocolatey\lib\openssh\tools\install-sshd.ps1"
        )) {
            if (Test-Path -LiteralPath $installScript) {
                Write-Host "Running OpenSSH install script: $installScript"
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript
                break
            }
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
Write-Host "Init task completed: openssh-install-service"
