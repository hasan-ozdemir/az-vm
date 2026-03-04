$ErrorActionPreference = "Stop"
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 0
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "SecurityLayer" -Value 1
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "MinEncryptionLevel" -Value 2
if (-not (Get-NetFirewallRule -DisplayName "Allow-TCP-3389" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow-TCP-3389" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -RemoteAddress Any -Profile Any | Out-Null
}
Set-Service -Name TermService -StartupType Automatic
sc.exe start TermService | Out-Null
$svcWait = [System.Diagnostics.Stopwatch]::StartNew()
do {
    Start-Sleep -Seconds 2
    $svc = Get-Service -Name TermService -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { break }
} while ($svcWait.Elapsed.TotalSeconds -lt 60)
if (-not $svc -or $svc.Status -ne "Running") {
    throw "TermService did not reach Running state within 60 seconds."
}
foreach ($port in @(__TCP_PORTS_PS_ARRAY__)) {
    $name = "Allow-TCP-$port"
    if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress Any -Profile Any | Out-Null
    }
}
Write-Output "rdp-firewall-ready"
