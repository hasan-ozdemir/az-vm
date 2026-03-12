$ErrorActionPreference = "Stop"
Write-Host "Update task started: copy-settings-user"

$taskName = '10005-copy-settings-user'
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

function Invoke-RegQuiet {
    param(
        [string]$Verb,
        [string[]]$Arguments
    )

    $segments = @('reg', [string]$Verb)
    foreach ($argument in @($Arguments)) {
        $segments += ('"{0}"' -f [string]$argument)
    }

    $command = ((@($segments) -join ' ') + ' >nul 2>&1')
    cmd.exe /d /c $command | Out-Null
    return [int]$LASTEXITCODE
}

function Test-RegExeBranchExists {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace([string]$Path)) {
        return $false
    }

    return ((Invoke-RegQuiet -Verb 'query' -Arguments @($Path)) -eq 0)
}

function Assert-HiddenShellDesktopIcons {
    param(
        [string]$RootPath,
        [string]$Label
    )

    foreach ($desktopIconRoot in @(
        (Join-Path $RootPath 'Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'),
        (Join-Path $RootPath 'Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu')
    )) {
        Assert-RegistryValue -Path $desktopIconRoot -Name '{59031a47-3f72-44a7-89c5-5595fe6b30ee}' -ExpectedValue 1
        Assert-RegistryValue -Path $desktopIconRoot -Name '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' -ExpectedValue 1
        Assert-RegistryValue -Path $desktopIconRoot -Name '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}' -ExpectedValue 1
    }

    Write-Detail ("copy-settings-user-shell-icons-hidden: {0}" -f $Label)
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

function Clear-DesktopEntries {
    param([string]$DesktopPath)

    if ([string]::IsNullOrWhiteSpace([string]$DesktopPath) -or -not (Test-Path -LiteralPath $DesktopPath)) {
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

    Write-Detail ("copy-settings-user-desktop-cleared: {0}" -f $DesktopPath)
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
        [int]$PollMilliseconds = 250
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
            Write-Detail ("copy-settings-user-session-logoff: {0} => {1}" -f $UserName, $sessionId)
        }
        catch {
            Write-Detail ("copy-settings-user-session-logoff-skip: {0} => {1}" -f $sessionId, $_.Exception.Message)
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
        Write-Detail ("copy-settings-user-profile-ready: {0} => {1}" -f $UserName, $existingProfilePath)
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
    Write-Detail ("copy-settings-user-profile-materialized: {0} => {1}" -f $UserName, $profilePath)
    return [string]$profilePath
}

function Remove-RegistryMountIfPresent {
    param([string]$MountName)

    if ([string]::IsNullOrWhiteSpace([string]$MountName)) {
        return
    }

    $null = Invoke-RegQuiet -Verb 'unload' -Arguments @(("HKU\{0}" -f $MountName))
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
    $exitCode = Invoke-RegQuiet -Verb 'load' -Arguments @(("HKU\{0}" -f $MountName), $HiveFilePath)
    if ($exitCode -ne 0) {
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

    foreach ($attempt in 1..6) {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds 250

        $exitCode = Invoke-RegQuiet -Verb 'unload' -Arguments @(("HKU\{0}" -f $MountName))
        if ($exitCode -eq 0) {
            return
        }

        Start-Sleep -Milliseconds 500
    }

    $exitCode = Invoke-RegQuiet -Verb 'unload' -Arguments @(("HKU\{0}" -f $MountName))
    if ($exitCode -eq 0) {
        return
    }

    throw ("reg unload failed for HKU\{0} with exit code {1}" -f $MountName, $exitCode)
}

function Copy-RegistryBranchWithRegExe {
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        Write-Detail ("copy-settings-user-registry-skip: {0}" -f $Label)
        return
    }

    $sourceRegPath = Convert-AzVmRegistryProviderPathToRegExePath -Path $SourcePath
    $targetRegPath = Convert-AzVmRegistryProviderPathToRegExePath -Path $TargetPath
    & reg.exe copy $sourceRegPath $targetRegPath /s /f 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw ("reg copy failed for {0}: {1} -> {2}" -f $Label, $sourceRegPath, $targetRegPath)
    }

    Write-Detail ("copy-settings-user-registry-ok: {0}" -f $Label)
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
        Write-Detail ("copy-settings-user-registry-skip: {0}" -f $RelativePath)
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
                Write-Detail ("copy-settings-user-registry-value-skip: {0}\{1} => {2}" -f $SourcePath, $valueName, $_.Exception.Message)
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
        Write-Detail ("copy-settings-user-file-skip: missing source => {0}" -f $SourcePath)
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
        $xfList = @()
        foreach ($excludedFile in @($ExcludedFiles)) {
            $excludedText = [string]$excludedFile
            if ([string]::IsNullOrWhiteSpace([string]$excludedText)) {
                continue
            }

            if ($excludedText.Contains('\') -or $excludedText.Contains('/')) {
                $xfList += (Join-Path $SourcePath $excludedText)
            }
            else {
                $xfList += $excludedText
            }
        }

        $argumentList += '/XF'
        $argumentList += @($xfList)
    }

    $robocopyOutput = @(& $robocopyExe @argumentList 2>&1)
    $exitCode = [int]$LASTEXITCODE
    if ($exitCode -gt 7) {
        $detailLines = @(
            @($robocopyOutput) |
                ForEach-Object { [string]$_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                Select-Object -Last 25
        )
        $detailText = if (@($detailLines).Count -gt 0) {
            [string](($detailLines -join ' | ') -replace '\s+', ' ')
        }
        else {
            ''
        }

        $normalizedDetail = [string]$detailText
        $normalizedDetail = $normalizedDetail.ToLowerInvariant()
        if ($exitCode -gt 7 -and $normalizedDetail.Contains('webcachelock.dat') -and $normalizedDetail.Contains('error 32')) {
            Write-Warning ("Ignoring locked WebCacheLock.dat while copying {0}; the live WebCache lock file is not required for the replicated profile." -f $Label)
            Write-Detail ("copy-settings-user-file-skip: {0} locked WebCacheLock.dat" -f $Label)
            return
        }

        if ([string]::IsNullOrWhiteSpace([string]$detailText)) {
            throw ("robocopy failed for {0} with exit code {1}." -f $Label, $exitCode)
        }

        throw ("robocopy failed for {0} with exit code {1}. detail: {2}" -f $Label, $exitCode, $detailText)
    }

    Write-Detail ("copy-settings-user-file-ok: {0}" -f $Label)
}

function Invoke-ProfileRelativeCopy {
    param(
        [string]$SourceProfilePath,
        [string]$TargetProfilePath,
        [string]$RelativePath,
        [string]$Label,
        [string[]]$ExcludedDirectories = @(),
        [string[]]$ExcludedFiles = @()
    )

    if ([string]::IsNullOrWhiteSpace([string]$RelativePath)) {
        return
    }

    $sourcePath = Join-Path $SourceProfilePath $RelativePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        Write-Detail ("copy-settings-user-file-skip: missing source => {0}" -f $RelativePath)
        return
    }

    $targetPath = Join-Path $TargetProfilePath $RelativePath
    $sourceItem = Get-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
    $isSourceReparsePoint = (($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint)
    if ($isSourceReparsePoint) {
        Write-Detail ("copy-settings-user-file-skip: {0} source reparse-point => {1}" -f $Label, $RelativePath)
        return
    }

    if ($sourceItem.PSIsContainer) {
        Invoke-RobocopyBranch `
            -SourcePath $sourcePath `
            -TargetPath $targetPath `
            -ExcludedDirectories $ExcludedDirectories `
            -ExcludedFiles $ExcludedFiles `
            -Label $Label
        return
    }

    Ensure-AzVmDirectory -Path (Split-Path -Path $targetPath -Parent)
    Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force -ErrorAction Stop
    Write-Detail ("copy-settings-user-file-ok: {0}" -f $Label)
}

function Test-UserProcessesRunning {
    param([string]$UserName)

    if ([string]::IsNullOrWhiteSpace([string]$UserName)) {
        return $false
    }

    $normalizedUser = $UserName.ToLowerInvariant()
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        try {
            $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwner -ErrorAction Stop
            if ($null -eq $owner -or [int]$owner.ReturnValue -ne 0) { continue }
            $ownerUser = [string]$owner.User
            if ([string]::IsNullOrWhiteSpace([string]$ownerUser)) { continue }
            if ([string]::Equals($ownerUser.ToLowerInvariant(), $normalizedUser, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        catch {
        }
    }

    return $false
}

function Wait-UserSessionsAndProcessesToSettle {
    param(
        [string]$UserName,
        [int]$TimeoutSeconds = 8
    )

    $settled = Wait-AzVmCondition -Condition {
        (@(Get-LoggedOnUserSessionIds -UserName $UserName).Count -eq 0) -and
        (-not (Test-UserProcessesRunning -UserName $UserName))
    } -TimeoutSeconds $TimeoutSeconds -PollMilliseconds 250

    if ($settled) {
        Write-Detail ("copy-settings-user-user-settled: {0}" -f $UserName)
        return
    }

    Write-Warning ("Proceeding after the bounded user-settle wait expired for {0}; later copy steps will still validate the resulting state." -f $UserName)
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

function Assert-RequiredRelativePathCopied {
    param(
        [string]$SourceProfilePath,
        [string]$TargetProfilePath,
        [string]$RelativePath
    )

    $sourcePath = Join-Path $SourceProfilePath $RelativePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        return
    }

    $sourceItem = Get-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
    $isSourceReparsePoint = (($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint)
    if ($isSourceReparsePoint) {
        return
    }

    $targetPath = Join-Path $TargetProfilePath $RelativePath
    if (-not (Test-Path -LiteralPath $targetPath)) {
        throw ("Required path was not copied: {0}" -f $RelativePath)
    }

    if (-not $sourceItem.PSIsContainer) {
        return
    }

    $sourceHasContent = (@(Get-ChildItem -LiteralPath $sourcePath -Force -ErrorAction SilentlyContinue).Count -gt 0)
    if (-not $sourceHasContent) {
        return
    }

    if (-not (Test-PathContentCopied -Path $targetPath)) {
        throw ("Required path content was not copied: {0}" -f $RelativePath)
    }
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

        Write-Detail ("copy-settings-user-task-manager-skip: source store missing => {0}" -f $Label)
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

function Invoke-ClassesHiveRegCopy {
    param(
        [string]$HiveFilePath,
        [string]$MountName,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace([string]$HiveFilePath) -or -not (Test-Path -LiteralPath $HiveFilePath)) {
        Write-Detail ("copy-settings-user-classes-skip: {0}" -f $Label)
        return
    }

    $mountPath = "HKU\$MountName"
    & reg.exe load $mountPath $HiveFilePath 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw ("reg load failed for {0}: {1}" -f $Label, $HiveFilePath)
    }

    try {
        foreach ($branch in @(
            'Local Settings\Software\Microsoft\Windows\Shell',
            'CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
        )) {
            $sourceRegPath = "HKEY_CURRENT_USER\Software\Classes\{0}" -f $branch
            if (-not (Test-RegExeBranchExists -Path $sourceRegPath)) {
                Write-Detail ("copy-settings-user-registry-skip: {0}:classes:{1}" -f $Label, $branch)
                continue
            }

            & reg.exe copy $sourceRegPath ("{0}\{1}" -f $mountPath, $branch) /s /f 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw ("reg copy failed for {0}: {1}" -f $Label, $branch)
            }
        }

        $allFoldersQuery = @(& reg.exe query ("{0}\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell" -f $mountPath) /v GroupView 2>&1)
        if (($allFoldersQuery -join ' ') -notmatch '0x0\b') {
            throw ("Classes hive validation failed for {0}: AllFolders GroupView is not 0." -f $Label)
        }

        $bagOneQuery = @(& reg.exe query ("{0}\Local Settings\Software\Microsoft\Windows\Shell\Bags\1\Shell" -f $mountPath) /v GroupView 2>&1)
        if (($bagOneQuery -join ' ') -notmatch '0x0\b') {
            throw ("Classes hive validation failed for {0}: bag one GroupView is not 0." -f $Label)
        }

        Write-Detail ("copy-settings-user-classes-ok: {0}" -f $Label)
    }
    finally {
        & reg.exe unload $mountPath 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw ("reg unload failed for {0}: {1}" -f $Label, $mountPath)
        }
    }
}

function Invoke-MainHiveRegCopy {
    param(
        [string]$HiveFilePath,
        [string]$MountName,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace([string]$HiveFilePath) -or -not (Test-Path -LiteralPath $HiveFilePath)) {
        throw ("Main hive file was not found for {0}: {1}" -f $Label, $HiveFilePath)
    }

    $mountPath = "HKU\$MountName"
    & reg.exe load $mountPath $HiveFilePath 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw ("reg load failed for {0}: {1}" -f $Label, $HiveFilePath)
    }

    try {
        foreach ($branch in @(
            'Control Panel',
            'Environment',
            'Keyboard Layout',
            'Software\Microsoft\Notepad',
            'Software\Microsoft\Windows\CurrentVersion\Explorer',
            'Software\Microsoft\Windows\CurrentVersion\Search'
        )) {
            $sourceRegPath = "HKEY_CURRENT_USER\{0}" -f $branch
            if (-not (Test-RegExeBranchExists -Path $sourceRegPath)) {
                Write-Detail ("copy-settings-user-registry-skip: {0}:{1}" -f $Label, $branch)
                continue
            }

            & reg.exe copy $sourceRegPath ("{0}\{1}" -f $mountPath, $branch) /s /f 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw ("reg copy failed for {0}: {1}" -f $Label, $branch)
            }
        }

        $keyboardQuery = @(& reg.exe query ("{0}\Control Panel\Keyboard" -f $mountPath) /v KeyboardDelay 2>&1)
        if (($keyboardQuery -join ' ') -notmatch '\bKeyboardDelay\b.*\b0\b') {
            throw ("Main hive validation failed for {0}: KeyboardDelay is not 0." -f $Label)
        }

        $advancedQuery = @(& reg.exe query ("{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -f $mountPath) /v ShowTaskViewButton 2>&1)
        if (($advancedQuery -join ' ') -notmatch '0x0\b') {
            throw ("Main hive validation failed for {0}: ShowTaskViewButton is not 0." -f $Label)
        }

        $searchQuery = @(& reg.exe query ("{0}\Software\Microsoft\Windows\CurrentVersion\Search" -f $mountPath) /v SearchboxTaskbarMode 2>&1)
        if (($searchQuery -join ' ') -notmatch '0x0\b') {
            throw ("Main hive validation failed for {0}: SearchboxTaskbarMode is not 0." -f $Label)
        }

        foreach ($desktopIconQueryPath in @(
            ("{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel" -f $mountPath),
            ("{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu" -f $mountPath)
        )) {
            foreach ($desktopIconGuid in @(
                '{59031a47-3f72-44a7-89c5-5595fe6b30ee}',
                '{20D04FE0-3AEA-1069-A2D8-08002B30309D}',
                '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}'
            )) {
                $desktopIconQuery = @(& reg.exe query $desktopIconQueryPath /v $desktopIconGuid 2>&1)
                if (($desktopIconQuery -join ' ') -notmatch '0x1\b') {
                    throw ("Main hive validation failed for {0}: hidden desktop icon state missing for {1}." -f $Label, $desktopIconGuid)
                }
            }
        }

        Write-Detail ("copy-settings-user-main-hive-ok: {0}" -f $Label)
    }
    finally {
        & reg.exe unload $mountPath 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw ("reg unload failed for {0}: {1}" -f $Label, $mountPath)
        }
    }
}

function Get-LoadedUserHiveRoots {
    param([string]$UserName)

    Ensure-LocalUserExists -UserName $UserName
    $user = Get-LocalUser -Name $UserName -ErrorAction Stop
    $sid = [string]$user.SID
    $mainRoot = ''
    $classesRoot = ''

    if (-not [string]::IsNullOrWhiteSpace([string]$sid)) {
        $candidateMainRoot = "Registry::HKEY_USERS\$sid"
        if (Test-Path -LiteralPath $candidateMainRoot) {
            $mainRoot = $candidateMainRoot
        }

        $candidateClassesRoot = "Registry::HKEY_USERS\${sid}_Classes"
        if (Test-Path -LiteralPath $candidateClassesRoot) {
            $classesRoot = $candidateClassesRoot
        }
    }

    return [pscustomobject]@{
        Sid = [string]$sid
        MainRoot = [string]$mainRoot
        ClassesRoot = [string]$classesRoot
    }
}

function Invoke-ProfileFileCopy {
    param(
        [string]$SourceProfilePath,
        [string]$TargetProfilePath,
        [string]$Label
    )

    Ensure-AzVmDirectory -Path $TargetProfilePath
    $targetDesktopPath = Join-Path $TargetProfilePath 'Desktop'
    Ensure-AzVmDirectory -Path $targetDesktopPath
    Clear-DesktopEntries -DesktopPath $targetDesktopPath
    $roamingExcludedDirectories = @(
        'Microsoft\Credentials',
        'Microsoft\Protect',
        'Microsoft\Vault',
        'Microsoft\IdentityCRL',
        'ollama app.exe\EBWebView\Default\Network',
        'ollama app.exe\EBWebView\Default\Safe Browsing Network',
        'npm-cache'
    )

    $targetNpmRoot = Join-Path $TargetProfilePath 'AppData\Roaming\npm'
    $targetNpmReady = (
        (Test-Path -LiteralPath (Join-Path $targetNpmRoot 'codex.cmd')) -and
        (Test-Path -LiteralPath (Join-Path $targetNpmRoot 'gemini.cmd')) -and
        (Test-Path -LiteralPath (Join-Path $targetNpmRoot 'copilot.cmd'))
    )
    if ([string]::Equals([string]$Label, 'default-profile', [System.StringComparison]::OrdinalIgnoreCase)) {
        $roamingExcludedDirectories += 'npm'
        Write-Detail 'copy-settings-user-file-skip: default-profile roaming npm'
    }
    elseif ($targetNpmReady) {
        $roamingExcludedDirectories += 'npm'
        Write-Detail ("copy-settings-user-file-skip: {0} roaming npm already-synchronized" -f $Label)
    }

    Invoke-ProfileRelativeCopy -SourceProfilePath $SourceProfilePath -TargetProfilePath $TargetProfilePath -RelativePath 'AppData\Roaming' -Label ($Label + ' roaming') -ExcludedDirectories @($roamingExcludedDirectories) -ExcludedFiles @(
        'desktop.ini',
        'Thumbs.db',
        'Microsoft\Windows\WebCacheLock.dat',
        'NTUSER.DAT*',
        'UsrClass.dat*',
        '*.log',
        '*.etl',
        '*.lock'
    )
    Invoke-ProfileRelativeCopy -SourceProfilePath $SourceProfilePath -TargetProfilePath $TargetProfilePath -RelativePath 'AppData\Local' -Label ($Label + ' local') -ExcludedDirectories @(
        'Temp',
        'Packages',
        'Programs',
        'Microsoft\Windows\INetCache',
        'Microsoft\Windows\WebCache',
        'Microsoft\Windows\CloudStore',
        'Microsoft\WindowsApps',
        'Microsoft\Windows\Notifications',
        'Microsoft\Credentials',
        'CrashDumps',
        'D3DSCache',
        'Docker\run',
        'Google\Chrome\User Data\Default\Cache',
        'Google\Chrome\User Data\Default\Code Cache',
        'Google\Chrome\User Data\Default\GPUCache',
        'Google\Chrome\User Data\Default\Service Worker\CacheStorage',
        'Google\Chrome\User Data\ShaderCache',
        'docker-secrets-engine',
        'npm-cache',
        'OneAuth',
        'IdentityCache',
        'ConnectedDevicesPlatform',
        'SquirrelTemp'
    ) -ExcludedFiles @(
        'desktop.ini',
        'Thumbs.db',
        'Microsoft\Windows\WebCacheLock.dat',
        'NTUSER.DAT*',
        'UsrClass.dat*',
        '*.log',
        '*.etl',
        '*.lock'
    )

    $requiredRelativePaths = @(
        'Desktop',
        'Documents',
        'Favorites',
        'Videos',
        'Pictures',
        'Downloads',
        'Links',
        'Music'
    )

    foreach ($requiredRelativePath in @($requiredRelativePaths)) {
        Invoke-ProfileRelativeCopy -SourceProfilePath $SourceProfilePath -TargetProfilePath $TargetProfilePath -RelativePath $requiredRelativePath -Label ($Label + ' ' + $requiredRelativePath)
    }
}

function Invoke-AssistantInteractiveSeed {
    param(
        [string]$UserName,
        [string]$UserPassword,
        [string]$ProfilePath
    )

    if ([string]::IsNullOrWhiteSpace([string]$ProfilePath) -or -not (Test-Path -LiteralPath $ProfilePath)) {
        throw ("Assistant profile path was not found for hive seed: {0}" -f $ProfilePath)
    }

    $assistantNtUserPath = Join-Path $ProfilePath 'NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $assistantNtUserPath)) {
        throw ("Assistant NTUSER.DAT was not found: {0}" -f $assistantNtUserPath)
    }

    $assistantUsrClassPath = Join-Path $ProfilePath 'AppData\Local\Microsoft\Windows\UsrClass.dat'
    $loadedRoots = Get-LoadedUserHiveRoots -UserName $UserName
    if (-not [string]::IsNullOrWhiteSpace([string]$loadedRoots.MainRoot)) {
        Invoke-RepresentativeRegistryCopy -MainTargetRoot ([string]$loadedRoots.MainRoot) -ClassesTargetRoot ([string]$loadedRoots.ClassesRoot) -Label 'assistant-profile'
        Assert-RegistryValue -Path (Join-Path ([string]$loadedRoots.MainRoot) 'Control Panel\Keyboard') -Name 'KeyboardDelay' -ExpectedValue '0'
        Assert-RegistryValue -Path (Join-Path ([string]$loadedRoots.MainRoot) 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced') -Name 'ShowTaskViewButton' -ExpectedValue 0
        Assert-RegistryValue -Path (Join-Path ([string]$loadedRoots.MainRoot) 'Software\Microsoft\Windows\CurrentVersion\Search') -Name 'SearchboxTaskbarMode' -ExpectedValue 0
        Assert-HiddenShellDesktopIcons -RootPath ([string]$loadedRoots.MainRoot) -Label 'assistant-profile'
        if (-not [string]::IsNullOrWhiteSpace([string]$loadedRoots.ClassesRoot)) {
            Assert-RegistryValue -Path (Join-Path ([string]$loadedRoots.ClassesRoot) 'Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell') -Name 'GroupView' -ExpectedValue 0
            Assert-RegistryValue -Path (Join-Path ([string]$loadedRoots.ClassesRoot) 'Local Settings\Software\Microsoft\Windows\Shell\Bags\1\Shell') -Name 'GroupView' -ExpectedValue 0
        }
    }
    else {
        Invoke-MainHiveRegCopy -HiveFilePath $assistantNtUserPath -MountName 'AzVmAssistantNtUser' -Label 'assistant-profile'
        Invoke-ClassesHiveRegCopy -HiveFilePath $assistantUsrClassPath -MountName 'AzVmAssistantUsrClass' -Label 'assistant-profile'
    }
    Write-Detail ("copy-settings-user-interactive-hkcu-ok: {0}" -f $UserName)
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
Wait-UserSessionsAndProcessesToSettle -UserName $assistantUser -TimeoutSeconds 8
$defaultProfilePath = 'C:\Users\Default'
if (-not (Test-Path -LiteralPath $defaultProfilePath)) {
    throw ("Default user profile path was not found: {0}" -f $defaultProfilePath)
}

$defaultNtUserPath = Join-Path $defaultProfilePath 'NTUSER.DAT'

$defaultMainMountName = 'AzVmDefaultNtUser'

$defaultMainRoot = $null

try {
    Clear-DesktopEntries -DesktopPath (Join-Path $managerProfilePath 'Desktop')
    Clear-DesktopEntries -DesktopPath (Join-Path $assistantProfilePath 'Desktop')
    Clear-DesktopEntries -DesktopPath (Join-Path $defaultProfilePath 'Desktop')

    $defaultMainRoot = Mount-RegistryHive -MountName $defaultMainMountName -HiveFilePath $defaultNtUserPath

    Invoke-RepresentativeRegistryCopy -MainTargetRoot $defaultMainRoot -ClassesTargetRoot '' -Label 'default-profile'
    Invoke-LogonScreenRegistryCopy

    Invoke-ProfileFileCopy -SourceProfilePath $managerProfilePath -TargetProfilePath $assistantProfilePath -Label 'assistant'
    Invoke-ProfileFileCopy -SourceProfilePath $managerProfilePath -TargetProfilePath $defaultProfilePath -Label 'default-profile'
    Invoke-AssistantInteractiveSeed -UserName $assistantUser -UserPassword $assistantPassword -ProfilePath $assistantProfilePath

    Assert-RegistryValue -Path (Join-Path $defaultMainRoot 'Control Panel\Keyboard') -Name 'KeyboardDelay' -ExpectedValue '0'
    Assert-RegistryValue -Path (Join-Path $defaultMainRoot 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced') -Name 'ShowTaskViewButton' -ExpectedValue 0
    Assert-RegistryValue -Path (Join-Path $defaultMainRoot 'Software\Microsoft\Windows\CurrentVersion\Search') -Name 'SearchboxTaskbarMode' -ExpectedValue 0
    Assert-HiddenShellDesktopIcons -RootPath $defaultMainRoot -Label 'default-profile'

    Assert-RegistryValue -Path 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard' -Name 'KeyboardDelay' -ExpectedValue '0'
    Assert-RegistryValue -Path 'Registry::HKEY_USERS\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowTaskViewButton' -ExpectedValue 0
    Assert-RegistryValue -Path 'Registry::HKEY_USERS\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -ExpectedValue 0
    Assert-HiddenShellDesktopIcons -RootPath 'Registry::HKEY_USERS\.DEFAULT' -Label 'logon-screen'

    Assert-TaskManagerSettingsCopied -SourceProfilePath $managerProfilePath -ProfilePath $assistantProfilePath -Label 'assistant'
    Assert-TaskManagerSettingsCopied -SourceProfilePath $managerProfilePath -ProfilePath $defaultProfilePath -Label 'default-profile'
    foreach ($requiredRelativePath in @(
        'Desktop',
        'Documents',
        'Favorites',
        'Videos',
        'Pictures',
        'Downloads',
        'Links',
        'Music'
    )) {
        Assert-RequiredRelativePathCopied -SourceProfilePath $managerProfilePath -TargetProfilePath $assistantProfilePath -RelativePath $requiredRelativePath
        Assert-RequiredRelativePathCopied -SourceProfilePath $managerProfilePath -TargetProfilePath $defaultProfilePath -RelativePath $requiredRelativePath
    }
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
            Write-Detail ("copy-settings-user-hive-unload-warning: {0}" -f $_.Exception.Message)
            throw
        }
    }
}

foreach ($mountName in @($defaultMainMountName)) {
    if (Test-Path -LiteralPath ("Registry::HKEY_USERS\{0}" -f $mountName)) {
        throw ("Registry hive mount remains loaded after cleanup: {0}" -f $mountName)
    }
}

Write-Detail 'copy-settings-user-registry-validated'
Write-Detail 'copy-settings-user-files-validated'
Write-Host "copy-settings-user-completed"
Write-Host "Update task completed: copy-settings-user"
