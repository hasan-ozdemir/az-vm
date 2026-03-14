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

$copySkipEvidence = New-Object 'System.Collections.Generic.List[object]'

function Write-Detail {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace([string]$Text)) {
        return
    }

    Write-Host ([string]$Text)
}

function Add-CopySkipEvidence {
    param(
        [string]$Reason,
        [string]$Label,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace([string]$Reason)) {
        return
    }

    $copySkipEvidence.Add([pscustomobject]@{
        Reason = [string]$Reason
        Label = [string]$Label
        Path = [string]$Path
    }) | Out-Null
}

function Write-CopySkipEvidenceSummary {
    $skipCount = 0
    if ($null -ne ([object]$copySkipEvidence)) {
        $skipCount = [int]$copySkipEvidence.Count
    }

    if ($skipCount -eq 0) {
        Write-Detail 'copy-settings-user-skip-summary: none'
        return
    }

    Write-Detail ("copy-settings-user-skip-summary: count={0}" -f $skipCount)
    foreach ($group in @($copySkipEvidence | Group-Object Reason | Sort-Object Name)) {
        Write-Detail ("copy-settings-user-skip-reason: {0} => {1}" -f [string]$group.Name, [int]$group.Count)
    }

    foreach ($entry in @($copySkipEvidence | Select-Object -First 20)) {
        Write-Detail ("copy-settings-user-skip-item: {0} => {1} => {2}" -f [string]$entry.Reason, [string]$entry.Label, [string]$entry.Path)
    }
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
            Add-CopySkipEvidence -Reason 'session-logoff-failed' -Label $UserName -Path ([string]$sessionId)
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
        Add-CopySkipEvidence -Reason 'missing-registry-source' -Label $Label -Path $SourcePath
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
        Add-CopySkipEvidence -Reason 'excluded-registry-branch' -Label $RelativePath -Path $SourcePath
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
                Add-CopySkipEvidence -Reason 'registry-value-skip' -Label $valueName -Path ("{0}\{1}" -f $SourcePath, $valueName)
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

function Write-ExistingCopyExclusions {
    param(
        [string]$SourcePath,
        [string[]]$ExcludedDirectories = @(),
        [string[]]$ExcludedFiles = @(),
        [string]$Label
    )

    foreach ($relativeDirectory in @($ExcludedDirectories)) {
        if ([string]::IsNullOrWhiteSpace([string]$relativeDirectory)) {
            continue
        }

        $candidate = Join-Path $SourcePath $relativeDirectory
        if (Test-Path -LiteralPath $candidate) {
            Add-CopySkipEvidence -Reason 'excluded-directory' -Label $Label -Path $candidate
            Write-Detail ("copy-settings-user-file-skip: {0} excluded-directory => {1}" -f $Label, $candidate)
        }
    }

    foreach ($excludedFile in @($ExcludedFiles)) {
        $excludedText = [string]$excludedFile
        if ([string]::IsNullOrWhiteSpace([string]$excludedText)) {
            continue
        }

        $candidate = if ($excludedText.Contains('\') -or $excludedText.Contains('/')) {
            Join-Path $SourcePath $excludedText
        }
        else {
            Join-Path $SourcePath $excludedText
        }

        if (Test-Path -LiteralPath $candidate) {
            Add-CopySkipEvidence -Reason 'excluded-file' -Label $Label -Path $candidate
            Write-Detail ("copy-settings-user-file-skip: {0} excluded-file => {1}" -f $Label, $candidate)
        }
    }
}

function Get-TargetPruneSkipReason {
    param([string]$Message)

    $text = [string]$Message
    if ([string]::IsNullOrWhiteSpace([string]$text)) {
        return ''
    }

    $normalized = $text.ToLowerInvariant()
    if ($normalized.Contains('being used by another process') -or $normalized.Contains('cannot access the file')) {
        return 'locked-target'
    }

    if ($normalized.Contains('access is denied') -or $normalized.Contains('error 5')) {
        return 'access-denied'
    }

    if ($normalized.Contains('reparse point')) {
        return 'reparse-point'
    }

    return ''
}

function Remove-StaleExcludedTargetPaths {
    param(
        [string]$TargetPath,
        [string[]]$ExcludedDirectories = @(),
        [string[]]$ExcludedFiles = @(),
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace([string]$TargetPath) -or -not (Test-Path -LiteralPath $TargetPath)) {
        return
    }

    foreach ($relativeDirectory in @($ExcludedDirectories)) {
        $relativeText = [string]$relativeDirectory
        if ([string]::IsNullOrWhiteSpace([string]$relativeText)) {
            continue
        }

        $targetCandidate = Join-Path $TargetPath $relativeText
        if (-not (Test-Path -LiteralPath $targetCandidate)) {
            continue
        }

        try {
            Remove-Item -LiteralPath $targetCandidate -Recurse -Force -ErrorAction Stop
            Add-CopySkipEvidence -Reason 'excluded-target-pruned' -Label $Label -Path $targetCandidate
            Write-Detail ("copy-settings-user-target-prune: {0} excluded-directory => {1}" -f $Label, $targetCandidate)
        }
        catch {
            $skipReason = Get-TargetPruneSkipReason -Message ([string]$_.Exception.Message)
            if (-not [string]::IsNullOrWhiteSpace([string]$skipReason)) {
                Add-CopySkipEvidence -Reason $skipReason -Label $Label -Path $targetCandidate
                Write-Detail ("copy-settings-user-target-prune-skip: {0} {1} => {2}" -f $Label, $skipReason, $targetCandidate)
                continue
            }

            throw ("Excluded target directory could not be cleared for {0}: {1}. {2}" -f $Label, $targetCandidate, $_.Exception.Message)
        }
    }

    foreach ($excludedFile in @($ExcludedFiles)) {
        $relativeText = [string]$excludedFile
        if ([string]::IsNullOrWhiteSpace([string]$relativeText)) {
            continue
        }

        $hasRelativeParent = ($relativeText.Contains('\') -or $relativeText.Contains('/'))
        $parentRelativePath = ''
        $leafPattern = $relativeText
        if ($hasRelativeParent) {
            $parentRelativePath = [string](Split-Path -Path $relativeText -Parent)
            $leafPattern = [string](Split-Path -Path $relativeText -Leaf)
        }

        if ([string]::IsNullOrWhiteSpace([string]$leafPattern)) {
            continue
        }

        $searchRoot = $TargetPath
        if (-not [string]::IsNullOrWhiteSpace([string]$parentRelativePath) -and $parentRelativePath -ne '.') {
            $searchRoot = Join-Path $TargetPath $parentRelativePath
        }

        if (-not (Test-Path -LiteralPath $searchRoot)) {
            continue
        }

        $matches = if ($hasRelativeParent) {
            @(Get-ChildItem -LiteralPath $searchRoot -Force -File -Filter $leafPattern -ErrorAction SilentlyContinue)
        }
        else {
            @(Get-ChildItem -LiteralPath $searchRoot -Force -File -Filter $leafPattern -Recurse -ErrorAction SilentlyContinue)
        }

        foreach ($targetCandidate in @($matches)) {
            if ($null -eq $targetCandidate -or [string]::IsNullOrWhiteSpace([string]$targetCandidate.FullName)) {
                continue
            }

            try {
                Remove-Item -LiteralPath ([string]$targetCandidate.FullName) -Force -ErrorAction Stop
                Add-CopySkipEvidence -Reason 'excluded-target-pruned' -Label $Label -Path ([string]$targetCandidate.FullName)
                Write-Detail ("copy-settings-user-target-prune: {0} excluded-file => {1}" -f $Label, ([string]$targetCandidate.FullName))
            }
            catch {
                $skipReason = Get-TargetPruneSkipReason -Message ([string]$_.Exception.Message)
                if (-not [string]::IsNullOrWhiteSpace([string]$skipReason)) {
                    Add-CopySkipEvidence -Reason $skipReason -Label $Label -Path ([string]$targetCandidate.FullName)
                    Write-Detail ("copy-settings-user-target-prune-skip: {0} {1} => {2}" -f $Label, $skipReason, ([string]$targetCandidate.FullName))
                    continue
                }

                throw ("Excluded target file could not be cleared for {0}: {1}. {2}" -f $Label, ([string]$targetCandidate.FullName), $_.Exception.Message)
            }
        }
    }
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
        Add-CopySkipEvidence -Reason 'missing-source' -Label $Label -Path $SourcePath
        Write-Detail ("copy-settings-user-file-skip: missing source => {0}" -f $SourcePath)
        return
    }

    Ensure-AzVmDirectory -Path $TargetPath
    $robocopyExe = Join-Path $env:WINDIR 'System32\robocopy.exe'
    if (-not (Test-Path -LiteralPath $robocopyExe)) {
        throw "robocopy.exe was not found."
    }

    Write-ExistingCopyExclusions -SourcePath $SourcePath -ExcludedDirectories $ExcludedDirectories -ExcludedFiles $ExcludedFiles -Label $Label
    Remove-StaleExcludedTargetPaths -TargetPath $TargetPath -ExcludedDirectories $ExcludedDirectories -ExcludedFiles $ExcludedFiles -Label $Label

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
            Add-CopySkipEvidence -Reason 'locked-file' -Label $Label -Path (Join-Path $SourcePath 'Microsoft\Windows\WebCacheLock.dat')
            Write-Detail ("copy-settings-user-file-skip: {0} locked WebCacheLock.dat" -f $Label)
            return
        }

        if ($exitCode -gt 7 -and ($normalizedDetail.Contains('access is denied') -or $normalizedDetail.Contains('error 5'))) {
            Write-Warning ("Ignoring access denied items while copying {0}; protected or session-owned files are skipped for profile safety." -f $Label)
            Add-CopySkipEvidence -Reason 'access-denied' -Label $Label -Path $SourcePath
            Write-Detail ("copy-settings-user-file-skip: {0} access-denied => {1}" -f $Label, $SourcePath)
            return
        }

        if ([string]::IsNullOrWhiteSpace([string]$detailText)) {
            throw ("robocopy failed for {0} with exit code {1}." -f $Label, $exitCode)
        }

        throw ("robocopy failed for {0} with exit code {1}. detail: {2}" -f $Label, $exitCode, $detailText)
    }

    Remove-StaleExcludedTargetPaths -TargetPath $TargetPath -ExcludedDirectories $ExcludedDirectories -ExcludedFiles $ExcludedFiles -Label $Label
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
        Add-CopySkipEvidence -Reason 'missing-source' -Label $Label -Path $sourcePath
        Write-Detail ("copy-settings-user-file-skip: missing source => {0}" -f $RelativePath)
        return
    }

    $targetPath = Join-Path $TargetProfilePath $RelativePath
    $sourceItem = Get-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
    $isSourceReparsePoint = (($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint)
    if ($isSourceReparsePoint) {
        Add-CopySkipEvidence -Reason 'reparse-point' -Label $Label -Path $sourcePath
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
    try {
        Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force -ErrorAction Stop
        Write-Detail ("copy-settings-user-file-ok: {0}" -f $Label)
    }
    catch {
        $message = [string]$_.Exception.Message
        $normalizedMessage = $message.ToLowerInvariant()
        if ($normalizedMessage.Contains('access to the path') -or $normalizedMessage.Contains('access is denied')) {
            Add-CopySkipEvidence -Reason 'access-denied' -Label $Label -Path $sourcePath
            Write-Warning ("Skipping access denied file while copying {0}: {1}" -f $Label, $sourcePath)
            Write-Detail ("copy-settings-user-file-skip: {0} access-denied => {1}" -f $Label, $RelativePath)
            return
        }

        if ($normalizedMessage.Contains('because it is being used by another process') -or $normalizedMessage.Contains('being used by another process')) {
            Add-CopySkipEvidence -Reason 'locked-file' -Label $Label -Path $sourcePath
            Write-Warning ("Skipping locked file while copying {0}: {1}" -f $Label, $sourcePath)
            Write-Detail ("copy-settings-user-file-skip: {0} locked-file => {1}" -f $Label, $RelativePath)
            return
        }

        throw
    }
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

            Add-CopySkipEvidence -Reason 'missing-task-manager-source' -Label $Label -Path $sourceSettingsPath
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

function New-ProfileCopySpec {
    param(
        [string]$RelativePath,
        [string]$LabelSuffix,
        [string[]]$ExcludedDirectories = @(),
        [string[]]$ExcludedFiles = @()
    )

    return [pscustomobject]@{
        RelativePath = [string]$RelativePath
        LabelSuffix = [string]$LabelSuffix
        ExcludedDirectories = @($ExcludedDirectories)
        ExcludedFiles = @($ExcludedFiles)
    }
}

function Add-ProfileCopySpecIfPresent {
    param(
        [System.Collections.Generic.List[object]]$Specs,
        [string]$SourceProfilePath,
        [string]$RelativePath,
        [string]$LabelSuffix,
        [string[]]$ExcludedDirectories = @(),
        [string[]]$ExcludedFiles = @()
    )

    if ($null -eq $Specs -or [string]::IsNullOrWhiteSpace([string]$RelativePath)) {
        return
    }

    $sourcePath = Join-Path $SourceProfilePath $RelativePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        return
    }

    $Specs.Add((New-ProfileCopySpec -RelativePath $RelativePath -LabelSuffix $LabelSuffix -ExcludedDirectories $ExcludedDirectories -ExcludedFiles $ExcludedFiles)) | Out-Null
}

function Get-ProfileCopySpecs {
    param(
        [string]$SourceProfilePath,
        [string]$TargetProfilePath,
        [string]$Label
    )

    $commonExcludedFiles = @(
        'desktop.ini',
        'Thumbs.db',
        'NTUSER.DAT*',
        'UsrClass.dat*',
        '*.log',
        '*.etl',
        '*.lock'
    )

    $specs = New-Object 'System.Collections.Generic.List[object]'

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
        Add-ProfileCopySpecIfPresent -Specs $specs -SourceProfilePath $SourceProfilePath -RelativePath $requiredRelativePath -LabelSuffix $requiredRelativePath
    }

    Add-ProfileCopySpecIfPresent -Specs $specs -SourceProfilePath $SourceProfilePath -RelativePath 'AppData\Local\Microsoft\Windows\TaskManager' -LabelSuffix 'task-manager' -ExcludedFiles @($commonExcludedFiles)

    foreach ($relativePath in @(
        'AppData\Local\Google\Chrome\User Data\Local State',
        'AppData\Local\Google\Chrome\User Data\Default\Preferences',
        'AppData\Local\Google\Chrome\User Data\Default\Secure Preferences',
        'AppData\Local\Google\Chrome\User Data\Default\Bookmarks'
    )) {
        $leafName = ([string]$relativePath).Split('\\')[-1].Replace(' ', '-').ToLowerInvariant()
        Add-ProfileCopySpecIfPresent -Specs $specs -SourceProfilePath $SourceProfilePath -RelativePath $relativePath -LabelSuffix ("chrome-{0}" -f $leafName) -ExcludedFiles @($commonExcludedFiles)
    }

    foreach ($relativePath in @(
        'AppData\Roaming\Code\User\settings.json',
        'AppData\Roaming\Code\User\keybindings.json',
        'AppData\Roaming\Code\User\tasks.json'
    )) {
        $labelSuffix = ([string]$relativePath).Substring(([string]'AppData\Roaming\Code\User\').Length).Replace('.json', '').Replace('\', '-').ToLowerInvariant()
        Add-ProfileCopySpecIfPresent -Specs $specs -SourceProfilePath $SourceProfilePath -RelativePath $relativePath -LabelSuffix ("vscode-{0}" -f $labelSuffix) -ExcludedFiles @($commonExcludedFiles)
    }

    Add-ProfileCopySpecIfPresent -Specs $specs -SourceProfilePath $SourceProfilePath -RelativePath 'AppData\Roaming\Code\User\snippets' -LabelSuffix 'vscode-snippets' -ExcludedFiles @($commonExcludedFiles)

    $targetNpmRoot = Join-Path $TargetProfilePath 'AppData\Roaming\npm'
    $targetNpmReady = (
        (Test-Path -LiteralPath (Join-Path $targetNpmRoot 'codex.cmd')) -and
        (Test-Path -LiteralPath (Join-Path $targetNpmRoot 'gemini.cmd')) -and
        (Test-Path -LiteralPath (Join-Path $targetNpmRoot 'copilot.cmd'))
    )
    if ([string]::Equals([string]$Label, 'default-profile', [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-CopySkipEvidence -Reason 'npm-copy-skip-default-profile' -Label $Label -Path (Join-Path $SourceProfilePath 'AppData\Roaming\npm')
        Write-Detail 'copy-settings-user-file-skip: default-profile roaming npm'
    }
    elseif ($targetNpmReady) {
        Add-CopySkipEvidence -Reason 'npm-already-synchronized' -Label $Label -Path $targetNpmRoot
        Write-Detail ("copy-settings-user-file-skip: {0} roaming npm already-synchronized" -f $Label)
    }
    else {
        Add-ProfileCopySpecIfPresent -Specs $specs -SourceProfilePath $SourceProfilePath -RelativePath 'AppData\Roaming\npm' -LabelSuffix 'npm' -ExcludedFiles @($commonExcludedFiles)
    }

    return @($specs.ToArray())
}

function Invoke-ExplicitExcludedTargetCleanup {
    param(
        [string]$TargetProfilePath,
        [string]$Label
    )

    Remove-StaleExcludedTargetPaths -TargetPath $TargetProfilePath -ExcludedDirectories @(
        'AppData\Roaming\Microsoft\Credentials',
        'AppData\Roaming\Microsoft\Protect',
        'AppData\Roaming\Microsoft\Vault',
        'AppData\Roaming\Microsoft\IdentityCRL'
    ) -ExcludedFiles @(
        'AppData\Local\Microsoft\Windows\WebCacheLock.dat',
        'AppData\Local\Microsoft\Windows\WebCache\WebCacheV01.dat'
    ) -Label ($Label + ' cleanup')

    $ollamaTargetRoot = Join-Path $TargetProfilePath 'AppData\Roaming\ollama app.exe'
    Remove-StaleExcludedTargetPaths -TargetPath $ollamaTargetRoot -ExcludedDirectories @(
        'EBWebView\Default\Network',
        'EBWebView\Default\Safe Browsing Network',
        'EBWebView\Default\Cache',
        'EBWebView\Default\Code Cache',
        'EBWebView\Default\GPUCache',
        'EBWebView\Default\Service Worker\CacheStorage',
        'EBWebView\Default\Service Worker\ScriptCache',
        'EBWebView\Default\DawnCache',
        'EBWebView\Default\GrShaderCache'
    ) -Label ($Label + ' cleanup ollama')
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
        Add-CopySkipEvidence -Reason 'missing-classes-hive' -Label $Label -Path $HiveFilePath
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
                Add-CopySkipEvidence -Reason 'missing-classes-registry-branch' -Label ("{0}:classes:{1}" -f $Label, $branch) -Path $sourceRegPath
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
                Add-CopySkipEvidence -Reason 'missing-main-registry-branch' -Label ("{0}:{1}" -f $Label, $branch) -Path $sourceRegPath
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

    $copySpecs = @(Get-ProfileCopySpecs -SourceProfilePath $SourceProfilePath -TargetProfilePath $TargetProfilePath -Label $Label)
    foreach ($copySpec in @($copySpecs)) {
        $relativePath = [string]$copySpec.RelativePath
        if ([string]::IsNullOrWhiteSpace([string]$relativePath)) {
            continue
        }

        $labelSuffix = [string]$copySpec.LabelSuffix
        $copyLabel = if ([string]::IsNullOrWhiteSpace([string]$labelSuffix)) {
            [string]$Label
        }
        else {
            "{0} {1}" -f $Label, $labelSuffix
        }

        Invoke-ProfileRelativeCopy -SourceProfilePath $SourceProfilePath -TargetProfilePath $TargetProfilePath -RelativePath $relativePath -Label $copyLabel -ExcludedDirectories @($copySpec.ExcludedDirectories) -ExcludedFiles @($copySpec.ExcludedFiles)
    }

    Invoke-ExplicitExcludedTargetCleanup -TargetProfilePath $TargetProfilePath -Label $Label
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
    Assert-ExcludedItemNotCopied -SourceProfilePath $managerProfilePath -TargetProfilePath $assistantProfilePath -RelativePath 'AppData\Roaming\ollama app.exe\EBWebView\Default\Cache'
    Assert-ExcludedItemNotCopied -SourceProfilePath $managerProfilePath -TargetProfilePath $assistantProfilePath -RelativePath 'AppData\Roaming\ollama app.exe\EBWebView\Default\Code Cache'
    Assert-ExcludedItemNotCopied -SourceProfilePath $managerProfilePath -TargetProfilePath $assistantProfilePath -RelativePath 'AppData\Roaming\ollama app.exe\EBWebView\Default\GPUCache'
    Assert-ExcludedItemNotCopied -SourceProfilePath $managerProfilePath -TargetProfilePath $defaultProfilePath -RelativePath 'AppData\Local\Microsoft\Windows\WebCache\WebCacheV01.dat'
    Assert-ExcludedItemNotCopied -SourceProfilePath $managerProfilePath -TargetProfilePath $defaultProfilePath -RelativePath 'AppData\Roaming\Microsoft\Credentials'
    Assert-ExcludedItemNotCopied -SourceProfilePath $managerProfilePath -TargetProfilePath $defaultProfilePath -RelativePath 'AppData\Roaming\ollama app.exe\EBWebView\Default\Cache'
    Assert-ExcludedItemNotCopied -SourceProfilePath $managerProfilePath -TargetProfilePath $defaultProfilePath -RelativePath 'AppData\Roaming\ollama app.exe\EBWebView\Default\Code Cache'
    Assert-ExcludedItemNotCopied -SourceProfilePath $managerProfilePath -TargetProfilePath $defaultProfilePath -RelativePath 'AppData\Roaming\ollama app.exe\EBWebView\Default\GPUCache'
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

Write-CopySkipEvidenceSummary
Write-Detail 'copy-settings-user-registry-validated'
Write-Detail 'copy-settings-user-files-validated'
Write-Host "copy-settings-user-completed"
Write-Host "Update task completed: copy-settings-user"
