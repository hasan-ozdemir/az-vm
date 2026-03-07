$ErrorActionPreference = "Stop"
Write-Host "Init task started: rdp-configure"

$rdpPort = [int]"__RDP_PORT__"
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 0
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "SecurityLayer" -Value 1
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "MinEncryptionLevel" -Value 2
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "PortNumber" -Value $rdpPort

$rdpRuleName = "Allow-RDP-$rdpPort"
$legacyRuleNames = @("Allow-TCP-3389")
$namedRules = @(Get-NetFirewallRule -DisplayName "Allow-RDP-*" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DisplayName)
foreach ($ruleName in @($legacyRuleNames + $namedRules)) {
    if ([string]::IsNullOrWhiteSpace([string]$ruleName)) {
        continue
    }
    if ([string]::Equals([string]$ruleName, $rdpRuleName, [System.StringComparison]::OrdinalIgnoreCase)) {
        continue
    }
    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Out-Null
}

if (-not (Get-NetFirewallRule -DisplayName $rdpRuleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $rdpRuleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $rdpPort -RemoteAddress Any -Profile Any | Out-Null
}
else {
    Enable-NetFirewallRule -DisplayName $rdpRuleName -ErrorAction SilentlyContinue | Out-Null
}

Set-Service -Name TermService -StartupType Automatic
$termService = Get-Service -Name TermService -ErrorAction SilentlyContinue
if ($termService -and $termService.Status -eq "Running") {
    Restart-Service -Name TermService -Force
}
else {
    Start-Service -Name TermService
}

$svcWait = [System.Diagnostics.Stopwatch]::StartNew()
do {
    Start-Sleep -Seconds 2
    $svc = Get-Service -Name TermService -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { break }
} while ($svcWait.Elapsed.TotalSeconds -lt 60)

if (-not $svc -or $svc.Status -ne "Running") {
    throw "TermService did not reach Running state."
}

Write-Host "rdp-ready"
Write-Host "Init task completed: rdp-configure"
