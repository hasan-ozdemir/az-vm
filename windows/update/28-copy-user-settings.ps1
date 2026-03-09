$ErrorActionPreference = "Stop"
Write-Host "Update task started: copy-user-settings"

$taskName = '28-copy-user-settings'
$managerUser = "__VM_ADMIN_USER__"
$managerPassword = "__VM_ADMIN_PASS__"
$assistantUser = "__ASSISTANT_USER__"
$assistantPassword = "__ASSISTANT_PASS__"
$helperPath = "C:\Windows\Temp\az-vm-interactive-session-helper.ps1"

if (-not (Test-Path -LiteralPath $helperPath)) {
    throw ("Interactive session helper was not found: {0}" -f $helperPath)
}

. $helperPath

function Write-Detail {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace([string]$Text)) {
        return
    }

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

function Ensure-LocalUserExists {
    param([string]$UserName)

    if ([string]::IsNullOrWhiteSpace([string]$UserName)) {
        throw "User name is empty."
    }

    $user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if ($null -eq $user) {
        throw ("Local user was not found: {0}" -f $UserName)
    }
}

function Get-LocalUserProfilePath {
    param([string]$UserName)

    $expectedPath = "C:\Users\$UserName"
    $profile = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' -ErrorAction SilentlyContinue | Where-Object {
        [string]::Equals([string]$_.ProfileImagePath, $expectedPath, [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1

    if ($null -eq $profile) {
        return ''
    }

    return [string]$profile.ProfileImagePath
}

function Wait-AzVmCondition {
    param(
        [scriptblock]$Condition,
        [int]$TimeoutSeconds = 30,
        [int]$PollMilliseconds = 500
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (& $Condition) {
            return $true
        }

        Start-Sleep -Milliseconds $PollMilliseconds
    }

    return $false
}

function Get-LoggedOnUserSessionIds {
    param([string]$UserName)

    if ([string]::IsNullOrWhiteSpace([string]$UserName)) {
        return @()
    }

    $sessionIds = @()
    $quserOutput = @()
    try {
        $quserOutput = @(cmd.exe /c quser 2>$null)
    }
    catch {
        return @()
    }
    foreach ($line in @($quserOutput)) {
        $text = [string]$line
        if ([string]::IsNullOrWhiteSpace([string]$text)) { continue }
        if ($text -match '^\s*USERNAME\b') { continue }

        $normalized = $text.TrimStart('>').Trim()
        $parts = @($normalized -split '\s+')
        if (@($parts).Count -lt 3) { continue }
        if (-not [string]::Equals([string]$parts[0], $UserName, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($parts[2] -match '^\d+$') {
            $sessionIds += [int]$parts[2]
        }
    }

    return @($sessionIds | Select-Object -Unique)
}

function Stop-LoggedOnUserSessions {
    param([string]$UserName)

    foreach ($sessionId in @(Get-LoggedOnUserSessionIds -UserName $UserName)) {
        try {
            & logoff $sessionId | Out-Null
            Write-Detail ("copy-user-settings-session-logoff: {0} => {1}" -f $UserName, $sessionId)
        }
        catch {
            Write-Detail ("copy-user-settings-session-logoff-skip: {0} => {1}" -f $sessionId, $_.Exception.Message)
        }
    }
}

function Stop-UserProcesses {
    param([string]$UserName)

    if ([string]::IsNullOrWhiteSpace([string]$UserName)) {
        return
    }

    $normalizedUser = $UserName.ToLowerInvariant()
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    foreach ($process in @($processes)) {
        try {
            $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwner -ErrorAction Stop
            if ($null -eq $owner -or [int]$owner.ReturnValue -ne 0) { continue }
            $ownerUser = [string]$owner.User
            if ([string]::IsNullOrWhiteSpace([string]$ownerUser)) { continue }
            if (-not [string]::Equals($ownerUser.ToLowerInvariant(), $normalizedUser, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
        }
        catch {
        }
    }
}

function Ensure-UserProfileMaterialized {
    param(
        [string]$UserName,
        [string]$UserPassword
    )

    Ensure-LocalUserExists -UserName $UserName

    $existingProfilePath = Get-LocalUserProfilePath -UserName $UserName
    if (-not [string]::IsNullOrWhiteSpace([string]$existingProfilePath) -and (Test-Path -LiteralPath $existingProfilePath)) {
        Write-Detail ("copy-user-settings-profile-ready: {0} => {1}" -f $UserName, $existingProfilePath)
        return [string]$existingProfilePath
    }

    $materializeTaskName = "{0}-materialize-{1}" -f $taskName, $UserName
    $paths = Get-AzVmInteractivePaths -TaskName $materializeTaskName
    $workerScript = @'
$ErrorActionPreference = "Stop"
$helperPath = "__HELPER_PATH__"
$resultPath = "__RESULT_PATH__"
$taskName = "__TASK_NAME__"

. $helperPath

$profilePath = [Environment]::GetFolderPath('UserProfile')
Ensure-AzVmDirectory -Path $profilePath
Ensure-AzVmDirectory -Path (Join-Path $profilePath 'Desktop')
Write-AzVmInteractiveResult -ResultPath $resultPath -TaskName $taskName -Success $true -Summary 'User profile materialized.' -Details @($profilePath)
'@

    $workerScript = $workerScript.Replace('__HELPER_PATH__', $helperPath)
    $workerScript = $workerScript.Replace('__RESULT_PATH__', [string]$paths.ResultPath)
    $workerScript = $workerScript.Replace('__TASK_NAME__', $materializeTaskName)

    $null = Invoke-AzVmInteractiveDesktopAutomation `
        -TaskName $materializeTaskName `
        -RunAsUser $UserName `
        -RunAsPassword $UserPassword `
        -WorkerScriptText $workerScript `
        -WaitTimeoutSeconds 180

    if (-not (Wait-AzVmCondition -Condition {
        $path = Get-LocalUserProfilePath -UserName $UserName
        return (-not [string]::IsNullOrWhiteSpace([string]$path) -and (Test-Path -LiteralPath $path))
    } -TimeoutSeconds 30)) {
        throw ("User profile could not be materialized: {0}" -f $UserName)
    }

    $profilePath = Get-LocalUserProfilePath -UserName $UserName
    Write-Detail ("copy-user-settings-profile-materialized: {0} => {1}" -f $UserName, $profilePath)
    return [string]$profilePath
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

    foreach ($attempt in 1..5) {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds 500

        & reg.exe unload ("HKU\{0}" -f $MountName) | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return
        }

        Start-Sleep -Seconds 2
    }

    throw ("reg unload failed for HKU\{0}" -f $MountName)
}

function Copy-RegistryBranchWithRegExe {
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        Write-Detail ("copy-user-settings-registry-skip: {0}" -f $Label)
        return
    }

    $sourceRegPath = Convert-AzVmRegistryProviderPathToRegExePath -Path $SourcePath
    $targetRegPath = Convert-AzVmRegistryProviderPathToRegExePath -Path $TargetPath
    & reg.exe copy $sourceRegPath $targetRegPath /s /f | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw ("reg copy failed for {0}: {1} -> {2}" -f $Label, $sourceRegPath, $targetRegPath)
    }

    Write-Detail ("copy-user-settings-registry-ok: {0}" -f $Label)
}

function Test-RegistryRelativePathExcluded {
    param(
        [string]$RelativePath,
        [string[]]$ExcludedPrefixes
    )

    $candidate = [string]$RelativePath
    if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
        return $false
    }

    $candidate = $candidate.Trim('\').ToLowerInvariant()
    foreach ($prefix in @($ExcludedPrefixes)) {
        $normalizedPrefix = [string]$prefix
        if ([string]::IsNullOrWhiteSpace([string]$normalizedPrefix)) { continue }
        $normalizedPrefix = $normalizedPrefix.Trim('\').ToLowerInvariant()
        if ($candidate -eq $normalizedPrefix -or $candidate.StartsWith($normalizedPrefix + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Copy-RegistryBranch {
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [string[]]$ExcludedPrefixes = @(),
        [string]$RelativePath = ''
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        return
    }

    if (Test-RegistryRelativePathExcluded -RelativePath $RelativePath -ExcludedPrefixes $ExcludedPrefixes) {
        Write-Detail ("copy-user-settings-registry-skip: {0}" -f $RelativePath)
        return
    }

    if (-not (Test-Path -LiteralPath $TargetPath)) {
        New-Item -Path $TargetPath -Force | Out-Null
    }

    $sourceKey = Get-Item -LiteralPath $SourcePath -ErrorAction Stop
    try {
        try {
            $defaultValue = $sourceKey.GetValue('', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $defaultKind = $sourceKey.GetValueKind('')
            if ($null -ne $defaultValue -or $defaultKind -ne [Microsoft.Win32.RegistryValueKind]::Unknown) {
                Set-AzVmRegistryValue -Path $TargetPath -Name '(default)' -Value $defaultValue -Kind $defaultKind
            }
        }
        catch {
        }

        foreach ($valueName in @($sourceKey.GetValueNames())) {
            try {
                $valueKind = $sourceKey.GetValueKind($valueName)
                if ($valueKind -eq [Microsoft.Win32.RegistryValueKind]::Unknown) {
                    continue
                }
                $valueData = $sourceKey.GetValue($valueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                Set-AzVmRegistryValue -Path $TargetPath -Name $valueName -Value $valueData -Kind $valueKind
            }
            catch {
                Write-Detail ("copy-user-settings-registry-value-skip: {0}\{1} => {2}" -f $SourcePath, $valueName, $_.Exception.Message)
            }
        }

        foreach ($child in @(Get-ChildItem -LiteralPath $SourcePath -ErrorAction SilentlyContinue)) {
            try {
                $childSourcePath = [string]$child.PSPath
                $childTargetPath = Join-Path $TargetPath $child.PSChildName
                $childRelativePath = if ([string]::IsNullOrWhiteSpace([string]$RelativePath)) {
                    [string]$child.PSChildName
                }
                else {
                    "{0}\{1}" -f $RelativePath.Trim('\'), [string]$child.PSChildName
                }

                Copy-RegistryBranch -SourcePath $childSourcePath -TargetPath $childTargetPath -ExcludedPrefixes $ExcludedPrefixes -RelativePath $childRelativePath
            }
            finally {
                if ($child -is [System.IDisposable]) {
                    $child.Dispose()
                }
            }
        }
    }
    finally {
        if ($sourceKey -is [System.IDisposable]) {
            $sourceKey.Dispose()
        }
    }
}

function Get-ExistingRobocopyPathList {
    param(
        [string]$BasePath,
        [string[]]$RelativePaths
    )

    $paths = @()
    foreach ($relativePath in @($RelativePaths)) {
        if ([string]::IsNullOrWhiteSpace([string]$relativePath)) { continue }
        $candidate = Join-Path $BasePath $relativePath
        $paths += [string]$candidate
    }

    return @($paths)
}

function Invoke-RobocopyBranch {
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [string[]]$ExcludedDirectories = @(),
        [string[]]$ExcludedFiles = @(),
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        Write-Detail ("copy-user-settings-file-skip: missing source => {0}" -f $SourcePath)
        return
    }

    Ensure-AzVmDirectory -Path $TargetPath
    $robocopyExe = Join-Path $env:WINDIR 'System32\robocopy.exe'
    if (-not (Test-Path -LiteralPath $robocopyExe)) {
        throw "robocopy.exe was not found."
    }

    $argumentList = @(
        $SourcePath,
        $TargetPath,
        '/E',
        '/COPY:DAT',
        '/DCOPY:DAT',
        '/MT:16',
        '/R:1',
        '/W:1',
        '/XJ',
        '/NFL',
        '/NDL',
        '/NJH',
        '/NJS',
        '/NP'
    )

    $xdList = @(Get-ExistingRobocopyPathList -BasePath $SourcePath -RelativePaths $ExcludedDirectories)
    if (@($xdList).Count -gt 0) {
        $argumentList += '/XD'
        $argumentList += @($xdList)
    }

    if (@($ExcludedFiles).Count -gt 0) {
        $argumentList += '/XF'
        $argumentList += @($ExcludedFiles)
    }

    & $robocopyExe @argumentList | Out-Null
    $exitCode = [int]$LASTEXITCODE
    if ($exitCode -gt 7) {
        throw ("robocopy failed for {0} with exit code {1}." -f $Label, $exitCode)
    }

    Write-Detail ("copy-user-settings-file-ok: {0}" -f $Label)
}

function Test-PathContentCopied {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    if ((Get-Item -LiteralPath $Path -ErrorAction Stop).PSIsContainer) {
        return (@(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue).Count -gt 0)
    }

    return $true
}

function Assert-ExcludedItemNotCopied {
    param(
        [string]$SourceProfilePath,
        [string]$TargetProfilePath,
        [string]$RelativePath
    )

    $sourcePath = Join-Path $SourceProfilePath $RelativePath
    $targetPath = Join-Path $TargetProfilePath $RelativePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        return
    }

    if (Test-PathContentCopied -Path $targetPath) {
        throw ("Excluded path was copied unexpectedly: {0}" -f $RelativePath)
    }
}

function Assert-TaskManagerSettingsCopied {
    param(
        [string]$SourceProfilePath,
        [string]$ProfilePath,
        [string]$Label
    )

    $sourceSettingsPath = Join-Path $SourceProfilePath 'AppData\Local\Microsoft\Windows\TaskManager\settings.json'
    $settingsPath = Join-Path $ProfilePath 'AppData\Local\Microsoft\Windows\TaskManager\settings.json'
    if (-not (Test-Path -LiteralPath $sourceSettingsPath)) {
        if (Test-Path -LiteralPath $settingsPath) {
            throw ("Task Manager settings were copied unexpectedly for {0}: source is absent but target exists." -f $Label)
        }

        Write-Detail ("copy-user-settings-task-manager-skip: source store missing => {0}" -f $Label)
        return
    }

    if (-not (Test-Path -LiteralPath $settingsPath)) {
        throw ("Task Manager settings were not copied for {0}: {1}" -f $Label, $settingsPath)
    }

    $raw = [string](Get-Content -LiteralPath $settingsPath -Raw -ErrorAction Stop)
    if ([string]::IsNullOrWhiteSpace([string]$raw) -or $raw -notmatch '"SmallView"\s*:\s*false') {
        throw ("Task Manager settings do not contain SmallView=false for {0}." -f $Label)
    }
}

function Invoke-RepresentativeRegistryCopy {
    param(
        [string]$MainTargetRoot,
        [string]$ClassesTargetRoot,
        [string]$Label
    )

    $mainBranches = @(
        'Control Panel',
        'Environment',
        'Keyboard Layout',
        'Software\local accessibility vendor',
        'Software\Microsoft\Notepad',
        'Software\Microsoft\Windows\CurrentVersion\Explorer',
        'Software\Microsoft\Windows\CurrentVersion\Search'
    )
    foreach ($branch in @($mainBranches)) {
        Copy-RegistryBranchWithRegExe -SourcePath (Join-Path 'Registry::HKEY_CURRENT_USER' $branch) -TargetPath (Join-Path $MainTargetRoot $branch) -Label ("{0}:{1}" -f $Label, $branch)
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$ClassesTargetRoot)) {
        $classesBranches = @(
            'Local Settings\Software\Microsoft\Windows\Shell',
            'CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
        )
        foreach ($branch in @($classesBranches)) {
            Copy-RegistryBranchWithRegExe -SourcePath (Join-Path 'Registry::HKEY_CURRENT_USER\Software\Classes' $branch) -TargetPath (Join-Path $ClassesTargetRoot $branch) -Label ("{0}:classes:{1}" -f $Label, $branch)
        }
    }
}

function Invoke-LogonScreenRegistryCopy {
    $defaultRoot = 'Registry::HKEY_USERS\.DEFAULT'

    $mainBranches = @(
        'Control Panel',
        'Environment',
        'Keyboard Layout',
        'Software\Microsoft\Windows\CurrentVersion\Explorer',
        'Software\Microsoft\Windows\CurrentVersion\Search'
    )
    foreach ($branch in @($mainBranches)) {
        Copy-RegistryBranchWithRegExe -SourcePath (Join-Path 'Registry::HKEY_CURRENT_USER' $branch) -TargetPath (Join-Path $defaultRoot $branch) -Label ("logon-screen:{0}" -f $branch)
    }
}

function Invoke-ProfileFileCopy {
    param(
        [string]$SourceProfilePath,
        [string]$TargetProfilePath,
        [string]$Label
    )

    Ensure-AzVmDirectory -Path $TargetProfilePath

    Invoke-RobocopyBranch -SourcePath (Join-Path $SourceProfilePath 'Desktop') -TargetPath (Join-Path $TargetProfilePath 'Desktop') -Label ($Label + ' desktop')
    Invoke-RobocopyBranch -SourcePath (Join-Path $SourceProfilePath 'AppData\Roaming') -TargetPath (Join-Path $TargetProfilePath 'AppData\Roaming') -Label ($Label + ' roaming') -ExcludedDirectories @(
        'Microsoft\Credentials',
        'Microsoft\Protect',
        'Microsoft\Vault',
        'Microsoft\IdentityCRL',
        'npm-cache'
    ) -ExcludedFiles @(
        'NTUSER.DAT*',
        'UsrClass.dat*',
        '*.log',
        '*.etl',
        '*.lock'
    )
    Invoke-RobocopyBranch -SourcePath (Join-Path $SourceProfilePath 'AppData\Local') -TargetPath (Join-Path $TargetProfilePath 'AppData\Local') -Label ($Label + ' local') -ExcludedDirectories @(
        'Temp',
        'Packages',
        'Programs',
        'Microsoft\Windows\INetCache',
        'Microsoft\Windows\WebCache',
        'Microsoft\Windows\CloudStore',
        'Microsoft\WindowsApps',
        'Microsoft\Credentials',
        'CrashDumps',
        'D3DSCache',
        'Google\Chrome\User Data\Default\Cache',
        'Google\Chrome\User Data\Default\Code Cache',
        'Google\Chrome\User Data\Default\GPUCache',
        'Google\Chrome\User Data\Default\Service Worker\CacheStorage',
        'Google\Chrome\User Data\ShaderCache',
        'npm-cache',
        'OneAuth',
        'IdentityCache',
        'ConnectedDevicesPlatform',
        'SquirrelTemp'
    ) -ExcludedFiles @(
        'NTUSER.DAT*',
        'UsrClass.dat*',
        '*.log',
        '*.etl',
        '*.lock'
    )
    if ([string]::Equals([string]$Label, 'default-profile', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Detail 'copy-user-settings-file-skip: default-profile locallow'
        return
    }

    Invoke-RobocopyBranch -SourcePath (Join-Path $SourceProfilePath 'AppData\LocalLow') -TargetPath (Join-Path $TargetProfilePath 'AppData\LocalLow') -Label ($Label + ' locallow') -ExcludedDirectories @(
        'Temp'
    ) -ExcludedFiles @(
        'NTUSER.DAT*',
        'UsrClass.dat*',
        '*.log',
        '*.etl',
        '*.lock'
    )
}

function Invoke-AssistantInteractiveSeed {
    param(
        [string]$UserName,
        [string]$UserPassword
    )

    $interactiveTaskName = "{0}-assistant-hkcu" -f $taskName
    $paths = Get-AzVmInteractivePaths -TaskName $interactiveTaskName
    $workerScript = @'
$ErrorActionPreference = "Stop"
$helperPath = "__HELPER_PATH__"
$resultPath = "__RESULT_PATH__"
$taskName = "__TASK_NAME__"

. $helperPath

$advanced = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-AzVmRegistryValue -Path $advanced -Name 'LaunchTo' -Value 1 -Kind DWord
Set-AzVmRegistryValue -Path $advanced -Name 'Hidden' -Value 1 -Kind DWord
Set-AzVmRegistryValue -Path $advanced -Name 'ShowSuperHidden' -Value 1 -Kind DWord
Set-AzVmRegistryValue -Path $advanced -Name 'HideFileExt' -Value 0 -Kind DWord
Set-AzVmRegistryValue -Path $advanced -Name 'ShowInfoTip' -Value 0 -Kind DWord
Set-AzVmRegistryValue -Path $advanced -Name 'IconsOnly' -Value 1 -Kind DWord
Set-AzVmRegistryValue -Path $advanced -Name 'AutoArrange' -Value 1 -Kind DWord
Set-AzVmRegistryValue -Path $advanced -Name 'SnapToGrid' -Value 1 -Kind DWord
Set-AzVmRegistryValue -Path $advanced -Name 'ShowTaskViewButton' -Value 0 -Kind DWord

$searchPath = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Search'
Set-AzVmRegistryValue -Path $searchPath -Name 'SearchboxTaskbarMode' -Value 0 -Kind DWord

$controlPanel = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel'
Set-AzVmRegistryValue -Path $controlPanel -Name 'AllItemsIconView' -Value 1 -Kind DWord
Set-AzVmRegistryValue -Path $controlPanel -Name 'StartupPage' -Value 1 -Kind DWord

$operationStatus = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager'
Set-AzVmRegistryValue -Path $operationStatus -Name 'EnthusiastMode' -Value 1 -Kind DWord

$keyboard = 'Registry::HKEY_CURRENT_USER\Control Panel\Keyboard'
Set-AzVmRegistryValue -Path $keyboard -Name 'KeyboardDelay' -Value '0' -Kind String

$allFoldersShell = 'Registry::HKEY_CURRENT_USER\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell'
Set-AzVmRegistryValue -Path $allFoldersShell -Name 'FolderType' -Value 'NotSpecified' -Kind String
Set-AzVmRegistryValue -Path $allFoldersShell -Name 'LogicalViewMode' -Value 1 -Kind DWord
Set-AzVmRegistryValue -Path $allFoldersShell -Name 'Mode' -Value 4 -Kind DWord
Set-AzVmRegistryValue -Path $allFoldersShell -Name 'Sort' -Value 'prop:System.ItemNameDisplay' -Kind String
Set-AzVmRegistryValue -Path $allFoldersShell -Name 'SortDirection' -Value 0 -Kind DWord
Set-AzVmRegistryValue -Path $allFoldersShell -Name 'GroupView' -Value 0 -Kind DWord

$contextMenuPath = 'Registry::HKEY_CURRENT_USER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
Set-AzVmRegistryValue -Path $contextMenuPath -Name '(default)' -Value '' -Kind String

if ([string](Get-ItemProperty -Path $advanced -Name 'ShowTaskViewButton' -ErrorAction Stop).ShowTaskViewButton -ne '0') {
    throw 'Assistant HKCU validation failed for ShowTaskViewButton.'
}
if ([string](Get-ItemProperty -Path $searchPath -Name 'SearchboxTaskbarMode' -ErrorAction Stop).SearchboxTaskbarMode -ne '0') {
    throw 'Assistant HKCU validation failed for SearchboxTaskbarMode.'
}
if ([string](Get-ItemProperty -Path $controlPanel -Name 'AllItemsIconView' -ErrorAction Stop).AllItemsIconView -ne '1') {
    throw 'Assistant HKCU validation failed for AllItemsIconView.'
}
if ([string](Get-ItemProperty -Path $keyboard -Name 'KeyboardDelay' -ErrorAction Stop).KeyboardDelay -ne '0') {
    throw 'Assistant HKCU validation failed for KeyboardDelay.'
}
if ([string](Get-ItemProperty -Path $allFoldersShell -Name 'GroupView' -ErrorAction Stop).GroupView -ne '0') {
    throw 'Assistant HKCU validation failed for GroupView.'
}

Write-AzVmInteractiveResult -ResultPath $resultPath -TaskName $taskName -Success $true -Summary 'Assistant HKCU settings seeded.' -Details @('assistant-hkcu-seeded')
'@

    $workerScript = $workerScript.Replace('__HELPER_PATH__', $helperPath)
    $workerScript = $workerScript.Replace('__RESULT_PATH__', [string]$paths.ResultPath)
    $workerScript = $workerScript.Replace('__TASK_NAME__', $interactiveTaskName)

    $null = Invoke-AzVmInteractiveDesktopAutomation `
        -TaskName $interactiveTaskName `
        -RunAsUser $UserName `
        -RunAsPassword $UserPassword `
        -WorkerScriptText $workerScript `
        -WaitTimeoutSeconds 180

    Write-Detail ("copy-user-settings-interactive-hkcu-ok: {0}" -f $UserName)
}

Ensure-LocalUserExists -UserName $managerUser
Ensure-LocalUserExists -UserName $assistantUser

$managerProfilePath = Get-LocalUserProfilePath -UserName $managerUser
if ([string]::IsNullOrWhiteSpace([string]$managerProfilePath) -or -not (Test-Path -LiteralPath $managerProfilePath)) {
    throw ("Manager profile path was not found: {0}" -f $managerUser)
}

$assistantProfilePath = Ensure-UserProfileMaterialized -UserName $assistantUser -UserPassword $assistantPassword
Stop-LoggedOnUserSessions -UserName $assistantUser
Stop-UserProcesses -UserName $assistantUser
Start-Sleep -Seconds 5
$defaultProfilePath = 'C:\Users\Default'
if (-not (Test-Path -LiteralPath $defaultProfilePath)) {
    throw ("Default user profile path was not found: {0}" -f $defaultProfilePath)
}

$defaultNtUserPath = Join-Path $defaultProfilePath 'NTUSER.DAT'

$defaultMainMountName = 'AzVmDefaultNtUser'

$defaultMainRoot = $null

try {
    $defaultMainRoot = Mount-RegistryHive -MountName $defaultMainMountName -HiveFilePath $defaultNtUserPath

    Invoke-RepresentativeRegistryCopy -MainTargetRoot $defaultMainRoot -ClassesTargetRoot '' -Label 'default-profile'
    Invoke-LogonScreenRegistryCopy

    Invoke-ProfileFileCopy -SourceProfilePath $managerProfilePath -TargetProfilePath $assistantProfilePath -Label 'assistant'
    Invoke-ProfileFileCopy -SourceProfilePath $managerProfilePath -TargetProfilePath $defaultProfilePath -Label 'default-profile'
    Invoke-AssistantInteractiveSeed -UserName $assistantUser -UserPassword $assistantPassword

    Assert-RegistryValue -Path (Join-Path $defaultMainRoot 'Control Panel\Keyboard') -Name 'KeyboardDelay' -ExpectedValue '0'
    Assert-RegistryValue -Path (Join-Path $defaultMainRoot 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced') -Name 'ShowTaskViewButton' -ExpectedValue 0
    Assert-RegistryValue -Path (Join-Path $defaultMainRoot 'Software\Microsoft\Windows\CurrentVersion\Search') -Name 'SearchboxTaskbarMode' -ExpectedValue 0

    Assert-RegistryValue -Path 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard' -Name 'KeyboardDelay' -ExpectedValue '0'
    Assert-RegistryValue -Path 'Registry::HKEY_USERS\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowTaskViewButton' -ExpectedValue 0
    Assert-RegistryValue -Path 'Registry::HKEY_USERS\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -ExpectedValue 0

    Assert-TaskManagerSettingsCopied -SourceProfilePath $managerProfilePath -ProfilePath $assistantProfilePath -Label 'assistant'
    Assert-TaskManagerSettingsCopied -SourceProfilePath $managerProfilePath -ProfilePath $defaultProfilePath -Label 'default-profile'
    Assert-ExcludedItemNotCopied -SourceProfilePath $managerProfilePath -TargetProfilePath $assistantProfilePath -RelativePath 'AppData\Local\Microsoft\Windows\WebCache\WebCacheV01.dat'
    Assert-ExcludedItemNotCopied -SourceProfilePath $managerProfilePath -TargetProfilePath $assistantProfilePath -RelativePath 'AppData\Roaming\Microsoft\Credentials'
    Assert-ExcludedItemNotCopied -SourceProfilePath $managerProfilePath -TargetProfilePath $defaultProfilePath -RelativePath 'AppData\Local\Microsoft\Windows\WebCache\WebCacheV01.dat'
    Assert-ExcludedItemNotCopied -SourceProfilePath $managerProfilePath -TargetProfilePath $defaultProfilePath -RelativePath 'AppData\Roaming\Microsoft\Credentials'
}
finally {
    foreach ($mountName in @($defaultMainMountName)) {
        if ([string]::IsNullOrWhiteSpace([string]$mountName)) {
            continue
        }

        try {
            Dismount-RegistryHive -MountName $mountName
        }
        catch {
            Write-Detail ("copy-user-settings-hive-unload-warning: {0}" -f $_.Exception.Message)
            throw
        }
    }
}

foreach ($mountName in @($defaultMainMountName)) {
    if (Test-Path -LiteralPath ("Registry::HKEY_USERS\{0}" -f $mountName)) {
        throw ("Registry hive mount remains loaded after cleanup: {0}" -f $mountName)
    }
}

Write-Detail 'copy-user-settings-registry-validated'
Write-Detail 'copy-user-settings-files-validated'
Write-Host "copy-user-settings-completed"
Write-Host "Update task completed: copy-user-settings"
