param(
    [switch]$WorkerMode,
    [string]$ResultPath = '',
    [string]$TaskName = '10003-configure-ux-windows'
)

$ErrorActionPreference = "Stop"
if (-not $WorkerMode) {
    Write-Host "Update task started: configure-ux-windows"
}

$managerUser = "__VM_ADMIN_USER__"
$managerPassword = "__VM_ADMIN_PASS__"
$notepadPath = Join-Path $env:WINDIR "System32\notepad.exe"
$helperPath = "C:\Windows\Temp\az-vm-interactive-session-helper.ps1"
$textExtensions = @(".txt", ".log", ".ini", ".cfg", ".conf", ".csv", ".xml", ".json", ".yaml", ".yml", ".md", ".ps1", ".cmd", ".bat", ".reg", ".sql")
$artifactFileNames = @('desktop.ini', 'Thumbs.db')
$details = New-Object 'System.Collections.Generic.List[string]'

if (-not (Test-Path -LiteralPath $helperPath)) {
    throw ("Interactive session helper was not found: {0}" -f $helperPath)
}

. $helperPath

function Add-Detail {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace([string]$Text)) {
        return
    }

    [void]$details.Add([string]$Text)
    Write-Host ([string]$Text)
}

function Assert-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$ExpectedValue
    )

    if ([string]::IsNullOrWhiteSpace([string]$Name) -or [string]::Equals([string]$Name, '(default)', [System.StringComparison]::OrdinalIgnoreCase)) {
        $actualValue = [string](Get-Item -Path $Path -ErrorAction Stop).GetValue('')
    }
    else {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        $actualValue = $item.$Name
    }

    if ([string]$actualValue -ne [string]$ExpectedValue) {
        throw ("Registry validation failed: {0}\{1} expected '{2}' but got '{3}'." -f $Path, $Name, $ExpectedValue, $actualValue)
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

    & reg.exe unload ("HKU\{0}" -f $MountName) | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw ("reg unload failed for HKU\{0}" -f $MountName)
    }
}

function Resolve-ManagerRegistryRoots {
    param([pscustomobject]$ProfileInfo)

    if ($null -eq $ProfileInfo) {
        throw "Profile info is required."
    }

    $mainRoot = ("Registry::HKEY_USERS\{0}" -f [string]$ProfileInfo.Sid)
    if (-not (Test-Path -LiteralPath $mainRoot)) {
        throw ("Loaded user hive was not found for SID '{0}'." -f [string]$ProfileInfo.Sid)
    }

    $classesRoot = ("Registry::HKEY_USERS\{0}_Classes" -f [string]$ProfileInfo.Sid)
    $classesMountName = ''
    if (-not (Test-Path -LiteralPath $classesRoot)) {
        $usrClassPath = Join-Path ([string]$ProfileInfo.ProfilePath) 'AppData\Local\Microsoft\Windows\UsrClass.dat'
        $classesMountName = 'AzVm04ManagerClasses'
        $classesRoot = Mount-RegistryHive -MountName $classesMountName -HiveFilePath $usrClassPath
    }

    return [pscustomobject]@{
        MainRoot = [string]$mainRoot
        ClassesRoot = [string]$classesRoot
        ClassesMountName = [string]$classesMountName
    }
}

function Clear-DesktopEntries {
    param([string]$DesktopPath)

    if ([string]::IsNullOrWhiteSpace([string]$DesktopPath)) {
        return
    }

    if (-not (Test-Path -LiteralPath $DesktopPath)) {
        Write-Host ("desktop-cleanup-skip: profile not found => {0}" -f $DesktopPath)
        return
    }

    Get-ChildItem -LiteralPath $DesktopPath -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.PSIsContainer) {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
        }
        else {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
        }
    }

    Write-Host ("desktop-cleanup-ok: {0}" -f $DesktopPath)
}

function Write-Utf8JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $parentPath = Split-Path -Path $Path -Parent
    Ensure-AzVmDirectory -Path $parentPath
    $jsonText = [string]($Value | ConvertTo-Json -Depth 20)
    [System.IO.File]::WriteAllText($Path, $jsonText, (New-Object System.Text.UTF8Encoding($false)))
}

function Stop-TaskManagerProcesses {
    $running = @(Get-Process -Name 'Taskmgr' -ErrorAction SilentlyContinue)
    foreach ($proc in @($running)) {
        try {
            Stop-Process -Id ([int]$proc.Id) -Force -ErrorAction Stop
        }
        catch {
        }
    }
}

function Start-TaskManagerProcess {
    $taskManagerExe = Join-Path $env:WINDIR 'System32\taskmgr.exe'
    if (-not (Test-Path -LiteralPath $taskManagerExe)) {
        throw ("taskmgr.exe was not found: {0}" -f $taskManagerExe)
    }

    return (Start-Process -FilePath $taskManagerExe -PassThru)
}

function Test-TaskManagerLaunch {
    param(
        [string]$Phase,
        [int]$HealthySeconds = 4
    )

    Stop-TaskManagerProcesses
    Start-Sleep -Milliseconds 500

    try {
        $proc = Start-TaskManagerProcess
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($message -match '(?i)unauthorized') {
            Add-Detail ("task-manager-launch-{0}:unavailable" -f $Phase)
            Add-Detail ("task-manager-launch-{0}-reason:{1}" -f $Phase, $message)
            return [pscustomobject]@{ Status = 'unavailable'; Message = $message }
        }

        Add-Detail ("task-manager-launch-{0}:failed" -f $Phase)
        Add-Detail ("task-manager-launch-{0}-reason:{1}" -f $Phase, $message)
        return [pscustomobject]@{ Status = 'failed'; Message = $message }
    }

    Start-Sleep -Seconds $HealthySeconds
    $isHealthy = ($null -ne $proc -and -not $proc.HasExited)
    Add-Detail ("task-manager-launch-{0}:{1}" -f $Phase, $(if ($isHealthy) { 'ok' } else { 'failed' }))
    Stop-TaskManagerProcesses
    Start-Sleep -Seconds 1

    return [pscustomobject]@{
        Status = $(if ($isHealthy) { 'ok' } else { 'failed' })
        Message = ''
    }
}

function Backup-TaskManagerSettings {
    param([string]$SettingsPath)

    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        return ''
    }

    $backupPath = $SettingsPath + '.az-vm-backup'
    Copy-Item -LiteralPath $SettingsPath -Destination $backupPath -Force
    Add-Detail ("task-manager-settings-backup: {0}" -f $backupPath)
    return [string]$backupPath
}

function Restore-TaskManagerSettings {
    param(
        [string]$BackupPath,
        [string]$SettingsPath
    )

    if ([string]::IsNullOrWhiteSpace([string]$BackupPath) -or -not (Test-Path -LiteralPath $BackupPath)) {
        return $false
    }

    Copy-Item -LiteralPath $BackupPath -Destination $SettingsPath -Force
    Add-Detail ("task-manager-settings-restored: {0}" -f $SettingsPath)
    return $true
}

function Remove-TaskManagerSettings {
    param([string]$SettingsPath)

    if (Test-Path -LiteralPath $SettingsPath) {
        Remove-Item -LiteralPath $SettingsPath -Force -ErrorAction Stop
        Add-Detail ("task-manager-settings-reset: {0}" -f $SettingsPath)
    }
}

function Read-TaskManagerSettings {
    param([string]$SettingsPath)

    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        throw ("Task Manager settings.json was not found: {0}" -f $SettingsPath)
    }

    $raw = [string](Get-Content -LiteralPath $SettingsPath -Raw -ErrorAction Stop)
    if ([string]::IsNullOrWhiteSpace([string]$raw)) {
        throw ("Task Manager settings.json is empty: {0}" -f $SettingsPath)
    }

    try {
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        throw ("Task Manager settings.json is not valid JSON: {0}" -f $_.Exception.Message)
    }
}

function Ensure-TaskManagerFullViewSetting {
    param([string]$ProfilePath)

    $settingsDirectory = Join-Path $ProfilePath 'AppData\Local\Microsoft\Windows\TaskManager'
    $settingsPath = Join-Path $ProfilePath 'AppData\Local\Microsoft\Windows\TaskManager\settings.json'
    Ensure-AzVmDirectory -Path $settingsDirectory

    if (-not (Test-Path -LiteralPath $settingsPath)) {
        Add-Detail 'task-manager-settings-skip:no-store'
        return
    }

    $backupPath = Backup-TaskManagerSettings -SettingsPath $settingsPath
    $resetRequired = $false
    $settings = $null

    try {
        $settings = Read-TaskManagerSettings -SettingsPath $settingsPath
    }
    catch {
        Add-Detail ("task-manager-settings-invalid: {0}" -f $_.Exception.Message)
        $resetRequired = $true
    }

    if (-not $resetRequired -and $null -ne $settings) {
        $propertyNames = @($settings.PSObject.Properties | ForEach-Object { [string]$_.Name })
        if (@($propertyNames).Count -le 1 -and @($propertyNames).Count -eq 1 -and [string]::Equals($propertyNames[0], 'SmallView', [System.StringComparison]::OrdinalIgnoreCase)) {
            Add-Detail 'task-manager-settings-reset:repo-minimal-store-detected'
            $resetRequired = $true
        }
    }

    if ($resetRequired) {
        Remove-TaskManagerSettings -SettingsPath $settingsPath
        if (-not [string]::IsNullOrWhiteSpace([string]$backupPath) -and (Test-Path -LiteralPath $backupPath)) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
        Add-Detail 'task-manager-settings-reset-for-regeneration'
        return
    }

    if ($settings.PSObject.Properties.Match('SmallView').Count -eq 0) {
        $settings | Add-Member -NotePropertyName 'SmallView' -NotePropertyValue $false
    }
    else {
        $settings.SmallView = $false
    }

    Write-Utf8JsonFile -Path $settingsPath -Value $settings
    $writtenSettings = Read-TaskManagerSettings -SettingsPath $settingsPath
    if ($writtenSettings.PSObject.Properties.Match('SmallView').Count -eq 0 -or [bool]$writtenSettings.SmallView) {
        throw "Task Manager settings.json did not persist SmallView=false."
    }

    Add-Detail ("task-manager-settings-store: {0}" -f $settingsPath)
    Add-Detail 'task-manager-settings-small-view-false'

    if (-not [string]::IsNullOrWhiteSpace([string]$backupPath) -and (Test-Path -LiteralPath $backupPath)) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Restart-ExplorerShell {
    $explorerExe = Join-Path $env:WINDIR 'explorer.exe'
    $running = @(Get-Process -Name 'explorer' -ErrorAction SilentlyContinue)
    if (@($running).Count -eq 0) {
        Add-Detail 'explorer-shell-refresh-skip:no-running-explorer'
        return
    }

    foreach ($proc in @($running)) {
        try {
            Stop-Process -Id ([int]$proc.Id) -Force -ErrorAction Stop
        }
        catch {
            Add-Detail ("explorer-stop-skip:{0}" -f $_.Exception.Message)
        }
    }

    Start-Sleep -Seconds 2
    if (Test-Path -LiteralPath $explorerExe) {
        try {
            Start-Process -FilePath $explorerExe | Out-Null
            Add-Detail 'explorer-shell-restarted'
        }
        catch {
            Add-Detail ("explorer-start-skip:{0}" -f $_.Exception.Message)
        }
    }
}

function Get-FixedDriveRoots {
    $drives = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DeviceID)
    if (@($drives).Count -eq 0) {
        $drives = @('C:')
    }

    return @(
        $drives |
            ForEach-Object {
                $value = [string]$_
                if ([string]::IsNullOrWhiteSpace([string]$value)) {
                    return
                }

                if ($value.EndsWith('\', [System.StringComparison]::Ordinal)) {
                    return $value
                }

                return ($value + '\')
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Select-Object -Unique
    )
}

function Invoke-BestEffortStep {
    param(
        [string]$Label,
        [scriptblock]$Action
    )

    try {
        & $Action
        Add-Detail ("best-effort-ok:{0}" -f $Label)
    }
    catch {
        Add-Detail ("best-effort-warning:{0}:{1}" -f $Label, $_.Exception.Message)
    }
}

function Remove-KnownArtifactFiles {
    param([string[]]$RootPaths)

    foreach ($rootPath in @($RootPaths)) {
        if ([string]::IsNullOrWhiteSpace([string]$rootPath) -or -not (Test-Path -LiteralPath $rootPath)) {
            continue
        }

        foreach ($artifactFileName in @($artifactFileNames)) {
            Get-ChildItem -LiteralPath $rootPath -Filter $artifactFileName -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                Add-Detail ("artifact-file-removed:{0}" -f $_.FullName)
            }
        }
    }
}

function Remove-SystemVolumeInformationBestEffort {
    param([string[]]$DriveRoots)

    foreach ($driveRoot in @($DriveRoots)) {
        if ([string]::IsNullOrWhiteSpace([string]$driveRoot)) {
            continue
        }

        $sviPath = Join-Path $driveRoot 'System Volume Information'
        if (-not (Test-Path -LiteralPath $sviPath)) {
            continue
        }

        Invoke-BestEffortStep -Label ("system-volume-information:{0}" -f $driveRoot) -Action {
            cmd.exe /d /c "attrib -h -s `"$sviPath`"" | Out-Null
            Remove-Item -LiteralPath $sviPath -Recurse -Force -ErrorAction Stop
        }
    }
}

function Disable-SystemRestoreAndDeleteShadows {
    param([string[]]$DriveRoots)

    foreach ($driveRoot in @($DriveRoots)) {
        if ([string]::IsNullOrWhiteSpace([string]$driveRoot)) {
            continue
        }

        Disable-ComputerRestore -Drive $driveRoot -ErrorAction Stop
        $volumeName = $driveRoot.TrimEnd('\')
        & vssadmin.exe delete shadows /for=$volumeName /all /quiet | Out-Null
        $shadowDeleteExit = [int]$LASTEXITCODE
        if ($shadowDeleteExit -ne 0) {
            Add-Detail ("shadow-delete-warning:{0}:exit={1}" -f $volumeName, $shadowDeleteExit)
        }
        else {
            Add-Detail ("shadow-delete-ok:{0}" -f $volumeName)
        }
    }

    $systemRestoreRoot = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    Set-AzVmRegistryValue -Path $systemRestoreRoot -Name 'DisableSR' -Value 1 -Kind DWord
}

function Invoke-WindowsUxPerformanceTuning {
    $managerRoots = $null

    try {
        Add-Detail 'ux-worker-begin'
        $managerProfileInfo = Get-LocalUserProfileInfo -UserName $managerUser
        $managerProfilePath = [string]$managerProfileInfo.ProfilePath
        $assistantDesktopPath = Join-Path ("C:\Users\__ASSISTANT_USER__") 'Desktop'
        $defaultDesktopPath = 'C:\Users\Default\Desktop'
        $publicDesktopPath = 'C:\Users\Public\Desktop'
        $knownDesktopRoots = @($publicDesktopPath, (Join-Path $managerProfilePath 'Desktop'), $assistantDesktopPath, $defaultDesktopPath)
        $fixedDriveRoots = @(Get-FixedDriveRoots)
        $currentUserName = [string][Environment]::UserName
        Add-Detail ("ux-worker-profile-info:{0}" -f $managerProfilePath)
        if ([string]::Equals($currentUserName, $managerUser, [System.StringComparison]::OrdinalIgnoreCase)) {
            $managerMainRoot = 'Registry::HKEY_CURRENT_USER'
            $managerClassesRoot = 'Registry::HKEY_CURRENT_USER\Software\Classes'
            Add-Detail 'ux-worker-roots-ready:current-user-hive'
        }
        else {
            $managerRoots = Resolve-ManagerRegistryRoots -ProfileInfo $managerProfileInfo
            $managerMainRoot = [string]$managerRoots.MainRoot
            $managerClassesRoot = [string]$managerRoots.ClassesRoot
            Add-Detail ("ux-worker-roots-ready:{0}|{1}" -f $managerMainRoot, $managerClassesRoot)
        }

        Add-Detail 'ux-worker-machine-policy-begin'
        $tsPolicy = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
        Set-AzVmRegistryValue -Path $tsPolicy -Name "fDisableWallpaper" -Value 1 -Kind DWord
        Set-AzVmRegistryValue -Path $tsPolicy -Name "fDisableFullWindowDrag" -Value 1 -Kind DWord
        Set-AzVmRegistryValue -Path $tsPolicy -Name "fDisableMenuAnims" -Value 1 -Kind DWord
        Set-AzVmRegistryValue -Path $tsPolicy -Name "fDisableThemes" -Value 1 -Kind DWord
        Set-AzVmRegistryValue -Path $tsPolicy -Name "fDisableCursorSetting" -Value 1 -Kind DWord
        Set-AzVmRegistryValue -Path $tsPolicy -Name "fDisableFontSmoothing" -Value 1 -Kind DWord

        $oobePolicy = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\OOBE"
        Set-AzVmRegistryValue -Path $oobePolicy -Name "DisablePrivacyExperience" -Value 1 -Kind DWord

        $cloudContent = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
        Set-AzVmRegistryValue -Path $cloudContent -Name "DisableWindowsConsumerFeatures" -Value 1 -Kind DWord
        Set-AzVmRegistryValue -Path $cloudContent -Name "DisableConsumerAccountStateContent" -Value 1 -Kind DWord

        $widgetsPolicy = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Dsh'
        Set-AzVmRegistryValue -Path $widgetsPolicy -Name 'AllowNewsAndInterests' -Value 0 -Kind DWord

        $explorerPolicy = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Explorer'
        Set-AzVmRegistryValue -Path $explorerPolicy -Name 'DisableThumbsDBOnNetworkFolders' -Value 1 -Kind DWord
        Set-AzVmRegistryValue -Path $explorerPolicy -Name 'DisableThumbnailCache' -Value 1 -Kind DWord

        $systemRestoreRoot = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $systemPolicy = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
        Set-AzVmRegistryValue -Path $systemPolicy -Name "EnableFirstLogonAnimation" -Value 0 -Kind DWord

        $terminalServerRoot = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Terminal Server'
        $rdpTcpRoot = Join-Path $terminalServerRoot 'WinStations\RDP-Tcp'
        Set-AzVmRegistryValue -Path $terminalServerRoot -Name 'fDenyTSConnections' -Value 0 -Kind DWord
        Set-AzVmRegistryValue -Path $rdpTcpRoot -Name 'UserAuthentication' -Value 0 -Kind DWord
        Set-AzVmRegistryValue -Path $rdpTcpRoot -Name 'SecurityLayer' -Value 1 -Kind DWord
        Set-AzVmRegistryValue -Path $rdpTcpRoot -Name 'MinEncryptionLevel' -Value 2 -Kind DWord

        $className = "AzVmTextFile"
        $classRoot = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$className"
        Set-AzVmRegistryValue -Path $classRoot -Name "(default)" -Value "Co VM Text File" -Kind String
        $commandPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$className\shell\open\command"
        Set-AzVmRegistryValue -Path $commandPath -Name "(default)" -Value ("`"$notepadPath`" `"%1`"") -Kind String

        foreach ($ext in @($textExtensions)) {
            $extPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$ext"
            Set-AzVmRegistryValue -Path $extPath -Name "(default)" -Value $className -Kind String
        }

        Clear-DesktopEntries -DesktopPath (Join-Path $managerProfilePath 'Desktop')
        Disable-SystemRestoreAndDeleteShadows -DriveRoots $fixedDriveRoots
        Remove-KnownArtifactFiles -RootPaths $knownDesktopRoots
        Remove-SystemVolumeInformationBestEffort -DriveRoots $fixedDriveRoots

        powercfg.exe /hibernate on
        if ($LASTEXITCODE -ne 0) {
            throw ("powercfg /hibernate on failed with exit code {0}." -f $LASTEXITCODE)
        }

        $flyoutPath = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings'
        Set-AzVmRegistryValue -Path $flyoutPath -Name 'ShowHibernateOption' -Value 1 -Kind DWord
        Set-AzVmRegistryValue -Path $flyoutPath -Name 'ShowSleepOption' -Value 1 -Kind DWord

        Add-Detail 'ux-worker-user-registry-begin'
        $advanced = Join-Path $managerMainRoot 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Add-Detail ("ux-worker-explorer-advanced-begin:{0}" -f $advanced)
        Set-AzVmRegistryValue -Path $advanced -Name 'LaunchTo' -Value 1 -Kind DWord
        Set-AzVmRegistryValue -Path $advanced -Name 'Hidden' -Value 1 -Kind DWord
        Set-AzVmRegistryValue -Path $advanced -Name 'ShowSuperHidden' -Value 1 -Kind DWord
        Set-AzVmRegistryValue -Path $advanced -Name 'HideFileExt' -Value 0 -Kind DWord
        Set-AzVmRegistryValue -Path $advanced -Name 'ShowInfoTip' -Value 0 -Kind DWord
        Set-AzVmRegistryValue -Path $advanced -Name 'IconsOnly' -Value 1 -Kind DWord
        Set-AzVmRegistryValue -Path $advanced -Name 'AutoArrange' -Value 1 -Kind DWord
        Set-AzVmRegistryValue -Path $advanced -Name 'SnapToGrid' -Value 1 -Kind DWord
        Set-AzVmRegistryValue -Path $advanced -Name 'ShowTaskViewButton' -Value 0 -Kind DWord

        $searchPath = Join-Path $managerMainRoot 'Software\Microsoft\Windows\CurrentVersion\Search'
        Set-AzVmRegistryValue -Path $searchPath -Name 'SearchboxTaskbarMode' -Value 0 -Kind DWord

        $controlPanel = Join-Path $managerMainRoot 'Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel'
        Set-AzVmRegistryValue -Path $controlPanel -Name 'AllItemsIconView' -Value 1 -Kind DWord
        Set-AzVmRegistryValue -Path $controlPanel -Name 'StartupPage' -Value 1 -Kind DWord

        $operationStatus = Join-Path $managerMainRoot 'Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager'
        Set-AzVmRegistryValue -Path $operationStatus -Name 'EnthusiastMode' -Value 1 -Kind DWord

        $keyboard = Join-Path $managerMainRoot 'Control Panel\Keyboard'
        Set-AzVmRegistryValue -Path $keyboard -Name 'KeyboardDelay' -Value '0' -Kind String

        $desktopIconRoots = @(
            (Join-Path $managerMainRoot 'Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'),
            (Join-Path $managerMainRoot 'Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu')
        )
        foreach ($desktopIconRoot in @($desktopIconRoots)) {
            Set-AzVmRegistryValue -Path $desktopIconRoot -Name '{59031a47-3f72-44a7-89c5-5595fe6b30ee}' -Value 1 -Kind DWord
            Set-AzVmRegistryValue -Path $desktopIconRoot -Name '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' -Value 1 -Kind DWord
            Set-AzVmRegistryValue -Path $desktopIconRoot -Name '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}' -Value 1 -Kind DWord
            Set-AzVmRegistryValue -Path $desktopIconRoot -Name '{645FF040-5081-101B-9F08-00AA002F954E}' -Value 1 -Kind DWord
        }

        $currentUserShellRoot = Join-Path $managerClassesRoot 'Local Settings\Software\Microsoft\Windows\Shell'
        foreach ($staleNode in @('BagMRU', 'Bags')) {
            $stalePath = Join-Path $currentUserShellRoot $staleNode
            if (Test-Path -LiteralPath $stalePath) {
                Remove-Item -LiteralPath $stalePath -Recurse -Force -ErrorAction Stop
            }
        }

        $legacyDesktopBagsRoot = Join-Path $managerMainRoot 'Software\Microsoft\Windows\Shell\Bags'
        if (Test-Path -LiteralPath $legacyDesktopBagsRoot) {
            Remove-Item -LiteralPath $legacyDesktopBagsRoot -Recurse -Force -ErrorAction Stop
        }

        $allFoldersShell = Join-Path $managerClassesRoot 'Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell'
        Set-AzVmRegistryValue -Path $allFoldersShell -Name 'FolderType' -Value 'NotSpecified' -Kind String
        Set-AzVmRegistryValue -Path $allFoldersShell -Name 'LogicalViewMode' -Value 1 -Kind DWord
        Set-AzVmRegistryValue -Path $allFoldersShell -Name 'Mode' -Value 4 -Kind DWord
        Set-AzVmRegistryValue -Path $allFoldersShell -Name 'Sort' -Value 'prop:System.ItemNameDisplay' -Kind String
        Set-AzVmRegistryValue -Path $allFoldersShell -Name 'SortDirection' -Value 0 -Kind DWord
        Set-AzVmRegistryValue -Path $allFoldersShell -Name 'GroupView' -Value 0 -Kind DWord

        $bagOneShell = Join-Path $managerClassesRoot 'Local Settings\Software\Microsoft\Windows\Shell\Bags\1\Shell'
        Set-AzVmRegistryValue -Path $bagOneShell -Name 'FolderType' -Value 'NotSpecified' -Kind String
        Set-AzVmRegistryValue -Path $bagOneShell -Name 'LogicalViewMode' -Value 1 -Kind DWord
        Set-AzVmRegistryValue -Path $bagOneShell -Name 'Mode' -Value 4 -Kind DWord
        Set-AzVmRegistryValue -Path $bagOneShell -Name 'Sort' -Value 'prop:System.ItemNameDisplay' -Kind String
        Set-AzVmRegistryValue -Path $bagOneShell -Name 'SortDirection' -Value 0 -Kind DWord
        Set-AzVmRegistryValue -Path $bagOneShell -Name 'GroupView' -Value 0 -Kind DWord

        $desktopBag = Join-Path $managerMainRoot 'Software\Microsoft\Windows\Shell\Bags\1\Desktop'
        Set-AzVmRegistryValue -Path $desktopBag -Name 'IconSize' -Value 48 -Kind DWord
        Set-AzVmRegistryValue -Path $desktopBag -Name 'Sort' -Value 'prop:System.ItemNameDisplay' -Kind String
        Set-AzVmRegistryValue -Path $desktopBag -Name 'SortDirection' -Value 0 -Kind DWord
        Set-AzVmRegistryValue -Path $desktopBag -Name 'GroupView' -Value 0 -Kind DWord
        Set-AzVmRegistryValue -Path $desktopBag -Name 'FFlags' -Value 1075839525 -Kind DWord

        $contextMenuPath = Join-Path $managerClassesRoot 'CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
        Set-AzVmRegistryValue -Path $contextMenuPath -Name '(default)' -Value '' -Kind String

        Ensure-TaskManagerFullViewSetting -ProfilePath $managerProfilePath
        Restart-ExplorerShell
        Remove-KnownArtifactFiles -RootPaths $knownDesktopRoots

        Assert-RegistryValue -Path $tsPolicy -Name "fDisableWallpaper" -ExpectedValue 1
        Assert-RegistryValue -Path $cloudContent -Name "DisableWindowsConsumerFeatures" -ExpectedValue 1
        Assert-RegistryValue -Path $widgetsPolicy -Name 'AllowNewsAndInterests' -ExpectedValue 0
        Assert-RegistryValue -Path $explorerPolicy -Name 'DisableThumbsDBOnNetworkFolders' -ExpectedValue 1
        Assert-RegistryValue -Path $explorerPolicy -Name 'DisableThumbnailCache' -ExpectedValue 1
        Assert-RegistryValue -Path $systemRestoreRoot -Name 'DisableSR' -ExpectedValue 1
        Assert-RegistryValue -Path $systemPolicy -Name "EnableFirstLogonAnimation" -ExpectedValue 0
        Assert-RegistryValue -Path $terminalServerRoot -Name 'fDenyTSConnections' -ExpectedValue 0
        Assert-RegistryValue -Path $rdpTcpRoot -Name 'UserAuthentication' -ExpectedValue 0
        Assert-RegistryValue -Path $rdpTcpRoot -Name 'SecurityLayer' -ExpectedValue 1
        Assert-RegistryValue -Path $commandPath -Name "(default)" -ExpectedValue ("`"$notepadPath`" `"%1`"")
        Assert-RegistryValue -Path $flyoutPath -Name 'ShowHibernateOption' -ExpectedValue 1
        Assert-RegistryValue -Path $advanced -Name 'LaunchTo' -ExpectedValue 1
        Assert-RegistryValue -Path $advanced -Name 'HideFileExt' -ExpectedValue 0
        Assert-RegistryValue -Path $advanced -Name 'AutoArrange' -ExpectedValue 1
        Assert-RegistryValue -Path $advanced -Name 'SnapToGrid' -ExpectedValue 1
        Assert-RegistryValue -Path $advanced -Name 'ShowTaskViewButton' -ExpectedValue 0
        Assert-RegistryValue -Path $searchPath -Name 'SearchboxTaskbarMode' -ExpectedValue 0
        Assert-RegistryValue -Path $controlPanel -Name 'AllItemsIconView' -ExpectedValue 1
        Assert-RegistryValue -Path $controlPanel -Name 'StartupPage' -ExpectedValue 1
        Assert-RegistryValue -Path $operationStatus -Name 'EnthusiastMode' -ExpectedValue 1
        Assert-RegistryValue -Path $keyboard -Name 'KeyboardDelay' -ExpectedValue '0'
        Assert-RegistryValue -Path $allFoldersShell -Name 'FolderType' -ExpectedValue 'NotSpecified'
        Assert-RegistryValue -Path $allFoldersShell -Name 'Mode' -ExpectedValue 4
        Assert-RegistryValue -Path $allFoldersShell -Name 'LogicalViewMode' -ExpectedValue 1
        Assert-RegistryValue -Path $allFoldersShell -Name 'GroupView' -ExpectedValue 0
        Assert-RegistryValue -Path $bagOneShell -Name 'Mode' -ExpectedValue 4
        Assert-RegistryValue -Path $bagOneShell -Name 'LogicalViewMode' -ExpectedValue 1
        Assert-RegistryValue -Path $bagOneShell -Name 'GroupView' -ExpectedValue 0
        Assert-RegistryValue -Path $desktopBag -Name 'Sort' -ExpectedValue 'prop:System.ItemNameDisplay'
        Assert-RegistryValue -Path $desktopBag -Name 'SortDirection' -ExpectedValue 0
        Assert-RegistryValue -Path $desktopBag -Name 'GroupView' -ExpectedValue 0

        Add-Detail 'hibernate-option-visible'
        Add-Detail 'system-restore-disabled'
        Add-Detail 'rdp-nla-disabled'
        Add-Detail 'desktop-shell-icons-hidden'
        Add-Detail 'thumbnail-cache-disabled'
        Add-Detail 'explorer-group-none-default'
        Add-Detail 'explorer-details-view-default'
        Add-Detail 'desktop-sort-name-auto-arrange-grid'
        Add-Detail 'control-panel-small-icons'
        Add-Detail 'copy-dialog-show-more-details'
        Add-Detail 'task-manager-more-details'
        Add-Detail 'keyboard-repeat-delay-fastest'
        Add-Detail 'taskbar-search-hidden'
        Add-Detail 'taskbar-widgets-hidden'
        Add-Detail 'taskbar-task-view-hidden'
    }
    finally {
        if ($null -ne $managerRoots -and -not [string]::IsNullOrWhiteSpace([string]$managerRoots.ClassesMountName)) {
            Dismount-RegistryHive -MountName ([string]$managerRoots.ClassesMountName)
        }
    }
}

if ($WorkerMode) {
    try {
        Invoke-WindowsUxPerformanceTuning
        if (-not [string]::IsNullOrWhiteSpace([string]$ResultPath)) {
            Write-AzVmInteractiveResult -ResultPath $ResultPath -TaskName $TaskName -Success $true -Summary ('Windows UX tuning applied and validated for admin user {0}.' -f $managerUser) -Details @($details)
        }
    }
    catch {
        $message = [string]$_.Exception.Message
        Add-Detail ("ux-worker-error: {0}" -f $message)
        if (-not [string]::IsNullOrWhiteSpace([string]$ResultPath)) {
            Write-AzVmInteractiveResult -ResultPath $ResultPath -TaskName $TaskName -Success $false -Summary $message -Details @($details)
        }
        throw
    }

    return
}

$scriptPath = $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace([string]$scriptPath) -or -not (Test-Path -LiteralPath $scriptPath)) {
    throw "Current task script path could not be resolved for worker execution."
}

$paths = Get-AzVmInteractivePaths -TaskName $TaskName
$workerScript = @'
$scriptPath = '__SCRIPT_PATH__'
$resultPath = '__RESULT_PATH__'
$taskName = '__TASK_NAME__'
$powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powershellExe)) {
    throw ("powershell.exe was not found: {0}" -f $powershellExe)
}

& $powershellExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkerMode -ResultPath $resultPath -TaskName $taskName
exit $LASTEXITCODE
'@

$workerScript = $workerScript.Replace('__SCRIPT_PATH__', [string]$scriptPath)
$workerScript = $workerScript.Replace('__RESULT_PATH__', [string]$paths.ResultPath)
$workerScript = $workerScript.Replace('__TASK_NAME__', [string]$TaskName)

$null = Invoke-AzVmInteractiveDesktopAutomation `
    -TaskName $TaskName `
    -RunAsUser $managerUser `
    -RunAsPassword $managerPassword `
    -WorkerScriptText $workerScript `
    -WaitTimeoutSeconds 300

Write-Host "configure-ux-windows-completed"
Write-Host "Update task completed: configure-ux-windows"
