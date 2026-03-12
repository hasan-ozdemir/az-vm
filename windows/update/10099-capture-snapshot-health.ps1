$ErrorActionPreference = "Stop"
Write-Host "Update task started: capture-snapshot-health"

$companyName = "__COMPANY_NAME__"
$employeeEmailAddress = "__EMPLOYEE_EMAIL_ADDRESS__"
$employeeFullName = "__EMPLOYEE_FULL_NAME__"
$managerUser = "__VM_ADMIN_USER__"
$assistantUser = "__ASSISTANT_USER__"
$hostStartupProfileJsonBase64 = "__HOST_STARTUP_PROFILE_JSON_B64__"
$publicDesktop = "C:\Users\Public\Desktop"
$shortcutRunAsAdminFlag = 0x00002000
$unresolvedCompanyNameToken = ('__' + 'COMPANY_NAME' + '__')
$unresolvedEmployeeEmailAddressToken = ('__' + 'EMPLOYEE_EMAIL_ADDRESS' + '__')
$unresolvedEmployeeFullNameToken = ('__' + 'EMPLOYEE_FULL_NAME' + '__')

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

function Test-InvalidEmployeeEmailAddress {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $true }
    $trimmed = $Value.Trim()
    if ([string]::Equals($trimmed, $unresolvedEmployeeEmailAddressToken, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ([string]::Equals($trimmed, 'employee_email_address', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($trimmed.StartsWith("__", [System.StringComparison]::Ordinal) -and $trimmed.EndsWith("__", [System.StringComparison]::Ordinal)) { return $true }
    if (($trimmed -split '@').Count -lt 2) { return $true }
    return $false
}

function Test-InvalidEmployeeFullName {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $true }
    $trimmed = $Value.Trim()
    if ([string]::Equals($trimmed, $unresolvedEmployeeFullNameToken, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ([string]::Equals($trimmed, 'employee_full_name', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($trimmed.StartsWith("__", [System.StringComparison]::Ordinal) -and $trimmed.EndsWith("__", [System.StringComparison]::Ordinal)) { return $true }
    return $false
}

function ConvertTo-TitleCaseShortcutText {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return ""
    }

    $textInfo = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo
    return [string]$textInfo.ToTitleCase($Value.Trim().ToLowerInvariant())
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

function Convert-Base64JsonToObjectArray {
    param([string]$Base64Text)

    if ([string]::IsNullOrWhiteSpace([string]$Base64Text)) {
        return @()
    }

    try {
        $bytes = [Convert]::FromBase64String([string]$Base64Text)
        $json = [System.Text.Encoding]::UTF8.GetString($bytes)
        if ([string]::IsNullOrWhiteSpace([string]$json)) {
            return @()
        }

        $parsed = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        return @($parsed)
    }
    catch {
        Write-Warning ("startup-profile-decode-failed => {0}" -f $_.Exception.Message)
        return @()
    }
}

function Get-LocalUserProfileInfo {
    param([string]$UserName)

    if ([string]::IsNullOrWhiteSpace([string]$UserName)) {
        throw "User name is empty."
    }

    $expectedPath = "C:\Users\$UserName"
    $profile = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' -ErrorAction SilentlyContinue | Where-Object {
        [string]::Equals([string]$_.ProfileImagePath, $expectedPath, [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1

    if ($null -eq $profile) {
        throw ("Profile was not found for user '{0}'." -f $UserName)
    }

    return [pscustomobject]@{
        UserName = [string]$UserName
        Sid = [string]$profile.PSChildName
        ProfilePath = [string]$profile.ProfileImagePath
    }
}

function Remove-RegistryMountIfPresent {
    param([string]$MountName)

    if ([string]::IsNullOrWhiteSpace([string]$MountName)) {
        return
    }

    & reg.exe unload ("HKU\{0}" -f $MountName) | Out-Null
}

function Mount-RegistryHive {
    param(
        [string]$MountName,
        [string]$HiveFilePath
    )

    if ([string]::IsNullOrWhiteSpace([string]$MountName)) {
        throw "Registry mount name is empty."
    }
    if ([string]::IsNullOrWhiteSpace([string]$HiveFilePath) -or -not (Test-Path -LiteralPath $HiveFilePath)) {
        throw ("Registry hive file was not found: {0}" -f $HiveFilePath)
    }

    Remove-RegistryMountIfPresent -MountName $MountName
    & reg.exe load ("HKU\{0}" -f $MountName) $HiveFilePath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw ("reg load failed for HKU\{0} => {1}" -f $MountName, $HiveFilePath)
    }

    return ("Registry::HKEY_USERS\{0}" -f $MountName)
}

function Dismount-RegistryHive {
    param([string]$MountName)

    if ([string]::IsNullOrWhiteSpace([string]$MountName)) {
        return
    }

    try {
        Set-Location -Path 'C:\'
    }
    catch {
    }

    foreach ($attempt in 1..15) {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds 750

        & reg.exe unload ("HKU\{0}" -f $MountName) | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return
        }

        Start-Sleep -Seconds 2
    }

    Write-Warning ("reg unload failed for HKU\{0}" -f $MountName)
}

function Get-StartupApprovedStateCode {
    param(
        [string]$Path,
        [string]$ValueName
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path) -or [string]::IsNullOrWhiteSpace([string]$ValueName)) {
        return -1
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return -1
    }

    $item = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return -1
    }

    $property = @($item.PSObject.Properties | Where-Object { [string]$_.Name -eq $ValueName } | Select-Object -First 1)
    if (@($property).Count -eq 0 -or $null -eq $property[0].Value) {
        return -1
    }

    $bytes = @($property[0].Value)
    if (@($bytes).Count -eq 0) {
        return -1
    }

    return [int]$bytes[0]
}

function Get-ManagerContext {
    param([string]$UserName)

    $profileInfo = Get-LocalUserProfileInfo -UserName $UserName
    $mountName = ''
    $mainRoot = ("Registry::HKEY_USERS\{0}" -f [string]$profileInfo.Sid)
    if (-not (Test-Path -LiteralPath $mainRoot)) {
        $mountName = 'AzVm10099Manager'
        $mainRoot = Mount-RegistryHive -MountName $mountName -HiveFilePath (Join-Path ([string]$profileInfo.ProfilePath) 'NTUSER.DAT')
    }

    return [pscustomobject]@{
        ProfileInfo = $profileInfo
        MainRoot = [string]$mainRoot
        MountName = [string]$mountName
        StartupFolder = (Join-Path ([string]$profileInfo.ProfilePath) 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup')
        StartupApprovedStartupFolderPath = ("{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder" -f [string]$mainRoot)
        RunPath = ("{0}\Software\Microsoft\Windows\CurrentVersion\Run" -f [string]$mainRoot)
        RunApprovalPath = ("{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" -f [string]$mainRoot)
        Run32Path = ("{0}\Software\Microsoft\Windows\CurrentVersion\Run32" -f [string]$mainRoot)
        Run32ApprovalPath = ("{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32" -f [string]$mainRoot)
    }
}

function Resolve-StartupDisplayName {
    param([string]$Key)

    switch ([string]$Key) {
        'docker-desktop' { return 'Docker Desktop' }
        'ollama' { return 'Ollama' }
        'onedrive' { return 'OneDrive' }
        'teams' { return 'Teams' }
        'itunes-helper' { return 'iTunesHelper' }
        'google-drive' { return 'Google Drive' }
        'windscribe' { return 'Windscribe' }
        'anydesk' { return 'AnyDesk' }
        'codex-app' { return 'Codex App' }
        default { return '' }
    }
}

function Get-StartupLocationDefinitions {
    param([pscustomobject]$ManagerContext)

    return @(
        [pscustomobject]@{
            Scope = 'CurrentUser'
            EntryType = 'Run'
            Kind = 'Run'
            RunPath = [string]$ManagerContext.RunPath
            ApprovalPath = [string]$ManagerContext.RunApprovalPath
        }
        [pscustomobject]@{
            Scope = 'CurrentUser'
            EntryType = 'Run32'
            Kind = 'Run'
            RunPath = [string]$ManagerContext.Run32Path
            ApprovalPath = [string]$ManagerContext.Run32ApprovalPath
        }
        [pscustomobject]@{
            Scope = 'CurrentUser'
            EntryType = 'StartupFolder'
            Kind = 'StartupFolder'
            DirectoryPath = [string]$ManagerContext.StartupFolder
            ApprovalPath = [string]$ManagerContext.StartupApprovedStartupFolderPath
        }
        [pscustomobject]@{
            Scope = 'LocalMachine'
            EntryType = 'Run'
            Kind = 'Run'
            RunPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
            ApprovalPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        }
        [pscustomobject]@{
            Scope = 'LocalMachine'
            EntryType = 'Run32'
            Kind = 'Run'
            RunPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run32'
            ApprovalPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
        }
        [pscustomobject]@{
            Scope = 'LocalMachine'
            EntryType = 'StartupFolder'
            Kind = 'StartupFolder'
            DirectoryPath = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp'
            ApprovalPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
        }
    )
}

function Resolve-RequestedStartupLocation {
    param(
        [psobject]$ProfileEntry,
        [object[]]$LocationDefinitions
    )

    if ($null -eq $ProfileEntry) {
        return $null
    }

    $scope = if ($ProfileEntry.PSObject.Properties.Match('Scope').Count -gt 0) { [string]$ProfileEntry.Scope } else { '' }
    $entryType = if ($ProfileEntry.PSObject.Properties.Match('EntryType').Count -gt 0) { [string]$ProfileEntry.EntryType } else { '' }

    return @(
        @($LocationDefinitions) |
            Where-Object {
                [string]::Equals([string]$_.Scope, $scope, [System.StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals([string]$_.EntryType, $entryType, [System.StringComparison]::OrdinalIgnoreCase)
            } |
            Select-Object -First 1
    )[0]
}

function Get-RegistryValueText {
    param(
        [string]$Path,
        [string]$ValueName
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path) -or [string]::IsNullOrWhiteSpace([string]$ValueName)) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $item = Get-ItemProperty -Path $Path -Name $ValueName -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $null
    }

    return [string]$item.$ValueName
}

function Write-ShortcutReadback {
    param(
        [string]$Label,
        [string]$ShortcutPath
    )

    $shortcut = Get-ShortcutDetails -ShortcutPath $ShortcutPath
    Write-Host ("{0} => {1}" -f $Label, $ShortcutPath)
    Write-Host (" target => {0}" -f [string]$shortcut.TargetPath)
    Write-Host (" args => {0}" -f [string]$shortcut.Arguments)
    Write-Host (" hotkey => {0}" -f [string]$shortcut.Hotkey)
    Write-Host (" start-in => {0}" -f [string]$shortcut.WorkingDirectory)
    Write-Host (" show => {0}" -f [int]$shortcut.WindowStyle)
    Write-Host (" run-as-admin => {0}" -f [bool]$shortcut.RunAsAdmin)
}

function Write-StartupEntryStatus {
    param(
        [string]$DisplayName,
        [psobject]$ProfileEntry,
        [object[]]$LocationDefinitions
    )

    $location = Resolve-RequestedStartupLocation -ProfileEntry $ProfileEntry -LocationDefinitions $LocationDefinitions
    if ($null -eq $location) {
        Write-Warning ("startup-entry-skip => {0} => unsupported method '{1}/{2}'." -f $DisplayName, [string]$ProfileEntry.Scope, [string]$ProfileEntry.EntryType)
        return
    }

    if ([string]::Equals([string]$location.Kind, 'Run', [System.StringComparison]::OrdinalIgnoreCase)) {
        $commandText = Get-RegistryValueText -Path ([string]$location.RunPath) -ValueName $DisplayName
        if ($null -eq $commandText) {
            Write-Host ("missing-startup-entry => {0} => {1}/{2}" -f $DisplayName, [string]$location.Scope, [string]$location.EntryType)
            return
        }

        $approvalState = Get-StartupApprovedStateCode -Path ([string]$location.ApprovalPath) -ValueName $DisplayName
        Write-Host ("startup-entry => {0} => {1}/{2}" -f $DisplayName, [string]$location.Scope, [string]$location.EntryType)
        Write-Host (" command => {0}" -f [string]$commandText)
        Write-Host (" approval-state => {0}" -f [int]$approvalState)
        Write-Host (" enabled => {0}" -f [bool]($approvalState -lt 0 -or $approvalState -eq 2))
        return
    }

    $shortcutPath = Join-Path ([string]$location.DirectoryPath) ($DisplayName + '.lnk')
    if (-not (Test-Path -LiteralPath $shortcutPath)) {
        Write-Host ("missing-startup-entry => {0} => {1}/{2}" -f $DisplayName, [string]$location.Scope, [string]$location.EntryType)
        return
    }

    $approvalState = Get-StartupApprovedStateCode -Path ([string]$location.ApprovalPath) -ValueName ($DisplayName + '.lnk')
    Write-ShortcutReadback -Label 'startup-entry' -ShortcutPath $shortcutPath
    Write-Host (" scope => {0}" -f [string]$location.Scope)
    Write-Host (" method => {0}" -f [string]$location.EntryType)
    Write-Host (" approval-state => {0}" -f [int]$approvalState)
    Write-Host (" enabled => {0}" -f [bool]($approvalState -lt 0 -or $approvalState -eq 2))
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
$resolvedCompanyDisplayName = if (Test-InvalidCompanyName -Value $companyName) { $unresolvedCompanyNameToken } else { ConvertTo-TitleCaseShortcutText -Value $companyName.Trim() }
$resolvedEmployeeEmailAddress = if (Test-InvalidEmployeeEmailAddress -Value $employeeEmailAddress) { $unresolvedEmployeeEmailAddressToken } else { $employeeEmailAddress.Trim() }
$resolvedEmployeeFullName = if (Test-InvalidEmployeeFullName -Value $employeeFullName) { $unresolvedEmployeeFullNameToken } else { $employeeFullName.Trim() }
$publicShortcutNames = @(
    "a1ChatGPT Web",
    "a2CodexApp",
    "a3Be My Eyes",
    "a4WhatsApp Business",
    "a5WhatsApp Personal",
    "a6AnyDesk",
    "a7Docker Desktop",
    "a8WindScribe",
    "a9VLC Player",
    "a10NVDA",
    "a11MS Edge",
    "a12Itunes",
    "b1GarantiBank Business",
    "b2GarantiBank Personal",
    "b3QnbBank Business",
    "b4QnbBank Personal",
    "b5AktifBank Business",
    "b6AktifBank Personal",
    "b7ZiraatBank Business",
    "b8ZiraatBank Personal",
    "c1Cmd",
    "d1RClone CLI",
    "d2One Drive",
    "d3Google Drive",
    "d4ICloud",
    ("e1Mail {0}" -f $resolvedEmployeeEmailAddress),
    "g1Apple Developer",
    "g2Google Developer",
    "g3Microsoft Developer",
    "g4Azure Portal",
    "i1Internet Business",
    "i2Internet Personal",
    "k1Codex CLI",
    "k2Gemini CLI",
    "k3Github Copilot CLI",
    "m1Digital Tax Office",
    "n1Notepad",
    "o1Outlook",
    "o2Teams",
    "o3Word",
    "o4Excel",
    "o5Power Point",
    "o6OneNote",
    "q1SourTimes",
    "q2Spotify",
    "q3Netflix",
    "q4eGovernment",
    "q5Apple Account",
    "q6AJet Flights",
    "q7TCDD Train",
    "q8OBilet Bus",
    "r1Sahibinden Business",
    "r2Sahibinden Personal",
    "r3Letgo Business",
    "r4Letgo Personal",
    "r5Trendyol Business",
    "r6Trendyol Personal",
    "r7Amazon TR Business",
    "r8Amazon TR Personal",
    "r9HepsiBurada Business",
    "r10HepsiBurada Personal",
    "r11N11 Business",
    "r12N11 Personal",
    "r13ÇiçekSepeti Business",
    "r14ÇiçekSepeti Personal",
    "r15Pazarama Business",
    "r16Pazarama Personal",
    "r17PTTAVM Business",
    "r18PTTAVM Personal",
    "r19Ozon Business",
    "r20Ozon Personal",
    "r21Getir Business",
    "r22Getir Personal",
    "s1LinkedIn Business",
    "s2LinkedIn Personal",
    "s3YouTube Business",
    "s4YouTube Personal",
    "s5GitHub Business",
    "s6GitHub Personal",
    "s7TikTok Business",
    "s8TikTok Personal",
    "s9Instagram Business",
    "s10Instagram Personal",
    "s11Facebook Business",
    "s12Facebook Personal",
    "s13X-Twitter Business",
    "s14X-Twitter Personal",
    ("s15{0} Web" -f $resolvedCompanyDisplayName),
    ("s16{0} Blog" -f $resolvedCompanyDisplayName),
    "s17SnapChat Business",
    "s18NextSosyal Business",
    "t1Git Bash",
    "t2Python CLI",
    "t3NodeJS CLI",
    "t4Ollama App",
    "t5Pwsh",
    "t6PS",
    "t7Azure CLI",
    "t8WSL",
    "t9Docker CLI",
    "t10Azd CLI",
    "t11GH CLI",
    "t12FFmpeg CLI",
    "t13Seven Zip CLI",
    "t14Process Explorer",
    "t15Io Unlocker",
    "u1User Files",
    "u2This PC",
    "u3Control Panel",
    "u7Network and Sharing",
    "v1VS2022Com",
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

Write-Host "PUBLIC DESKTOP RECONCILE STATUS:"
$actualPublicShortcutFiles = @(
    Get-ChildItem -LiteralPath $publicDesktop -Filter "*.lnk" -File -ErrorAction SilentlyContinue | Sort-Object Name
)
$unmanagedPublicShortcutFiles = @(
    @($actualPublicShortcutFiles) |
        Where-Object {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension([string]$_.Name)
            return ($publicShortcutNames -notcontains [string]$baseName)
        }
)
Write-Host ("unmanaged-public-shortcut-count={0}" -f @($unmanagedPublicShortcutFiles).Count)
foreach ($shortcutFile in @($unmanagedPublicShortcutFiles)) {
    Write-ShortcutReadback -Label 'unmanaged-public-shortcut' -ShortcutPath ([string]$shortcutFile.FullName)
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
$startupProfile = @(Convert-Base64JsonToObjectArray -Base64Text $hostStartupProfileJsonBase64)
$startupProfileByKey = @{}
foreach ($entry in @($startupProfile)) {
    if ($null -eq $entry) {
        continue
    }

    $key = if ($entry.PSObject.Properties.Match('Key').Count -gt 0) { [string]$entry.Key } else { '' }
    if ([string]::IsNullOrWhiteSpace([string]$key) -or $startupProfileByKey.ContainsKey($key)) {
        continue
    }

    $startupProfileByKey[$key] = $entry
}

$startupProfileSummary = @(
    @($startupProfileByKey.Keys | Sort-Object) |
        ForEach-Object {
            $entry = $startupProfileByKey[[string]$_]
            ("{0}:{1}:{2}" -f [string]$_, [string]$entry.EntryType, [string]$entry.Scope)
        }
)
if (@($startupProfileSummary).Count -eq 0) {
    Write-Host 'host-startup-profile => none'
}
else {
    Write-Host ("host-startup-profile => {0}" -f ($startupProfileSummary -join ', '))
}

$managerContext = $null
try {
    $managerContext = Get-ManagerContext -UserName $managerUser
    $startupLocationDefinitions = @(Get-StartupLocationDefinitions -ManagerContext $managerContext)

    foreach ($startupKey in @($startupProfileByKey.Keys | Sort-Object)) {
        $displayName = Resolve-StartupDisplayName -Key ([string]$startupKey)
        if ([string]::IsNullOrWhiteSpace([string]$displayName)) {
            Write-Host ("unsupported-startup-key => {0}" -f [string]$startupKey)
            continue
        }

        Write-StartupEntryStatus -DisplayName $displayName -ProfileEntry $startupProfileByKey[[string]$startupKey] -LocationDefinitions $startupLocationDefinitions
    }
}
catch {
    Write-Warning ("startup-health-readback-failed => {0}" -f $_.Exception.Message)
}
finally {
    if ($null -ne $managerContext -and -not [string]::IsNullOrWhiteSpace([string]$managerContext.MountName)) {
        Dismount-RegistryHive -MountName ([string]$managerContext.MountName)
    }
}

Write-Host "capture-snapshot-health-completed"
Write-Host "Update task completed: capture-snapshot-health"
