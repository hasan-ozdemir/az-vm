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

    $rows = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $reserved = @('all users', 'default', 'default user', 'public')

    foreach ($row in @(
        @{ Label = 'manager'; UserName = [string]$ManagerUser; Path = ('C:\Users\{0}' -f [string]$ManagerUser) },
        @{ Label = 'assistant'; UserName = [string]$AssistantUser; Path = ('C:\Users\{0}' -f [string]$AssistantUser) },
        @{ Label = 'default'; UserName = 'default'; Path = 'C:\Users\Default' }
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

    foreach ($directory in @(Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if ($null -eq $directory) {
            continue
        }

        $name = [string]$directory.Name
        if ([string]::IsNullOrWhiteSpace([string]$name)) {
            continue
        }

        if ($reserved -contains $name.Trim().ToLowerInvariant()) {
            continue
        }

        $normalizedPath = ([string]$directory.FullName).TrimEnd('\').ToLowerInvariant()
        if ($seen.ContainsKey($normalizedPath)) {
            continue
        }

        $rows.Add([pscustomobject]@{
            Label = ('user:{0}' -f $name)
            UserName = [string]$name
            ProfilePath = [string]$directory.FullName
        }) | Out-Null
        $seen[$normalizedPath] = $true
    }

    return @($rows.ToArray())
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

    $rewritten = [regex]::Replace(
        $content,
        ('(?m)^{0}(?=\\|$)' -f [regex]::Escape([string]$SourceRoot)),
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            return [string]$DestinationRoot
        })

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

    $scratchRoot = Join-Path $env:TEMP ('az-vm-app-state-{0}' -f ([guid]::NewGuid().ToString('N')))
    Ensure-AzVmAppStateDirectory -Path $scratchRoot
    $previousProgressPreference = $global:ProgressPreference
    try {
        $global:ProgressPreference = 'SilentlyContinue'
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $scratchRoot -Force
    }
    finally {
        $global:ProgressPreference = $previousProgressPreference
    }

    try {
        $manifest = Get-AzVmAppStateManifestFromExpandedRoot -ExpandedRoot $scratchRoot -TaskName $TaskName
        $profileTargets = @(Get-AzVmAppStateProfileTargets -ManagerUser $ManagerUser -AssistantUser $AssistantUser)

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

            foreach ($profileTarget in @($profileTargets)) {
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

            foreach ($profileTarget in @($profileTargets)) {
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
                foreach ($profileTarget in @($profileTargets)) {
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
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Invoke-AzVmTaskAppStateReplay
