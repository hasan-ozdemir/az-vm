$ErrorActionPreference = "Stop"
Write-Host "Init task started: configure-sshd-port"

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

function Wait-SshdListener {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 20
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if ($null -ne $listener) {
            return $true
        }

        Start-Sleep -Seconds 1
    }

    return $false
}

$sshdService = Get-OpenSshService
if ($null -eq $sshdService) {
    $installScript = Get-OpenSshInstallScriptPath
    if ([string]::IsNullOrWhiteSpace([string]$installScript)) {
        throw "OpenSSH service is missing and install-sshd.ps1 could not be found."
    }

    Write-Host "OpenSSH service is missing. Running service installer before sshd_config changes."
    powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installScript
    if ($LASTEXITCODE -ne 0) {
        throw "OpenSSH install-sshd.ps1 failed while recovering the sshd service."
    }

    $sshdService = Get-OpenSshService
    if ($null -eq $sshdService) {
        throw "OpenSSH service is still missing after running install-sshd.ps1."
    }
}

$sshdConfig = "C:\ProgramData\ssh\sshd_config"
if (-not (Test-Path -LiteralPath $sshdConfig)) {
    New-Item -Path $sshdConfig -ItemType File -Force
}

$content = @(Get-Content -Path $sshdConfig -ErrorAction SilentlyContinue)
if ($content.Count -eq 0) {
    $content = @(
        "# Generated baseline sshd_config",
        "Port 22",
        "PasswordAuthentication no",
        "PubkeyAuthentication yes",
        "PermitEmptyPasswords no",
        "AllowTcpForwarding yes",
        "GatewayPorts no",
        "Subsystem sftp C:/Windows/System32/OpenSSH/sftp-server.exe"
    )
}

function Set-OrAdd {
    param([string]$Key,[string]$Value)
    $regex = "^\s*#?\s*" + [regex]::Escape($Key) + "\s+.*$"
    $replacement = "$Key $Value"
    $updated = $false
    for ($i = 0; $i -lt $content.Count; $i++) {
        if ($content[$i] -match $regex) {
            $content[$i] = $replacement
            $updated = $true
        }
    }
    if (-not $updated) {
        $content += $replacement
    }
}

Set-OrAdd -Key "Port" -Value "__SSH_PORT__"
Set-OrAdd -Key "PasswordAuthentication" -Value "yes"
Set-OrAdd -Key "PubkeyAuthentication" -Value "no"
Set-OrAdd -Key "PermitEmptyPasswords" -Value "no"
Set-OrAdd -Key "AllowTcpForwarding" -Value "yes"
Set-OrAdd -Key "GatewayPorts" -Value "yes"
Set-OrAdd -Key "Subsystem sftp" -Value "C:/Windows/System32/OpenSSH/sftp-server.exe"
Set-Content -Path $sshdConfig -Value $content -Encoding ascii

New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name "DefaultShell" -Value "C:\Windows\System32\cmd.exe"

$sshdService = Get-OpenSshService
Set-Service -Name sshd -StartupType Automatic
if ([string]::Equals([string]$sshdService.Status, 'Running', [System.StringComparison]::OrdinalIgnoreCase)) {
    Restart-Service -Name sshd -Force
}
else {
    Start-Service -Name sshd
}

$sshRuleName = "Allow-SSH-__SSH_PORT__"
if (-not (Get-NetFirewallRule -DisplayName $sshRuleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $sshRuleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort __SSH_PORT__ -RemoteAddress Any -Profile Any
}

if (-not (Wait-SshdListener -Port __SSH_PORT__ -TimeoutSeconds 20)) {
    throw "sshd was configured, but the listener did not bind to the configured port in time."
}

Write-Host "sshd-config-ready"
Write-Host "Init task completed: configure-sshd-port"

