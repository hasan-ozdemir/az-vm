$ErrorActionPreference = 'Stop'

function Ensure-AzVmAppStateDirectory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace([string]$Path)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Wait-AzVmAppStateZipReady {
    param(
        [string]$ZipPath,
        [int]$TimeoutSeconds = 60
    )

    if ([string]::IsNullOrWhiteSpace([string]$ZipPath) -or -not (Test-Path -LiteralPath $ZipPath)) {
        throw ("Task app-state zip was not found on guest: {0}" -f [string]$ZipPath)
    }

    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max($TimeoutSeconds, 5))
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $stream = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            try {
                return [int64]$stream.Length
            }
            finally {
                if ($null -ne $stream) { $stream.Dispose() }
            }
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    }

    throw ("App-state zip stayed busy after upload: {0}" -f [string]$ZipPath)
}

function Get-AzVmAppStateManifestFromExpandedRoot {
    param(
        [string]$ExpandedRoot,
        [string]$TaskName
    )

    $manifestPath = Join-Path $ExpandedRoot 'app-state.manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw ("App-state manifest was not found in expanded payload: {0}" -f $manifestPath)
    }

    $manifestText = [string](Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop)
    if ([string]::IsNullOrWhiteSpace([string]$manifestText)) {
        throw ("App-state manifest is empty: {0}" -f $manifestPath)
    }

    $manifest = ConvertFrom-Json -InputObject $manifestText -ErrorAction Stop
    $resolvedTaskName = ''
    if ($manifest.PSObject.Properties.Match('taskName').Count -gt 0) {
        $resolvedTaskName = [string]$manifest.taskName
    }
    if (-not [string]::Equals([string]$resolvedTaskName, [string]$TaskName, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("App-state manifest taskName '{0}' does not match task '{1}'." -f [string]$resolvedTaskName, [string]$TaskName)
    }

    return $manifest
}

function Get-AzVmAppStateProfileTargets {
    param(
        [string]$ManagerUser,
        [string]$AssistantUser
    )

    function Convert-AzVmAppStateUserNameToProfileLeaf {
        param([string]$Value)

        $text = if ($null -eq $Value) { '' } else { [string]$Value.Trim() }
        if ([string]::IsNullOrWhiteSpace([string]$text)) {
            return ''
        }

        if ($text.Contains('\')) {
            $parts = @($text -split '\\')
            $text = [string]$parts[$parts.Count - 1]
        }
        if ($text.Contains('/')) {
            $parts = @($text -split '/')
            $text = [string]$parts[$parts.Count - 1]
        }

        return [string]$text.Trim()
    }

    $rows = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $managerProfileLeaf = Convert-AzVmAppStateUserNameToProfileLeaf -Value $ManagerUser
    $assistantProfileLeaf = Convert-AzVmAppStateUserNameToProfileLeaf -Value $AssistantUser

    foreach ($row in @(
        @{ Label = 'manager'; UserName = [string]$managerProfileLeaf; Path = ('C:\Users\{0}' -f [string]$managerProfileLeaf) },
        @{ Label = 'assistant'; UserName = [string]$assistantProfileLeaf; Path = ('C:\Users\{0}' -f [string]$assistantProfileLeaf) }
    )) {
        $profilePath = [string]$row.Path
        if ([string]::IsNullOrWhiteSpace([string]$profilePath) -or -not (Test-Path -LiteralPath $profilePath)) {
            continue
        }

        $normalizedPath = $profilePath.TrimEnd('\').ToLowerInvariant()
        if ($seen.ContainsKey($normalizedPath)) {
            continue
        }

        $rows.Add([pscustomobject]@{
            Label = [string]$row.Label
            UserName = [string]$row.UserName
            ProfilePath = [string]$profilePath
        }) | Out-Null
        $seen[$normalizedPath] = $true
    }

    return @($rows.ToArray())
}

function Get-AzVmAppStateEntryTargetProfiles {
    param([AllowNull()]$Entry)

    if ($null -eq $Entry -or $Entry.PSObject.Properties.Match('targetProfiles').Count -lt 1) {
        return @()
    }

    return @(
        @($Entry.targetProfiles) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { $_.Trim().ToLowerInvariant() } |
            Select-Object -Unique
    )
}

function Get-AzVmAppStateSelectedProfileTargets {
    param(
        [object[]]$ProfileTargets,
        [AllowNull()]$Entry
    )

    $targetProfiles = @(Get-AzVmAppStateEntryTargetProfiles -Entry $Entry)
    if (@($targetProfiles).Count -lt 1) {
        return @($ProfileTargets)
    }

    return @(
        @($ProfileTargets) | Where-Object {
            $label = if ($_.PSObject.Properties.Match('Label').Count -gt 0) { [string]$_.Label } else { '' }
            $userName = if ($_.PSObject.Properties.Match('UserName').Count -gt 0) { [string]$_.UserName } else { '' }
            $normalizedValues = @($label, $userName) |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                ForEach-Object { $_.Trim().ToLowerInvariant() }
            foreach ($value in @($normalizedValues)) {
                if (@($targetProfiles) -contains $value) {
                    return $true
                }
            }
            return $false
        }
    )
}

function Invoke-AzVmRegImport {
    param([string]$SourcePath)

    if ([string]::IsNullOrWhiteSpace([string]$SourcePath) -or -not (Test-Path -LiteralPath $SourcePath)) {
        return $false
    }

    cmd.exe /d /c ('reg import "{0}" >nul 2>&1' -f $SourcePath) | Out-Null
    return ([int]$LASTEXITCODE -eq 0)
}

function Get-AzVmMountedUserHive {
    param(
        [string]$ProfilePath,
        [string]$PreferredLabel
    )

    if ([string]::IsNullOrWhiteSpace([string]$ProfilePath)) {
        return $null
    }

    $normalizedProfilePath = [string]$ProfilePath.TrimEnd('\')
    try {
        $profile = @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object {
            [string]::Equals(([string]$_.LocalPath).TrimEnd('\'), $normalizedProfilePath, [System.StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if (@($profile).Count -gt 0) {
            $entry = $profile[0]
            if ($entry.PSObject.Properties.Match('Loaded').Count -gt 0 -and [bool]$entry.Loaded -and $entry.PSObject.Properties.Match('SID').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$entry.SID)) {
                return [pscustomobject]@{
                    Root = ('HKEY_USERS\{0}' -f [string]$entry.SID)
                    Temporary = $false
                    MountName = [string]$entry.SID
                }
            }
        }
    }
    catch {
    }

    $ntUserDatPath = Join-Path $ProfilePath 'NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $ntUserDatPath)) {
        return $null
    }

    $sanitized = (($PreferredLabel -replace '[^A-Za-z0-9]', '_')).Trim('_')
    if ([string]::IsNullOrWhiteSpace([string]$sanitized)) {
        $sanitized = 'user'
    }

    $mountName = ('AZVM_APPSTATE_{0}' -f $sanitized)
    cmd.exe /d /c ('reg load "HKU\{0}" "{1}" >nul 2>&1' -f $mountName, $ntUserDatPath) | Out-Null
    if ([int]$LASTEXITCODE -ne 0) {
        return $null
    }

    return [pscustomobject]@{
        Root = ('HKEY_USERS\{0}' -f $mountName)
        Temporary = $true
        MountName = [string]$mountName
    }
}

function Close-AzVmMountedUserHive {
    param([AllowNull()]$MountInfo)

    if ($null -eq $MountInfo) {
        return
    }

    if (-not $MountInfo.PSObject.Properties.Match('Temporary').Count -or -not [bool]$MountInfo.Temporary) {
        return
    }

    $mountName = [string]$MountInfo.MountName
    if ([string]::IsNullOrWhiteSpace([string]$mountName)) {
        return
    }

    cmd.exe /d /c ('reg unload "HKU\{0}" >nul 2>&1' -f $mountName) | Out-Null
}

function Convert-AzVmAppStateRegRoot {
    param(
        [string]$SourcePath,
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string]$DestinationPath
    )

    $content = [string](Get-Content -LiteralPath $SourcePath -Raw -Encoding Unicode -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace([string]$content)) {
        $content = [string](Get-Content -LiteralPath $SourcePath -Raw -ErrorAction SilentlyContinue)
    }
    if ([string]::IsNullOrWhiteSpace([string]$content)) {
        return $false
    }

    $escapedSourceRoot = [regex]::Escape([string]$SourceRoot)
    $rewritten = [regex]::Replace(
        $content,
        ('(?im)^\[(\-?){0}(?=\\|])' -f $escapedSourceRoot),
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            return ('[{0}{1}' -f [string]$match.Groups[1].Value, [string]$DestinationRoot)
        })

    Ensure-AzVmAppStateDirectory -Path (Split-Path -Path $DestinationPath -Parent)
    Set-Content -LiteralPath $DestinationPath -Value $rewritten -Encoding Unicode
    return $true
}

function Convert-AzVmAppStateRegistryPathToCanonicalRoot {
    param([string]$RegistryPath)

    if ([string]::IsNullOrWhiteSpace([string]$RegistryPath)) {
        return ''
    }

    $trimmed = ([string]$RegistryPath).Trim()
    $trimmed = $trimmed -replace '^HKCU\\', 'HKEY_CURRENT_USER\'
    $trimmed = $trimmed -replace '^HKLM\\', 'HKEY_LOCAL_MACHINE\'
    $trimmed = $trimmed -replace '^HKCR\\', 'HKEY_CLASSES_ROOT\'
    $trimmed = $trimmed -replace '^HKU\\', 'HKEY_USERS\'
    return [string]$trimmed
}

function Convert-AzVmAppStateRegistryPathToProviderPath {
    param([string]$RegistryPath)

    if ([string]::IsNullOrWhiteSpace([string]$RegistryPath)) {
        return ''
    }

    $trimmed = Convert-AzVmAppStateRegistryPathToCanonicalRoot -RegistryPath $RegistryPath
    if ([string]::IsNullOrWhiteSpace([string]$trimmed)) {
        return ''
    }

    return ('Registry::{0}' -f $trimmed)
}

function Invoke-AzVmAppStateWslRegistryPurge {
    param(
        [string]$MountedUserRegistryRoot,
        [string]$RegistryPath,
        [string[]]$DistributionAllowList = @()
    )

    $normalizedAllowList = @(
        @($DistributionAllowList) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { $_.Trim().ToLowerInvariant() } |
            Select-Object -Unique
    )
    if (@($normalizedAllowList).Count -lt 1) {
        return
    }

    $normalizedRegistryPath = ([string]$RegistryPath).Trim()
    if (-not $normalizedRegistryPath.StartsWith('HKCU\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    $relativeRegistryPath = $normalizedRegistryPath.Substring(5)
    $providerRoot = Convert-AzVmAppStateRegistryPathToProviderPath -RegistryPath ('{0}\{1}' -f $MountedUserRegistryRoot, $relativeRegistryPath)
    if ([string]::IsNullOrWhiteSpace([string]$providerRoot) -or -not (Test-Path -LiteralPath $providerRoot)) {
        return
    }

    foreach ($childKey in @(Get-ChildItem -LiteralPath $providerRoot -ErrorAction SilentlyContinue | Sort-Object PSChildName)) {
        $distributionName = ''
        try {
            $distributionName = [string](Get-ItemPropertyValue -LiteralPath $childKey.PSPath -Name 'DistributionName' -ErrorAction Stop)
        }
        catch {
            continue
        }

        if ([string]::IsNullOrWhiteSpace([string]$distributionName)) {
            continue
        }

        if (@($normalizedAllowList) -contains $distributionName.Trim().ToLowerInvariant()) {
            continue
        }

        Remove-Item -LiteralPath $childKey.PSPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Copy-AzVmAppStateFile {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    Ensure-AzVmAppStateDirectory -Path (Split-Path -Path $DestinationPath -Parent)
    try {
        Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force -ErrorAction Stop
        return $true
    }
    catch {
        Write-Host ("app-state-file-copy-skip => source={0}; destination={1}; reason={2}" -f [string]$SourcePath, [string]$DestinationPath, $_.Exception.Message)
        return $false
    }
}

function Copy-AzVmAppStateDirectoryContents {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    Ensure-AzVmAppStateDirectory -Path $DestinationPath
    $copiedAny = $false
    foreach ($item in @(Get-ChildItem -LiteralPath $SourcePath -Force -ErrorAction SilentlyContinue)) {
        try {
            Copy-Item -LiteralPath $item.FullName -Destination $DestinationPath -Recurse -Force -ErrorAction Stop
            $copiedAny = $true
        }
        catch {
            Write-Host ("app-state-directory-copy-skip => source={0}; destination={1}; reason={2}" -f [string]$item.FullName, [string]$DestinationPath, $_.Exception.Message)
        }
    }

    return $copiedAny
}

function Invoke-AzVmRegExport {
    param(
        [string]$RegistryPath,
        [string]$DestinationPath
    )

    if ([string]::IsNullOrWhiteSpace([string]$RegistryPath) -or [string]::IsNullOrWhiteSpace([string]$DestinationPath)) {
        return $false
    }

    Ensure-AzVmAppStateDirectory -Path (Split-Path -Path $DestinationPath -Parent)
    cmd.exe /d /c ('reg export "{0}" "{1}" /y >nul 2>&1' -f $RegistryPath, $DestinationPath) | Out-Null
    return ([int]$LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $DestinationPath))
}

function ConvertTo-AzVmAppStateCaptureSafeName {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return 'item'
    }

    return (([string]$Value -replace '^[A-Za-z]:', '') -replace '[\\/:*?"<>| ]', '_').Trim('_')
}

function Test-AzVmAppStateCaptureExcludedItem {
    param(
        [string]$SourcePath,
        [string[]]$ExcludeNames = @(),
        [string[]]$ExcludePathPatterns = @(),
        [string[]]$ExcludeFilePatterns = @()
    )

    $leafName = [System.IO.Path]::GetFileName([string]$SourcePath)
    foreach ($excludeName in @($ExcludeNames)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$excludeName) -and [string]::Equals([string]$leafName, [string]$excludeName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    foreach ($pathPattern in @($ExcludePathPatterns)) {
        if ([string]::IsNullOrWhiteSpace([string]$pathPattern)) { continue }
        if ([string]$SourcePath -like [string]$pathPattern) {
            return $true
        }
    }

    if (Test-Path -LiteralPath $SourcePath -PathType Leaf) {
        foreach ($filePattern in @($ExcludeFilePatterns)) {
            if ([string]::IsNullOrWhiteSpace([string]$filePattern)) { continue }
            if ([string]$leafName -like [string]$filePattern) {
                return $true
            }
        }
    }

    return $false
}

function Copy-AzVmAppStateCaptureTree {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [string[]]$ExcludeNames = @(),
        [string[]]$ExcludePathPatterns = @(),
        [string[]]$ExcludeFilePatterns = @()
    )

    if ([string]::IsNullOrWhiteSpace([string]$SourcePath) -or -not (Test-Path -LiteralPath $SourcePath)) {
        return $false
    }

    if (Test-AzVmAppStateCaptureExcludedItem -SourcePath $SourcePath -ExcludeNames $ExcludeNames -ExcludePathPatterns $ExcludePathPatterns -ExcludeFilePatterns $ExcludeFilePatterns) {
        return $false
    }

    $item = Get-Item -LiteralPath $SourcePath -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $false
    }

    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $false
    }

    if ($item.PSIsContainer) {
        Ensure-AzVmAppStateDirectory -Path $DestinationPath
        $copiedAny = $false
        foreach ($child in @(Get-ChildItem -LiteralPath $SourcePath -Force -ErrorAction SilentlyContinue)) {
            $childDestination = Join-Path $DestinationPath $child.Name
            if (Copy-AzVmAppStateCaptureTree -SourcePath ([string]$child.FullName) -DestinationPath $childDestination -ExcludeNames $ExcludeNames -ExcludePathPatterns $ExcludePathPatterns -ExcludeFilePatterns $ExcludeFilePatterns) {
                $copiedAny = $true
            }
        }
        return $copiedAny
    }

    Ensure-AzVmAppStateDirectory -Path (Split-Path -Path $DestinationPath -Parent)
    try {
        Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force -ErrorAction Stop
        return $true
    }
    catch {
        Write-Host ("app-state-capture-file-skip => source={0}; destination={1}; reason={2}" -f [string]$SourcePath, [string]$DestinationPath, $_.Exception.Message)
        return $false
    }
}

function Get-AzVmAppStateScratchRootPath {
    param(
        [string]$Prefix
    )

    $normalizedPrefix = if ([string]::IsNullOrWhiteSpace([string]$Prefix)) { 'app-state' } else { ([string]$Prefix -replace '[^A-Za-z0-9\-]', '-').Trim('-') }
    if ([string]::IsNullOrWhiteSpace([string]$normalizedPrefix)) {
        $normalizedPrefix = 'app-state'
    }

    foreach ($basePath in @('C:\t', 'C:\Windows\Temp')) {
        try {
            Ensure-AzVmAppStateDirectory -Path $basePath
            return (Join-Path $basePath ('{0}-{1}' -f $normalizedPrefix, ([guid]::NewGuid().ToString('N'))))
        }
        catch {
        }
    }

    return (Join-Path $env:TEMP ('{0}-{1}' -f $normalizedPrefix, ([guid]::NewGuid().ToString('N'))))
}

function Stop-AzVmManagedProcessesGracefully {
    param(
        [string[]]$ProcessNames = @(),
        [int]$GracefulWaitSeconds = 10
    )

    $normalizedNames = @(
        @($ProcessNames) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { $_.Trim() } |
            Select-Object -Unique
    )
    if (@($normalizedNames).Count -lt 1) {
        return
    }

    foreach ($processName in @($normalizedNames)) {
        foreach ($process in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
            try {
                if ($process.MainWindowHandle -ne 0) {
                    [void]$process.CloseMainWindow()
                }
            }
            catch {
            }
        }
    }

    $deadline = (Get-Date).AddSeconds([Math]::Max($GracefulWaitSeconds, 1))
    do {
        $remaining = @()
        foreach ($processName in @($normalizedNames)) {
            $remaining += @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
        }
        if (@($remaining).Count -lt 1) {
            return
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    foreach ($process in @($remaining | Sort-Object Id -Unique)) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        }
        catch {
        }
    }
}

function Invoke-AzVmTaskAppStateReplayPreflight {
    param([string]$TaskName)

    if ([string]::Equals([string]$TaskName, '02-check-install-chrome', [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-AzVmManagedProcessesGracefully -ProcessNames @('chrome') -GracefulWaitSeconds 15
    }
}

function Resolve-AzVmAppStateCapturePathMatches {
    param(
        [string]$BasePath,
        [string]$RelativeOrAbsolutePath
    )

    if ([string]::IsNullOrWhiteSpace([string]$RelativeOrAbsolutePath)) {
        return @()
    }

    $candidatePath = [string]$RelativeOrAbsolutePath
    if (-not [System.IO.Path]::IsPathRooted($candidatePath) -and -not [string]::IsNullOrWhiteSpace([string]$BasePath)) {
        $candidatePath = Join-Path $BasePath $candidatePath
    }

    $hasWildcard = ($candidatePath.IndexOf('*', [System.StringComparison]::Ordinal) -ge 0 -or $candidatePath.IndexOf('?', [System.StringComparison]::Ordinal) -ge 0)
    if ($hasWildcard) {
        return @(
            Get-ChildItem -Path $candidatePath -Force -ErrorAction SilentlyContinue |
                Sort-Object FullName |
                Select-Object -ExpandProperty FullName
        )
    }

    if (Test-Path -LiteralPath $candidatePath) {
        return @([string](Resolve-Path -LiteralPath $candidatePath).Path)
    }

    return @()
}

function Test-AzVmAppStateLxssRegistryPath {
    param([string]$RegistryPath)

    return [string]::Equals(
        (Convert-AzVmAppStateRegistryPathToCanonicalRoot -RegistryPath $RegistryPath),
        'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Lxss',
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Get-AzVmAppStateAllowedLxssRegistryKeys {
    param([string[]]$DistributionAllowList = @())

    $normalizedAllowList = @(
        @($DistributionAllowList) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { $_.Trim().ToLowerInvariant() } |
            Select-Object -Unique
    )
    if (@($normalizedAllowList).Count -lt 1) {
        return @()
    }

    $providerRoot = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path -LiteralPath $providerRoot)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $providerRoot -ErrorAction SilentlyContinue |
            Sort-Object PSChildName |
            ForEach-Object {
                $distributionName = ''
                try {
                    $distributionName = [string](Get-ItemPropertyValue -LiteralPath $_.PSPath -Name 'DistributionName' -ErrorAction Stop)
                }
                catch {
                    return
                }
                if ([string]::IsNullOrWhiteSpace([string]$distributionName)) {
                    return
                }
                if (@($normalizedAllowList) -notcontains $distributionName.Trim().ToLowerInvariant()) {
                    return
                }
                [pscustomobject]@{
                    DistributionName = [string]$distributionName
                    RegistryPath = ('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Lxss\{0}' -f [string]$_.PSChildName)
                    KeyName = [string]$_.PSChildName
                }
            } |
            Where-Object { $_ -ne $null }
    )
}

function Export-AzVmFilteredLxssRegistry {
    param(
        [string]$DestinationPath,
        [string[]]$DistributionAllowList = @()
    )

    $allowedEntries = @(Get-AzVmAppStateAllowedLxssRegistryKeys -DistributionAllowList $DistributionAllowList)
    if (@($allowedEntries).Count -lt 1) {
        return $false
    }

    $tempExportPath = Join-Path $env:TEMP (('az-vm-lxss-{0}.reg' -f ([guid]::NewGuid().ToString('N'))))
    try {
        if (-not (Invoke-AzVmRegExport -RegistryPath 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Lxss' -DestinationPath $tempExportPath)) {
            return $false
        }

        $content = [string](Get-Content -LiteralPath $tempExportPath -Raw -Encoding Unicode -ErrorAction SilentlyContinue)
        if ([string]::IsNullOrWhiteSpace([string]$content)) {
            $content = [string](Get-Content -LiteralPath $tempExportPath -Raw -ErrorAction SilentlyContinue)
        }
        if ([string]::IsNullOrWhiteSpace([string]$content)) {
            return $false
        }

        $blocks = @([regex]::Split($content.Trim(), '(?:\r?\n){2,}'))
        if (@($blocks).Count -lt 2) {
            return $false
        }

        $rootPath = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Lxss'
        $allowedRegistryPaths = @($allowedEntries | ForEach-Object { [string]$_.RegistryPath })
        $defaultKey = [string]$allowedEntries[0].KeyName
        $outputBlocks = New-Object 'System.Collections.Generic.List[string]'
        [void]$outputBlocks.Add([string]$blocks[0].Trim())

        foreach ($block in @($blocks | Select-Object -Skip 1)) {
            $lines = @([regex]::Split([string]$block.Trim(), '\r?\n'))
            if (@($lines).Count -lt 1) {
                continue
            }

            $keyLine = [string]$lines[0]
            $match = [regex]::Match($keyLine, '^\[(.+)\]$')
            if (-not $match.Success) {
                continue
            }

            $blockRegistryPath = [string]$match.Groups[1].Value
            if ([string]::Equals($blockRegistryPath, $rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $rewrittenLines = New-Object 'System.Collections.Generic.List[string]'
                [void]$rewrittenLines.Add($keyLine)
                foreach ($line in @($lines | Select-Object -Skip 1)) {
                    if ($line -match '^\s*"NatIpAddress"=') { continue }
                    if ($line -match '^\s*"DefaultDistribution"=') { continue }
                    [void]$rewrittenLines.Add([string]$line)
                }
                [void]$rewrittenLines.Add(('"DefaultDistribution"="{{{0}}}"' -f $defaultKey.Trim('{}')))
                [void]$outputBlocks.Add(($rewrittenLines -join [Environment]::NewLine))
                continue
            }

            $keepBlock = $false
            foreach ($allowedRegistryPath in @($allowedRegistryPaths)) {
                if (
                    [string]::Equals($blockRegistryPath, $allowedRegistryPath, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $blockRegistryPath.StartsWith(($allowedRegistryPath + '\'), [System.StringComparison]::OrdinalIgnoreCase)
                ) {
                    $keepBlock = $true
                    break
                }
            }
            if ($keepBlock) {
                [void]$outputBlocks.Add(([string]$block).Trim())
            }
        }

        Ensure-AzVmAppStateDirectory -Path (Split-Path -Path $DestinationPath -Parent)
        Set-Content -LiteralPath $DestinationPath -Value (($outputBlocks -join ([Environment]::NewLine + [Environment]::NewLine)) + [Environment]::NewLine) -Encoding Unicode
        return $true
    }
    finally {
        Remove-Item -LiteralPath $tempExportPath -Force -ErrorAction SilentlyContinue
    }
}

function Export-AzVmAppStateUserRegistry {
    param(
        [string]$RegistryPath,
        [string]$DestinationPath,
        [psobject]$ProfileTarget,
        [string[]]$DistributionAllowList = @()
    )

    if ($null -eq $ProfileTarget) {
        return $false
    }

    if (Test-AzVmAppStateLxssRegistryPath -RegistryPath $RegistryPath) {
        return (Export-AzVmFilteredLxssRegistry -DestinationPath $DestinationPath -DistributionAllowList $DistributionAllowList)
    }

    $mountInfo = Get-AzVmMountedUserHive -ProfilePath ([string]$ProfileTarget.ProfilePath) -PreferredLabel ([string]$ProfileTarget.UserName)
    if ($null -eq $mountInfo) {
        return $false
    }

    try {
        $canonicalRoot = Convert-AzVmAppStateRegistryPathToCanonicalRoot -RegistryPath $RegistryPath
        if ([string]::IsNullOrWhiteSpace([string]$canonicalRoot)) {
            return $false
        }

        $mountedRoot = $canonicalRoot -replace '^HKEY_CURRENT_USER', ([string]$mountInfo.Root)
        $tempExportPath = Join-Path $env:TEMP (('az-vm-reg-export-{0}.reg' -f ([guid]::NewGuid().ToString('N'))))
        try {
            if (-not (Invoke-AzVmRegExport -RegistryPath $mountedRoot -DestinationPath $tempExportPath)) {
                return $false
            }
            return (Convert-AzVmAppStateRegRoot -SourcePath $tempExportPath -SourceRoot ([string]$mountInfo.Root) -DestinationRoot 'HKEY_CURRENT_USER' -DestinationPath $DestinationPath)
        }
        finally {
            Remove-Item -LiteralPath $tempExportPath -Force -ErrorAction SilentlyContinue
        }
    }
    finally {
        Close-AzVmMountedUserHive -MountInfo $mountInfo
    }
}

function Compress-AzVmAppStateCaptureRoot {
    param(
        [string]$SourceRoot,
        [string]$DestinationZipPath
    )

    if ([string]::IsNullOrWhiteSpace([string]$SourceRoot) -or -not (Test-Path -LiteralPath $SourceRoot)) {
        throw "App-state capture root is missing."
    }

    Remove-Item -LiteralPath $DestinationZipPath -Force -ErrorAction SilentlyContinue
    $previousProgressPreference = $global:ProgressPreference
    try {
        $global:ProgressPreference = 'SilentlyContinue'
        Compress-Archive -LiteralPath @(Get-ChildItem -LiteralPath $SourceRoot -Force | Select-Object -ExpandProperty FullName) -DestinationPath $DestinationZipPath -Force
    }
    finally {
        $global:ProgressPreference = $previousProgressPreference
    }
}

function Invoke-AzVmTaskAppStateCapture {
    param(
        [string]$TaskName,
        [string]$PlanPath,
        [string]$OutputZipPath,
        [string]$ManagerUser,
        [string]$AssistantUser
    )

    if ([string]::IsNullOrWhiteSpace([string]$PlanPath) -or -not (Test-Path -LiteralPath $PlanPath)) {
        throw ("App-state capture plan was not found: {0}" -f [string]$PlanPath)
    }

    $planText = [string](Get-Content -LiteralPath $PlanPath -Raw -ErrorAction Stop)
    $plan = ConvertFrom-Json -InputObject $planText -ErrorAction Stop
    if ($null -eq $plan) {
        throw "App-state capture plan could not be parsed."
    }

    $scratchRoot = Get-AzVmAppStateScratchRootPath -Prefix 'azv-capture'
    Ensure-AzVmAppStateDirectory -Path $scratchRoot
    $payloadRoot = Join-Path $scratchRoot 'payload'
    Ensure-AzVmAppStateDirectory -Path $payloadRoot

    $profileTargets = @(Get-AzVmAppStateProfileTargets -ManagerUser $ManagerUser -AssistantUser $AssistantUser)
    $machineRegistryExports = 0
    $userRegistryExports = 0
    $machineDirectoryExports = 0
    $machineFileExports = 0
    $profileDirectoryExports = 0
    $profileFileExports = 0
    $skipCount = 0

    $manifest = [ordered]@{
        version = 2
        taskName = [string]$TaskName
        machineDirectories = @()
        machineFiles = @()
        profileDirectories = @()
        profileFiles = @()
        registryImports = @()
    }

    try {
        foreach ($entry in @($plan.machineDirectories)) {
            if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.path)) { continue }
            foreach ($matchPath in @(Resolve-AzVmAppStateCapturePathMatches -BasePath '' -RelativeOrAbsolutePath ([string]$entry.path))) {
                $payloadPath = Join-Path ('payload\machine-directories') (ConvertTo-AzVmAppStateCaptureSafeName -Value $matchPath)
                if (Copy-AzVmAppStateCaptureTree -SourcePath $matchPath -DestinationPath (Join-Path $scratchRoot $payloadPath) -ExcludeNames @($entry.excludeNames) -ExcludePathPatterns @($entry.excludePathPatterns) -ExcludeFilePatterns @($entry.excludeFilePatterns)) {
                    $manifest.machineDirectories += @{
                        sourcePath = [string]$payloadPath
                        destinationPath = [string]$matchPath
                    }
                    $machineDirectoryExports++
                }
                else {
                    $skipCount++
                }
            }
        }

        foreach ($entry in @($plan.machineFiles)) {
            if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.path)) { continue }
            foreach ($matchPath in @(Resolve-AzVmAppStateCapturePathMatches -BasePath '' -RelativeOrAbsolutePath ([string]$entry.path))) {
                $payloadPath = Join-Path ('payload\machine-files') ((ConvertTo-AzVmAppStateCaptureSafeName -Value $matchPath) + [System.IO.Path]::GetExtension($matchPath))
                if (Copy-AzVmAppStateCaptureTree -SourcePath $matchPath -DestinationPath (Join-Path $scratchRoot $payloadPath) -ExcludeNames @($entry.excludeNames) -ExcludePathPatterns @($entry.excludePathPatterns) -ExcludeFilePatterns @($entry.excludeFilePatterns)) {
                    $manifest.machineFiles += @{
                        sourcePath = [string]$payloadPath
                        destinationPath = [string]$matchPath
                    }
                    $machineFileExports++
                }
                else {
                    $skipCount++
                }
            }
        }

        foreach ($entry in @($plan.profileDirectories)) {
            if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.path)) { continue }
            foreach ($profileTarget in @(Get-AzVmAppStateSelectedProfileTargets -ProfileTargets $profileTargets -Entry $entry)) {
                foreach ($matchPath in @(Resolve-AzVmAppStateCapturePathMatches -BasePath ([string]$profileTarget.ProfilePath) -RelativeOrAbsolutePath ([string]$entry.path))) {
                    $payloadPath = Join-Path ('payload\profile-directories\' + (ConvertTo-AzVmAppStateCaptureSafeName -Value ([string]$profileTarget.UserName))) (ConvertTo-AzVmAppStateCaptureSafeName -Value ([string]$entry.path))
                    if (Copy-AzVmAppStateCaptureTree -SourcePath $matchPath -DestinationPath (Join-Path $scratchRoot $payloadPath) -ExcludeNames @($entry.excludeNames) -ExcludePathPatterns @($entry.excludePathPatterns) -ExcludeFilePatterns @($entry.excludeFilePatterns)) {
                        $manifest.profileDirectories += @{
                            sourcePath = [string]$payloadPath
                            relativeDestinationPath = [string]$entry.path
                            targetProfiles = @([string]$profileTarget.Label)
                        }
                        $profileDirectoryExports++
                    }
                    else {
                        $skipCount++
                    }
                }
            }
        }

        foreach ($entry in @($plan.profileFiles)) {
            if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.path)) { continue }
            foreach ($profileTarget in @(Get-AzVmAppStateSelectedProfileTargets -ProfileTargets $profileTargets -Entry $entry)) {
                foreach ($matchPath in @(Resolve-AzVmAppStateCapturePathMatches -BasePath ([string]$profileTarget.ProfilePath) -RelativeOrAbsolutePath ([string]$entry.path))) {
                    $payloadPath = Join-Path ('payload\profile-files\' + (ConvertTo-AzVmAppStateCaptureSafeName -Value ([string]$profileTarget.UserName))) ((ConvertTo-AzVmAppStateCaptureSafeName -Value ([string]$entry.path)) + [System.IO.Path]::GetExtension($matchPath))
                    if (Copy-AzVmAppStateCaptureTree -SourcePath $matchPath -DestinationPath (Join-Path $scratchRoot $payloadPath) -ExcludeNames @($entry.excludeNames) -ExcludePathPatterns @($entry.excludePathPatterns) -ExcludeFilePatterns @($entry.excludeFilePatterns)) {
                        $manifest.profileFiles += @{
                            sourcePath = [string]$payloadPath
                            relativeDestinationPath = [string]$entry.path
                            targetProfiles = @([string]$profileTarget.Label)
                        }
                        $profileFileExports++
                    }
                    else {
                        $skipCount++
                    }
                }
            }
        }

        foreach ($entry in @($plan.machineRegistryKeys)) {
            if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.path)) { continue }
            $payloadPath = Join-Path 'payload\registry\machine' ((ConvertTo-AzVmAppStateCaptureSafeName -Value ([string]$entry.path)) + '.reg')
            if (Invoke-AzVmRegExport -RegistryPath (Convert-AzVmAppStateRegistryPathToCanonicalRoot -RegistryPath ([string]$entry.path)) -DestinationPath (Join-Path $scratchRoot $payloadPath)) {
                $manifest.registryImports += @{
                    sourcePath = [string]$payloadPath
                    scope = 'machine'
                }
                $machineRegistryExports++
            }
            else {
                $skipCount++
            }
        }

        foreach ($entry in @($plan.userRegistryKeys)) {
            if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.path)) { continue }
            foreach ($profileTarget in @(Get-AzVmAppStateSelectedProfileTargets -ProfileTargets $profileTargets -Entry $entry)) {
                $payloadPath = Join-Path ('payload\registry\user\' + (ConvertTo-AzVmAppStateCaptureSafeName -Value ([string]$profileTarget.UserName))) ((ConvertTo-AzVmAppStateCaptureSafeName -Value ([string]$entry.path)) + '.reg')
                if (Export-AzVmAppStateUserRegistry -RegistryPath ([string]$entry.path) -DestinationPath (Join-Path $scratchRoot $payloadPath) -ProfileTarget $profileTarget -DistributionAllowList @($entry.distributionAllowList)) {
                    $registryEntry = [ordered]@{
                        sourcePath = [string]$payloadPath
                        scope = 'user'
                        targetProfiles = @([string]$profileTarget.Label)
                    }
                    if (@($entry.distributionAllowList).Count -gt 0) {
                        $registryEntry.distributionAllowList = @($entry.distributionAllowList)
                    }
                    $manifest.registryImports += $registryEntry
                    $userRegistryExports++
                }
                else {
                    $skipCount++
                }
            }
        }

        $totalCapturedItems =
            [int]$machineRegistryExports +
            [int]$userRegistryExports +
            [int]$machineDirectoryExports +
            [int]$machineFileExports +
            [int]$profileDirectoryExports +
            [int]$profileFileExports
        if ($totalCapturedItems -gt 0) {
            Set-Content -LiteralPath (Join-Path $scratchRoot 'app-state.manifest.json') -Value ($manifest | ConvertTo-Json -Depth 12) -Encoding UTF8
            Compress-AzVmAppStateCaptureRoot -SourceRoot $scratchRoot -DestinationZipPath $OutputZipPath
        }
        return [pscustomobject]@{
            MachineRegistryExports = [int]$machineRegistryExports
            UserRegistryExports = [int]$userRegistryExports
            MachineDirectoryExports = [int]$machineDirectoryExports
            MachineFileExports = [int]$machineFileExports
            ProfileDirectoryExports = [int]$profileDirectoryExports
            ProfileFileExports = [int]$profileFileExports
            SkipCount = [int]$skipCount
            CreatedZip = ($totalCapturedItems -gt 0)
        }
    }
    finally {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $PlanPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-AzVmTaskAppStateReplay {
    param(
        [string]$ZipPath,
        [string]$TaskName,
        [string]$ManagerUser,
        [string]$AssistantUser
    )

    if ([string]::IsNullOrWhiteSpace([string]$ZipPath) -or -not (Test-Path -LiteralPath $ZipPath)) {
        throw ("Task app-state zip was not found on guest: {0}" -f [string]$ZipPath)
    }

    $replayWatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host ("app-state-phase => task={0}; phase=zip-ready-wait-start" -f [string]$TaskName)
    $zipLength = Wait-AzVmAppStateZipReady -ZipPath $ZipPath -TimeoutSeconds 60
    Write-Host ("app-state-phase => task={0}; phase=zip-ready; bytes={1}; elapsed={2:N1}s" -f [string]$TaskName, [int64]$zipLength, $replayWatch.Elapsed.TotalSeconds)

    $scratchRoot = Get-AzVmAppStateScratchRootPath -Prefix 'azv-replay'
    Ensure-AzVmAppStateDirectory -Path $scratchRoot
    $previousProgressPreference = $global:ProgressPreference
    try {
        $global:ProgressPreference = 'SilentlyContinue'
        Write-Host ("app-state-phase => task={0}; phase=extract-start; elapsed={1:N1}s" -f [string]$TaskName, $replayWatch.Elapsed.TotalSeconds)
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $scratchRoot -Force
        Write-Host ("app-state-phase => task={0}; phase=extract-complete; elapsed={1:N1}s" -f [string]$TaskName, $replayWatch.Elapsed.TotalSeconds)
    }
    finally {
        $global:ProgressPreference = $previousProgressPreference
    }

    try {
        $manifest = Get-AzVmAppStateManifestFromExpandedRoot -ExpandedRoot $scratchRoot -TaskName $TaskName
        Invoke-AzVmTaskAppStateReplayPreflight -TaskName $TaskName
        $profileTargets = @(Get-AzVmAppStateProfileTargets -ManagerUser $ManagerUser -AssistantUser $AssistantUser)
        Write-Host ("app-state-phase => task={0}; phase=manifest-ready; profiles={1}; elapsed={2:N1}s" -f [string]$TaskName, @($profileTargets).Count, $replayWatch.Elapsed.TotalSeconds)

        $machineRegistryImports = 0
        $userRegistryImports = 0
        $machineDirectoryCopies = 0
        $machineFileCopies = 0
        $profileDirectoryCopies = 0
        $profileFileCopies = 0

        foreach ($entry in @($manifest.machineDirectories)) {
            if ($null -eq $entry) { continue }
            $sourcePath = Join-Path $scratchRoot ([string]$entry.sourcePath)
            $destinationPath = [string]$entry.destinationPath
            if (-not (Test-Path -LiteralPath $sourcePath) -or [string]::IsNullOrWhiteSpace([string]$destinationPath)) {
                Write-Warning ("app-state-machine-directory-skip => {0}" -f [string]$sourcePath)
                continue
            }

            if (Copy-AzVmAppStateDirectoryContents -SourcePath $sourcePath -DestinationPath $destinationPath) {
                $machineDirectoryCopies++
            }
        }

        foreach ($entry in @($manifest.machineFiles)) {
            if ($null -eq $entry) { continue }
            $sourcePath = Join-Path $scratchRoot ([string]$entry.sourcePath)
            $destinationPath = [string]$entry.destinationPath
            if (-not (Test-Path -LiteralPath $sourcePath) -or [string]::IsNullOrWhiteSpace([string]$destinationPath)) {
                Write-Warning ("app-state-machine-file-skip => {0}" -f [string]$sourcePath)
                continue
            }

            if (Copy-AzVmAppStateFile -SourcePath $sourcePath -DestinationPath $destinationPath) {
                $machineFileCopies++
            }
        }

        foreach ($entry in @($manifest.profileDirectories)) {
            if ($null -eq $entry) { continue }
            $sourcePath = Join-Path $scratchRoot ([string]$entry.sourcePath)
            $relativeDestinationPath = [string]$entry.relativeDestinationPath
            if (-not (Test-Path -LiteralPath $sourcePath) -or [string]::IsNullOrWhiteSpace([string]$relativeDestinationPath)) {
                Write-Warning ("app-state-profile-directory-skip => {0}" -f [string]$sourcePath)
                continue
            }

            foreach ($profileTarget in @(Get-AzVmAppStateSelectedProfileTargets -ProfileTargets $profileTargets -Entry $entry)) {
                $destinationPath = Join-Path ([string]$profileTarget.ProfilePath) $relativeDestinationPath
                if (Copy-AzVmAppStateDirectoryContents -SourcePath $sourcePath -DestinationPath $destinationPath) {
                    $profileDirectoryCopies++
                }
            }
        }

        foreach ($entry in @($manifest.profileFiles)) {
            if ($null -eq $entry) { continue }
            $sourcePath = Join-Path $scratchRoot ([string]$entry.sourcePath)
            $relativeDestinationPath = [string]$entry.relativeDestinationPath
            if (-not (Test-Path -LiteralPath $sourcePath) -or [string]::IsNullOrWhiteSpace([string]$relativeDestinationPath)) {
                Write-Warning ("app-state-profile-file-skip => {0}" -f [string]$sourcePath)
                continue
            }

            foreach ($profileTarget in @(Get-AzVmAppStateSelectedProfileTargets -ProfileTargets $profileTargets -Entry $entry)) {
                $destinationPath = Join-Path ([string]$profileTarget.ProfilePath) $relativeDestinationPath
                if (Copy-AzVmAppStateFile -SourcePath $sourcePath -DestinationPath $destinationPath) {
                    $profileFileCopies++
                }
            }
        }

        foreach ($entry in @($manifest.registryImports)) {
            if ($null -eq $entry) { continue }
            $sourcePath = Join-Path $scratchRoot ([string]$entry.sourcePath)
            $scope = [string]$entry.scope
            if (-not (Test-Path -LiteralPath $sourcePath) -or [string]::IsNullOrWhiteSpace([string]$scope)) {
                Write-Warning ("app-state-registry-skip => {0}" -f [string]$sourcePath)
                continue
            }

            if ([string]::Equals([string]$scope, 'machine', [System.StringComparison]::OrdinalIgnoreCase)) {
                if (Invoke-AzVmRegImport -SourcePath $sourcePath) {
                    $machineRegistryImports++
                }
                else {
                    Write-Warning ("app-state-machine-registry-import-failed => {0}" -f [string]$sourcePath)
                }
                continue
            }

            if ([string]::Equals([string]$scope, 'user', [System.StringComparison]::OrdinalIgnoreCase)) {
                $distributionAllowList = @(
                    @($entry.distributionAllowList) |
                        ForEach-Object { [string]$_ } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
                )
                foreach ($profileTarget in @(Get-AzVmAppStateSelectedProfileTargets -ProfileTargets $profileTargets -Entry $entry)) {
                    $mountInfo = Get-AzVmMountedUserHive -ProfilePath ([string]$profileTarget.ProfilePath) -PreferredLabel ([string]$profileTarget.UserName)
                    if ($null -eq $mountInfo) {
                        Write-Warning ("app-state-user-registry-skip => {0} => hive-unavailable" -f [string]$profileTarget.Label)
                        continue
                    }

                    try {
                        $rewrittenPath = Join-Path $scratchRoot (('tmp-reg-{0}-{1}.reg' -f [string]$TaskName, ([string]$profileTarget.UserName -replace '[^A-Za-z0-9]', '_')))
                        if (@($distributionAllowList).Count -gt 0) {
                            Invoke-AzVmAppStateWslRegistryPurge -MountedUserRegistryRoot ([string]$mountInfo.Root) -RegistryPath 'HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss' -DistributionAllowList @($distributionAllowList)
                        }
                        if (-not (Convert-AzVmAppStateRegRoot -SourcePath $sourcePath -SourceRoot 'HKEY_CURRENT_USER' -DestinationRoot ([string]$mountInfo.Root) -DestinationPath $rewrittenPath)) {
                            Write-Warning ("app-state-user-registry-skip => {0} => rewrite-failed" -f [string]$profileTarget.Label)
                            continue
                        }

                        if (Invoke-AzVmRegImport -SourcePath $rewrittenPath) {
                            $userRegistryImports++
                        }
                        else {
                            Write-Warning ("app-state-user-registry-import-failed => {0} => {1}" -f [string]$profileTarget.Label, [string]$sourcePath)
                        }
                    }
                    finally {
                        Close-AzVmMountedUserHive -MountInfo $mountInfo
                    }
                }
            }
        }

        return [pscustomobject]@{
            MachineRegistryImports = [int]$machineRegistryImports
            UserRegistryImports = [int]$userRegistryImports
            MachineDirectoryCopies = [int]$machineDirectoryCopies
            MachineFileCopies = [int]$machineFileCopies
            ProfileDirectoryCopies = [int]$profileDirectoryCopies
            ProfileFileCopies = [int]$profileFileCopies
        }
    }
    finally {
        if ($replayWatch.IsRunning) {
            Write-Host ("app-state-phase => task={0}; phase=cleanup-start; elapsed={1:N1}s" -f [string]$TaskName, $replayWatch.Elapsed.TotalSeconds)
            $replayWatch.Stop()
        }
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Invoke-AzVmTaskAppStateReplay, Invoke-AzVmTaskAppStateCapture
