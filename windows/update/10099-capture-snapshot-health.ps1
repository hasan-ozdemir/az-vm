$ErrorActionPreference = "Stop"
Write-Host "Update task started: capture-snapshot-health"

$companyName = "__COMPANY_NAME__"
$managerUser = "__VM_ADMIN_USER__"
$assistantUser = "__ASSISTANT_USER__"
$publicDesktop = "C:\Users\Public\Desktop"
$shortcutRunAsAdminFlag = 0x00002000
$unresolvedCompanyNameToken = ('__' + 'COMPANY_NAME' + '__')

function Invoke-CommandWithTimeout {
    param(
        [scriptblock]$Action,
        [int]$TimeoutSeconds = 20
    )

    $job = Start-Job -ScriptBlock $Action
    $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if (-not $completed) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force
        return [pscustomobject]@{ Success = $false; TimedOut = $true }
    }

    $jobReceiveErrors = @()
    $output = Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobReceiveErrors
    if ($output) {
        $output | ForEach-Object { Write-Host ([string]$_) }
    }
    foreach ($jobError in @($jobReceiveErrors)) {
        Write-Warning ([string]$jobError)
    }

    $state = $job.ChildJobs[0].JobStateInfo.State
    $hadErrors = @($job.ChildJobs[0].Error).Count -gt 0
    Remove-Job -Job $job -Force
    return [pscustomobject]@{ Success = ($state -ne 'Failed' -and -not $hadErrors); TimedOut = $false }
}

function Test-InvalidCompanyName {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $true }
    $trimmed = $Value.Trim()
    if ([string]::Equals($trimmed, $unresolvedCompanyNameToken, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ([string]::Equals($trimmed, "company_name", [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($trimmed.StartsWith("__", [System.StringComparison]::Ordinal) -and $trimmed.EndsWith("__", [System.StringComparison]::Ordinal)) { return $true }
    return $false
}

function Get-ShortcutRunAsAdministratorFlag {
    param([string]$ShortcutPath)

    if ([string]::IsNullOrWhiteSpace([string]$ShortcutPath) -or -not (Test-Path -LiteralPath $ShortcutPath)) {
        return $false
    }

    $bytes = [System.IO.File]::ReadAllBytes($ShortcutPath)
    if ($bytes.Length -lt 0x18) {
        return $false
    }

    $linkFlags = [System.BitConverter]::ToUInt32($bytes, 0x14)
    return (($linkFlags -band [uint32]$shortcutRunAsAdminFlag) -ne 0)
}

function Get-ShortcutDetails {
    param([string]$ShortcutPath)

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    return [pscustomobject]@{
        TargetPath = [string]$shortcut.TargetPath
        Arguments = [string]$shortcut.Arguments
        WorkingDirectory = [string]$shortcut.WorkingDirectory
        Hotkey = [string]$shortcut.Hotkey
        WindowStyle = [int]$shortcut.WindowStyle
        RunAsAdmin = [bool](Get-ShortcutRunAsAdministratorFlag -ShortcutPath $ShortcutPath)
    }
}

function Write-DesktopArtifactScan {
    param(
        [string]$Label,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path) -or -not (Test-Path -LiteralPath $Path)) {
        Write-Host ("desktop-artifacts-skip => {0} => {1}" -f $Label, $Path)
        return
    }

    $matches = @(
        Get-ChildItem -LiteralPath $Path -Force -File -ErrorAction SilentlyContinue |
            Where-Object {
                [string]::Equals([string]$_.Name, 'desktop.ini', [System.StringComparison]::OrdinalIgnoreCase) -or
                [string]::Equals([string]$_.Name, 'Thumbs.db', [System.StringComparison]::OrdinalIgnoreCase)
            }
    )
    if (@($matches).Count -eq 0) {
        Write-Host ("desktop-artifacts-clean => {0} => {1}" -f $Label, $Path)
        return
    }

    foreach ($match in @($matches)) {
        Write-Host ("desktop-artifact => {0} => {1}" -f $Label, $match.FullName)
    }
}

function Write-DesktopState {
    param(
        [string]$Label,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path) -or -not (Test-Path -LiteralPath $Path)) {
        Write-Host ("desktop-state-skip => {0} => {1}" -f $Label, $Path)
        return
    }

    $entries = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    Write-Host ("desktop-state => {0} => count={1}" -f $Label, @($entries).Count)
    foreach ($entry in @($entries)) {
        Write-Host (" desktop-entry => {0}" -f $entry.FullName)
    }
}

$resolvedCompanyName = if (Test-InvalidCompanyName -Value $companyName) { $unresolvedCompanyNameToken } else { $companyName.Trim() }
$publicShortcutNames = @(
    "a1ChatGPT Web",
    "a2CodexApp",
    "a3Be My Eyes",
    "a4WhatsApp Kurumsal",
    "a5WhatsApp Bireysel",
    "a6AnyDesk",
    "a7Docker Desktop",
    "a8WindScribe",
    "a9VLC Player",
    "a10NVDA",
    "a11MS Edge",
    "a12Itunes",
    "b1GarantiBank Kurumsal",
    "b2GarantiBank Bireysel",
    "b3QnbBank Kurumsal",
    "b4QnbBank Bireysel",
    "b5AktifBank Kurumsal",
    "b6AktifBank Bireysel",
    "b7ZiraatBank Kurumsal",
    "b8ZiraatBank Bireysel",
    "c1Cmd",
    "d1RClone CLI",
    "d2One Drive",
    "d3Google Drive",
    "d4ICloud",
    "e1Mail <email>",
    "i1Internet",
    "k1Codex CLI",
    "k2Gemini CLI",
    "m1Dijital Vergi Dairesi",
    "n1Notepad",
    "o1Outlook",
    "o2Teams",
    "o3Word",
    "o4Excel",
    "o5Power Point",
    "o6OneNote",
    "r1Sahibinden Kurumsal",
    "r2Sahibinden Bireysel",
    "r3Letgo Kurumsal",
    "r4Letgo Bireysel",
    "r5Trendyol Kurumsal",
    "r6Trendyol Bireysel",
    "r7Amazon TR Kurumsal",
    "r8Amazon TR Bireysel",
    "r9HepsiBurada Kurumsal",
    "r10HepsiBurada Bireysel",
    "s1LinkedIn Kurumsal",
    "s2LinkedIn Bireysel",
    "s3YouTube Kurumsal",
    "s4YouTube Bireysel",
    "s5GitHub Kurumsal",
    "s6GitHub Bireysel",
    "s7TikTok Kurumsal",
    "s8TikTok Bireysel",
    "s9Instagram Kurumsal",
    "s10Instagram Bireysel",
    "s11Facebook Kurumsal",
    "s12Facebook Bireysel",
    "s13X-Twitter Kurumsal",
    "s14X-Twitter Bireysel",
    ("s15{0} Web" -f $resolvedCompanyName),
    ("s16{0} Blog" -f $resolvedCompanyName),
    "s17SnapChat Kurumsal",
    "s18Next Sosyal",
    "t1Git Bash",
    "t2Python CLI",
    "t3NodeJS CLI",
    "t4Ollama App",
    "t5Pwsh",
    "t6PS",
    "t7Azure CLI",
    "t8WSL",
    "t9Docker CLI",
    "t10AZD CLI",
    "t11GH CLI",
    "t12FFmpeg CLI",
    "t13Seven Zip CLI",
    "t14Process Explorer",
    "t15Io Unlocker",
    "u1User Files",
    "u2This PC",
    "u3Control Panel",
    "u7Network and Sharing",
    "v5VS Code",
    "z1Google Account Setup",
    "z2Office365 Account Setup"
)

Write-Host "Version Info:"
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    Write-Host "WindowsProductName=$($os.Caption)"
    Write-Host "WindowsVersion=$($os.Version)"
    Write-Host "OsBuildNumber=$($os.BuildNumber)"
}
catch {
    Write-Warning "Version info collection failed: $($_.Exception.Message)"
}

Write-Host "APP PATH CHECKS:"
foreach ($commandName in @("choco", "git", "node", "python", "py", "pwsh", "gh", "ffmpeg", "7z", "az", "docker", "wsl", "ollama")) {
    $cmd = Get-Command $commandName -ErrorAction SilentlyContinue
    if ($cmd) { Write-Host "$commandName => $($cmd.Source)" } else { Write-Host "$commandName => not-found" }
}

Write-Host "OPEN Ports:"
Get-NetTCPConnection -LocalPort __RDP_PORT__,__SSH_PORT__ -State Listen | Select-Object LocalAddress,LocalPort,OwningProcess | Format-Table -AutoSize
Write-Host "FIREWALL STATUS:"
Get-NetFirewallProfile | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction | Format-Table -AutoSize

Write-Host "RDP COMPATIBILITY:"
$rdpTcpRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
$terminalServerRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
Get-ItemProperty -Path $rdpTcpRoot -Name UserAuthentication,SecurityLayer,MinEncryptionLevel -ErrorAction SilentlyContinue | Format-List *
Get-ItemProperty -Path $terminalServerRoot -Name fDenyTSConnections -ErrorAction SilentlyContinue | Format-List *

Write-Host "AUTOLOGON STATUS:"
$winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$winlogon = Get-ItemProperty -Path $winlogonPath -ErrorAction SilentlyContinue
if ($null -eq $winlogon) {
    Write-Warning "Winlogon autologon state could not be read."
}
else {
    $autologonDomain = ''
    if ($winlogon.PSObject.Properties.Match('DefaultDomainName').Count -gt 0) {
        $autologonDomain = [string]$winlogon.DefaultDomainName
    }

    $managerAutologonConfigured = (
        [string]::Equals([string]$winlogon.AutoAdminLogon, '1', [System.StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$winlogon.DefaultUserName, $managerUser, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not [string]::IsNullOrWhiteSpace([string]$autologonDomain)
    )

    [pscustomobject]@{
        AutoAdminLogon = [string]$winlogon.AutoAdminLogon
        DefaultUserName = [string]$winlogon.DefaultUserName
        DefaultDomainName = [string]$autologonDomain
        manager_autologon_configured = [bool]$managerAutologonConfigured
    } | Format-List *
}

Write-Host "SYSTEM RESTORE STATUS:"
Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name DisableSR -ErrorAction SilentlyContinue | Format-List *
try {
    $restorePoints = @(Get-ComputerRestorePoint -ErrorAction Stop)
    Write-Host ("restore-point-count={0}" -f @($restorePoints).Count)
}
catch {
    Write-Warning ("Get-ComputerRestorePoint => {0}" -f $_.Exception.Message)
}
$shadowStatus = Invoke-CommandWithTimeout -TimeoutSeconds 20 -Action { vssadmin.exe list shadows }
if (-not $shadowStatus.Success) {
    Write-Warning "vssadmin list shadows did not complete successfully"
}

Write-Host "EXPLORER BAG STATUS:"
foreach ($registryPath in @(
    'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell',
    'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\1\Shell',
    'HKCU:\Software\Microsoft\Windows\Shell\Bags\1\Desktop'
)) {
    Write-Host ("bag => {0}" -f $registryPath)
    Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue | Format-List Mode,LogicalViewMode,GroupView,Sort,SortDirection,FolderType,IconSize
}

Write-Host "PUBLIC DESKTOP SHORTCUT STATUS:"
foreach ($shortcutName in @($publicShortcutNames)) {
    $shortcutPath = Join-Path $publicDesktop ($shortcutName + ".lnk")
    if (-not (Test-Path -LiteralPath $shortcutPath)) {
        Write-Host "missing-shortcut => $shortcutPath"
        continue
    }

    $shortcut = Get-ShortcutDetails -ShortcutPath $shortcutPath
    Write-Host "shortcut => $shortcutPath"
    Write-Host " target => $([string]$shortcut.TargetPath)"
    Write-Host " args => $([string]$shortcut.Arguments)"
    Write-Host " hotkey => $([string]$shortcut.Hotkey)"
    Write-Host " start-in => $([string]$shortcut.WorkingDirectory)"
    Write-Host " show => $([int]$shortcut.WindowStyle)"
    Write-Host " run-as-admin => $([bool]$shortcut.RunAsAdmin)"
}

Write-Host "PUBLIC DESKTOP MIRROR STATUS:"
$actualPublicShortcutNames = @(
    Get-ChildItem -LiteralPath $publicDesktop -Filter "*.lnk" -File -ErrorAction SilentlyContinue |
        ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension([string]$_.Name) }
)
$unexpectedShortcutNames = @($actualPublicShortcutNames | Where-Object { $publicShortcutNames -notcontains [string]$_ })
if (@($unexpectedShortcutNames).Count -eq 0) {
    Write-Host "unexpected-public-shortcut-count=0"
}
else {
    foreach ($shortcutName in @($unexpectedShortcutNames)) {
        Write-Host ("unexpected-public-shortcut => {0}" -f $shortcutName)
    }
}

Write-Host "PER-USER DESKTOP STATUS:"
Write-DesktopState -Label 'manager' -Path ("C:\Users\{0}\Desktop" -f $managerUser)
Write-DesktopState -Label 'assistant' -Path ("C:\Users\{0}\Desktop" -f $assistantUser)
Write-DesktopState -Label 'default' -Path 'C:\Users\Default\Desktop'
Write-DesktopState -Label 'public' -Path $publicDesktop

Write-Host "DESKTOP ARTIFACT STATUS:"
Write-DesktopArtifactScan -Label 'manager' -Path ("C:\Users\{0}\Desktop" -f $managerUser)
Write-DesktopArtifactScan -Label 'assistant' -Path ("C:\Users\{0}\Desktop" -f $assistantUser)
Write-DesktopArtifactScan -Label 'default' -Path 'C:\Users\Default\Desktop'
Write-DesktopArtifactScan -Label 'public' -Path $publicDesktop

Write-Host "SYSTEM VOLUME INFORMATION STATUS:"
foreach ($drive in @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DeviceID)) {
    $sviPath = ("{0}\System Volume Information" -f [string]$drive)
    Write-Host ("svi => {0} => {1}" -f $sviPath, (Test-Path -LiteralPath $sviPath))
}

Write-Host "AUTO-START APP STATUS:"
$machineStartupFolder = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
foreach ($startupShortcutName in @('Docker Desktop', 'Ollama', 'OneDrive', 'Teams', 'iTunesHelper')) {
    $startupShortcutPath = Join-Path $machineStartupFolder ($startupShortcutName + ".lnk")
    if (-not (Test-Path -LiteralPath $startupShortcutPath)) {
        Write-Host "missing-startup-shortcut => $startupShortcutPath"
        continue
    }

    $startupShortcut = Get-ShortcutDetails -ShortcutPath $startupShortcutPath
    Write-Host "startup-shortcut => $startupShortcutPath"
    Write-Host " target => $([string]$startupShortcut.TargetPath)"
    Write-Host " args => $([string]$startupShortcut.Arguments)"
    Write-Host " hotkey => $([string]$startupShortcut.Hotkey)"
}

Write-Host "capture-snapshot-health-completed"
Write-Host "Update task completed: capture-snapshot-health"
