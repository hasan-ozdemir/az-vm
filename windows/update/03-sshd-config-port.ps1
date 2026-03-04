$ErrorActionPreference = "Stop"
$sshdConfig = "C:\ProgramData\ssh\sshd_config"
if (-not (Test-Path $sshdConfig)) { New-Item -Path $sshdConfig -ItemType File -Force | Out-Null }
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
        "Subsystem sftp sftp-server.exe"
    )
}
function Set-OrAdd([string]$Key,[string]$Value) {
    $regex = "^\s*#?\s*" + [regex]::Escape($Key) + "\s+.*$"
    $replacement = "$Key $Value"
    $updated = $false
    for ($i = 0; $i -lt $content.Count; $i++) {
        if ($content[$i] -match $regex) {
            $content[$i] = $replacement
            $updated = $true
        }
    }
    if (-not $updated) { $content += $replacement }
}
Set-OrAdd -Key "Port" -Value "__SSH_PORT__"
Set-OrAdd -Key "PasswordAuthentication" -Value "yes"
Set-OrAdd -Key "PubkeyAuthentication" -Value "no"
Set-OrAdd -Key "PermitEmptyPasswords" -Value "no"
Set-OrAdd -Key "AllowTcpForwarding" -Value "yes"
Set-OrAdd -Key "GatewayPorts" -Value "yes"
Set-OrAdd -Key "Subsystem sftp" -Value "sftp-server.exe"
Set-Content -Path $sshdConfig -Value $content -Encoding ascii
New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name "DefaultShell" -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
Restart-Service -Name sshd -Force
if (-not (Get-NetFirewallRule -DisplayName "Allow-SSH-__SSH_PORT__" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow-SSH-__SSH_PORT__" -Direction Inbound -Action Allow -Protocol TCP -LocalPort __SSH_PORT__ -RemoteAddress Any -Profile Any | Out-Null
}
Write-Output "sshd-config-ready"
