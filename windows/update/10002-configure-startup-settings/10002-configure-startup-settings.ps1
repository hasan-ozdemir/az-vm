$ErrorActionPreference = "Stop"
Write-Host "Update task started: configure-startup-settings"

$managerUser = "__VM_ADMIN_USER__"
$hostStartupProfileJsonBase64 = "__HOST_STARTUP_PROFILE_JSON_B64__"
$machineStartupFolder = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp'
$machineStartupApprovedFolderPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
$machineRunPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
$machineRunApprovalPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$machineRun32Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run32'
$machineRun32ApprovalPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'

Import-Module 'C:\Windows\Temp\az-vm-session-environment.psm1' -Force -DisableNameChecking

function Refresh-SessionPath {
    Refresh-AzVmSessionPath | Out-Null
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

function Resolve-CommandPath {
    param(
        [string]$CommandName,
        [string[]]$FallbackCandidates = @()
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$CommandName)) {
        $command = Get-Command $CommandName -ErrorAction SilentlyContinue
        if ($command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
            $candidate = [string]$command.Source
            if ([System.IO.Path]::IsPathRooted($candidate) -and (Test-Path -LiteralPath $candidate)) {
                return [string]$candidate
            }
        }
    }

    foreach ($candidate in @($FallbackCandidates)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }

        if (Test-Path -LiteralPath $candidate) {
            return [string]$candidate
        }
    }

    return ""
}

function Resolve-ExecutableUnderDirectory {
    param(
        [string[]]$RootPaths = @(),
        [string]$ExecutableName
    )

    if ([string]::IsNullOrWhiteSpace([string]$ExecutableName)) {
        return ""
    }

    foreach ($rootPath in @($RootPaths)) {
        if ([string]::IsNullOrWhiteSpace([string]$rootPath) -or -not (Test-Path -LiteralPath $rootPath)) {
            continue
        }

        $directCandidate = Join-Path $rootPath $ExecutableName
        if (Test-Path -LiteralPath $directCandidate) {
            return [string]$directCandidate
        }

        $match = Get-ChildItem -LiteralPath $rootPath -Filter $ExecutableName -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -First 1
        if ($match -and (Test-Path -LiteralPath $match.FullName)) {
            return [string]$match.FullName
        }
    }

    return ""
}

function Resolve-AppPackageExecutablePath {
    param(
        [string]$NameFragment,
        [string[]]$PackageNameHints = @(),
        [string]$ExecutableName
    )

    if ([string]::IsNullOrWhiteSpace([string]$ExecutableName)) {
        return ""
    }

    $allPackages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
    if (@($allPackages).Count -eq 0) {
        return ""
    }

    $normalizedNameFragment = [string]$NameFragment
    if (-not [string]::IsNullOrWhiteSpace([string]$normalizedNameFragment)) {
        $normalizedNameFragment = $normalizedNameFragment.Trim().ToLowerInvariant()
    }

    $normalizedHints = @(
        @($PackageNameHints) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { $_.Trim().ToLowerInvariant() }
    )

    $matchingPackages = @(
        $allPackages | Where-Object {
            $pkgName = [string]$_.Name
            $pkgFamily = [string]$_.PackageFamilyName
            $installLocation = [string]$_.InstallLocation
            if ([string]::IsNullOrWhiteSpace([string]$installLocation)) { return $false }
            if ([string]::IsNullOrWhiteSpace([string]$pkgName) -and [string]::IsNullOrWhiteSpace([string]$pkgFamily)) { return $false }

            $pkgNameLower = $pkgName.ToLowerInvariant()
            $pkgFamilyLower = $pkgFamily.ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace([string]$normalizedNameFragment)) {
                if ($pkgNameLower.Contains($normalizedNameFragment) -or $pkgFamilyLower.Contains($normalizedNameFragment)) {
                    return $true
                }
            }

            foreach ($hint in @($normalizedHints)) {
                if ($pkgNameLower.Contains($hint) -or $pkgFamilyLower.Contains($hint)) {
                    return $true
                }
            }

            return $false
        }
    )

    foreach ($package in @($matchingPackages)) {
        $installLocation = [string]$package.InstallLocation
        if ([string]::IsNullOrWhiteSpace([string]$installLocation)) {
            continue
        }

        $candidate = Join-Path $installLocation $ExecutableName
        if (Test-Path -LiteralPath $candidate) {
            return [string]$candidate
        }

        $match = Get-ChildItem -LiteralPath $installLocation -Filter $ExecutableName -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($match -and (Test-Path -LiteralPath $match.FullName)) {
            return [string]$match.FullName
        }
    }

    return ""
}

function Resolve-StartAppId {
    param([string]$NameFragment)

    if ([string]::IsNullOrWhiteSpace([string]$NameFragment)) {
        return ""
    }

    if (-not (Get-Command Get-StartApps -ErrorAction SilentlyContinue)) {
        return ""
    }

    $normalized = $NameFragment.Trim().ToLowerInvariant()
    $startApps = @(Get-StartApps | Where-Object {
        $nameText = [string]$_.Name
        if ([string]::IsNullOrWhiteSpace([string]$nameText)) {
            return $false
        }

        return $nameText.ToLowerInvariant().Contains($normalized)
    })

    foreach ($entry in @($startApps)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.AppID)) {
            return [string]$entry.AppID
        }
    }

    return ""
}

function Resolve-AppxAppIdFromPackage {
    param(
        [string]$NameFragment,
        [string[]]$PackageNameHints = @()
    )

    $allPackages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
    if (@($allPackages).Count -eq 0) {
        return ""
    }

    $normalizedNameFragment = [string]$NameFragment
    if (-not [string]::IsNullOrWhiteSpace([string]$normalizedNameFragment)) {
        $normalizedNameFragment = $normalizedNameFragment.Trim().ToLowerInvariant()
    }

    $normalizedHints = @(
        @($PackageNameHints) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { $_.Trim().ToLowerInvariant() }
    )

    $matchingPackages = @(
        $allPackages | Where-Object {
            $pkgName = [string]$_.Name
            $pkgFamily = [string]$_.PackageFamilyName
            $installLocation = [string]$_.InstallLocation
            if ([string]::IsNullOrWhiteSpace([string]$installLocation)) { return $false }
            if ([string]::IsNullOrWhiteSpace([string]$pkgName) -and [string]::IsNullOrWhiteSpace([string]$pkgFamily)) { return $false }

            $pkgNameLower = $pkgName.ToLowerInvariant()
            $pkgFamilyLower = $pkgFamily.ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace([string]$normalizedNameFragment)) {
                if ($pkgNameLower.Contains($normalizedNameFragment) -or $pkgFamilyLower.Contains($normalizedNameFragment)) {
                    return $true
                }
            }

            foreach ($hint in @($normalizedHints)) {
                if ($pkgNameLower.Contains($hint) -or $pkgFamilyLower.Contains($hint)) {
                    return $true
                }
            }

            return $false
        }
    )

    foreach ($package in @($matchingPackages)) {
        $manifestPath = Join-Path ([string]$package.InstallLocation) 'AppxManifest.xml'
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            continue
        }

        try {
            [xml]$manifestXml = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop
            $appNodes = @($manifestXml.SelectNodes("//*[local-name()='Application']"))
            foreach ($appNode in @($appNodes)) {
                $applicationId = [string]$appNode.GetAttribute('Id')
                if ([string]::IsNullOrWhiteSpace([string]$applicationId)) {
                    continue
                }

                return ("{0}!{1}" -f [string]$package.PackageFamilyName, $applicationId)
            }
        }
        catch {
        }
    }

    return ""
}

function Resolve-StoreAppId {
    param(
        [string]$NameFragment,
        [string[]]$PackageNameHints = @()
    )

    $startAppsAppId = Resolve-StartAppId -NameFragment $NameFragment
    if (-not [string]::IsNullOrWhiteSpace([string]$startAppsAppId)) {
        return $startAppsAppId
    }

    return (Resolve-AppxAppIdFromPackage -NameFragment $NameFragment -PackageNameHints $PackageNameHints)
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
        Write-Warning ("Host startup profile could not be decoded: {0}" -f $_.Exception.Message)
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

    foreach ($attempt in 1..6) {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds 250

        & reg.exe unload ("HKU\{0}" -f $MountName) | Out-Null
        if ($LASTEXITCODE -eq 0) {
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

function Ensure-DirectoryPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace([string]$Path)) {
        throw "Directory path is empty."
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Ensure-RegistryPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace([string]$Path)) {
        throw "Registry path is empty."
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
}

function Remove-RegistryValueIfPresent {
    param(
        [string]$Path,
        [string]$ValueName
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path) -or [string]::IsNullOrWhiteSpace([string]$ValueName)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $property = Get-ItemProperty -Path $Path -Name $ValueName -ErrorAction SilentlyContinue
    if ($null -eq $property) {
        return
    }

    Remove-ItemProperty -Path $Path -Name $ValueName -ErrorAction Stop
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

function Ensure-StartupApprovedEnabled {
    param(
        [string]$Path,
        [string]$ValueName
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path) -or [string]::IsNullOrWhiteSpace([string]$ValueName)) {
        throw "StartupApproved target is empty."
    }

    Ensure-RegistryPath -Path $Path
    $enabledValue = [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    New-ItemProperty -Path $Path -Name $ValueName -PropertyType Binary -Value $enabledValue -Force | Out-Null
}

function Get-ShortcutContract {
    param([string]$ShortcutPath)

    if ([string]::IsNullOrWhiteSpace([string]$ShortcutPath) -or -not (Test-Path -LiteralPath $ShortcutPath)) {
        return $null
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    return [pscustomobject]@{
        TargetPath = [string]$shortcut.TargetPath
        Arguments = [string]$shortcut.Arguments
        WorkingDirectory = [string]$shortcut.WorkingDirectory
        IconLocation = [string]$shortcut.IconLocation
    }
}

function Test-ShortcutMatches {
    param(
        [string]$ShortcutPath,
        [string]$TargetPath,
        [string]$Arguments = "",
        [string]$WorkingDirectory = "",
        [string]$IconLocation = ""
    )

    $contract = Get-ShortcutContract -ShortcutPath $ShortcutPath
    if ($null -eq $contract) {
        return $false
    }

    return (
        [string]::Equals([string]$contract.TargetPath, [string]$TargetPath, [System.StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$contract.Arguments, [string]$Arguments, [System.StringComparison]::Ordinal) -and
        [string]::Equals([string]$contract.WorkingDirectory, [string]$WorkingDirectory, [System.StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$contract.IconLocation, [string]$IconLocation, [System.StringComparison]::OrdinalIgnoreCase)
    )
}

function New-StartupShortcut {
    param(
        [string]$DirectoryPath,
        [string]$ApprovalPath,
        [string]$Name,
        [string]$TargetPath,
        [string]$Arguments = "",
        [string]$WorkingDirectory = "",
        [string]$IconLocation = ""
    )

    if ([string]::IsNullOrWhiteSpace([string]$Name)) {
        throw "Startup shortcut name is empty."
    }
    if ([string]::IsNullOrWhiteSpace([string]$TargetPath)) {
        throw "Startup shortcut target is empty."
    }

    Ensure-DirectoryPath -Path $DirectoryPath
    Ensure-RegistryPath -Path $ApprovalPath

    $shortcutPath = Join-Path $DirectoryPath ($Name + '.lnk')
    $tempShortcutPath = Join-Path $DirectoryPath (("az-vm-startup-{0}.lnk" -f [System.Guid]::NewGuid().ToString('N')))
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($tempShortcutPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = $Arguments

    $effectiveWorkingDirectory = ""
    if ([string]::IsNullOrWhiteSpace([string]$WorkingDirectory)) {
        $parentPath = Split-Path -Path $TargetPath -Parent
        if (-not [string]::IsNullOrWhiteSpace([string]$parentPath)) {
            $effectiveWorkingDirectory = [string]$parentPath
            $shortcut.WorkingDirectory = $effectiveWorkingDirectory
        }
    }
    else {
        $effectiveWorkingDirectory = [string]$WorkingDirectory
        $shortcut.WorkingDirectory = $effectiveWorkingDirectory
    }

    $effectiveIconLocation = ""
    if ([string]::IsNullOrWhiteSpace([string]$IconLocation)) {
        $effectiveIconLocation = "$TargetPath,0"
        $shortcut.IconLocation = $effectiveIconLocation
    }
    else {
        $effectiveIconLocation = [string]$IconLocation
        $shortcut.IconLocation = $effectiveIconLocation
    }

    $shortcut.Save()
    Move-Item -LiteralPath $tempShortcutPath -Destination $shortcutPath -Force
    Ensure-StartupApprovedEnabled -Path $ApprovalPath -ValueName ($Name + '.lnk')

    if (-not (Test-Path -LiteralPath $shortcutPath)) {
        throw ("Startup shortcut was not created: {0}" -f $shortcutPath)
    }

    if (-not (Test-ShortcutMatches -ShortcutPath $shortcutPath -TargetPath $TargetPath -Arguments $Arguments -WorkingDirectory $effectiveWorkingDirectory -IconLocation $effectiveIconLocation)) {
        throw ("Startup shortcut validation failed for '{0}'." -f $Name)
    }

    $approvalCode = Get-StartupApprovedStateCode -Path $ApprovalPath -ValueName ($Name + '.lnk')
    if ($approvalCode -ne 2) {
        throw ("StartupApproved validation failed for shortcut '{0}'." -f $Name)
    }
}

function Ensure-StartupShortcut {
    param(
        [string]$DirectoryPath,
        [string]$ApprovalPath,
        [string]$Name,
        [string]$TargetPath,
        [string]$Arguments = "",
        [string]$WorkingDirectory = "",
        [string]$IconLocation = ""
    )

    $shortcutPath = Join-Path $DirectoryPath ($Name + '.lnk')
    if (Test-ShortcutMatches -ShortcutPath $shortcutPath -TargetPath $TargetPath -Arguments $Arguments -WorkingDirectory $WorkingDirectory -IconLocation $IconLocation) {
        Ensure-StartupApprovedEnabled -Path $ApprovalPath -ValueName ($Name + '.lnk')
        Write-Host ("autostart-ok: {0} => already-configured shortcut" -f $Name)
        return
    }

    New-StartupShortcut -DirectoryPath $DirectoryPath -ApprovalPath $ApprovalPath -Name $Name -TargetPath $TargetPath -Arguments $Arguments -WorkingDirectory $WorkingDirectory -IconLocation $IconLocation
    Write-Host ("autostart-ok: {0} => shortcut" -f $Name)
}

function Remove-StartupShortcutIfPresent {
    param(
        [string]$DirectoryPath,
        [string]$ApprovalPath,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace([string]$DirectoryPath) -or [string]::IsNullOrWhiteSpace([string]$Name)) {
        return
    }

    $shortcutPath = Join-Path $DirectoryPath ($Name + '.lnk')
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction Stop
        Write-Host ("autostart-entry-removed: shortcut => {0}" -f $shortcutPath)
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$ApprovalPath)) {
        Remove-RegistryValueIfPresent -Path $ApprovalPath -ValueName ($Name + '.lnk')
    }
}

function Get-QuotedCommandLine {
    param(
        [string]$TargetPath,
        [string]$Arguments = ""
    )

    if ([string]::IsNullOrWhiteSpace([string]$TargetPath)) {
        throw "Startup command target is empty."
    }

    $quotedTarget = ('"{0}"' -f $TargetPath)
    if ([string]::IsNullOrWhiteSpace([string]$Arguments)) {
        return $quotedTarget
    }

    return ("{0} {1}" -f $quotedTarget, $Arguments).Trim()
}

function Get-CompatRunEntryContract {
    param(
        [string]$TargetPath,
        [string]$Arguments = ""
    )

    if ([string]::IsNullOrWhiteSpace([string]$TargetPath)) {
        throw "Compatibility run target is empty."
    }

    $fallback = [pscustomobject]@{
        TargetPath = [string]$TargetPath
        Arguments = [string]$Arguments
    }

    if ([string]::IsNullOrWhiteSpace([string]$cmdExe) -or -not (Test-Path -LiteralPath $cmdExe)) {
        return $fallback
    }

    $workingDirectory = Split-Path -Path $TargetPath -Parent
    $launchCommand = Get-QuotedCommandLine -TargetPath $TargetPath -Arguments $Arguments
    $wrapperArguments = '/c start ""'
    if (-not [string]::IsNullOrWhiteSpace([string]$workingDirectory)) {
        $wrapperArguments = ('{0} /d "{1}"' -f $wrapperArguments, [string]$workingDirectory)
    }

    $wrapperArguments = ('{0} {1}' -f $wrapperArguments, [string]$launchCommand).Trim()
    return [pscustomobject]@{
        TargetPath = [string]$cmdExe
        Arguments = [string]$wrapperArguments
    }
}

function Resolve-EmbeddedStartupTargetPath {
    param(
        [string]$WrapperTargetPath,
        [string]$Arguments = ''
    )

    $wrapperLeaf = [System.IO.Path]::GetFileName([string]$WrapperTargetPath)
    if ($wrapperLeaf -notin @('cmd.exe', 'powershell.exe', 'pwsh.exe')) {
        return [string]$WrapperTargetPath
    }

    $expandedArguments = [Environment]::ExpandEnvironmentVariables([string]$Arguments)
    if ([string]::IsNullOrWhiteSpace([string]$expandedArguments)) {
        return ''
    }

    foreach ($pattern in @(
        '(?i)if\s+exist\s+"([^"]+)"',
        '(?i)start\s+""\s+"([^"]+)"',
        '(?i)start\s+"?([^"\s]+\.(?:exe|cmd|bat))',
        '(?i)&\s*''([^'']+\.(?:exe|cmd|bat))''',
        '(?i)&\s*"([^"]+\.(?:exe|cmd|bat))"',
        '(?i)(?:^|[&\s])("?[%A-Za-z0-9_:\\ .()-]+\.(?:exe|cmd|bat))'
    )) {
        $match = [regex]::Match($expandedArguments, $pattern)
        if (-not $match.Success) {
            continue
        }

        $candidate = [string]$match.Groups[1].Value.Trim('"', '''', ' ')
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }

        $expandedCandidate = [Environment]::ExpandEnvironmentVariables($candidate)
        if (Test-Path -LiteralPath $expandedCandidate) {
            return [string]$expandedCandidate
        }

        $commandName = [System.IO.Path]::GetFileName($expandedCandidate)
        if (-not [string]::IsNullOrWhiteSpace([string]$commandName)) {
            $resolved = Resolve-CommandPath -CommandName $commandName
            if (-not [string]::IsNullOrWhiteSpace([string]$resolved)) {
                return [string]$resolved
            }
        }
    }

    return ''
}

function Test-StartupSpecEligible {
    param([pscustomobject]$Spec)

    if ($null -eq $Spec) {
        return $false
    }

    $targetPath = [string]$Spec.TargetPath
    if ([string]::IsNullOrWhiteSpace([string]$targetPath) -or -not (Test-Path -LiteralPath $targetPath)) {
        return $false
    }

    $targetLeaf = [System.IO.Path]::GetFileName($targetPath)
    if (($targetLeaf -eq 'explorer.exe') -and [string]::IsNullOrWhiteSpace([string]$Spec.Arguments)) {
        return $false
    }

    $wrapperLeaf = $targetLeaf
    if ($wrapperLeaf -in @('cmd.exe', 'powershell.exe', 'pwsh.exe')) {
        $embeddedTargetPath = Resolve-EmbeddedStartupTargetPath -WrapperTargetPath $targetPath -Arguments ([string]$Spec.Arguments)
        if ([string]::IsNullOrWhiteSpace([string]$embeddedTargetPath)) {
            return $false
        }
    }

    return $true
}

function Ensure-RunEntry {
    param(
        [string]$RunPath,
        [string]$ApprovalPath,
        [string]$Name,
        [string]$TargetPath,
        [string]$Arguments = ""
    )

    if ([string]::IsNullOrWhiteSpace([string]$RunPath) -or [string]::IsNullOrWhiteSpace([string]$ApprovalPath)) {
        throw "Run registry path is empty."
    }
    if ([string]::IsNullOrWhiteSpace([string]$Name)) {
        throw "Run entry name is empty."
    }

    Ensure-RegistryPath -Path $RunPath
    Ensure-RegistryPath -Path $ApprovalPath

    $commandLine = Get-QuotedCommandLine -TargetPath $TargetPath -Arguments $Arguments
    New-ItemProperty -Path $RunPath -Name $Name -PropertyType String -Value $commandLine -Force | Out-Null
    Ensure-StartupApprovedEnabled -Path $ApprovalPath -ValueName $Name

    $actualValue = [string](Get-ItemProperty -Path $RunPath -Name $Name -ErrorAction Stop).$Name
    if (-not [string]::Equals($actualValue, $commandLine, [System.StringComparison]::Ordinal)) {
        throw ("Run entry validation failed for '{0}'." -f $Name)
    }

    $approvalCode = Get-StartupApprovedStateCode -Path $ApprovalPath -ValueName $Name
    if ($approvalCode -ne 2) {
        throw ("StartupApproved validation failed for run entry '{0}'." -f $Name)
    }

    Write-Host ("autostart-ok: {0} => run-entry" -f $Name)
}

function Remove-RunEntryIfPresent {
    param(
        [string]$RunPath,
        [string]$ApprovalPath,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace([string]$RunPath) -or [string]::IsNullOrWhiteSpace([string]$Name)) {
        return
    }

    Remove-RegistryValueIfPresent -Path $RunPath -ValueName $Name
    if (-not [string]::IsNullOrWhiteSpace([string]$ApprovalPath)) {
        Remove-RegistryValueIfPresent -Path $ApprovalPath -ValueName $Name
    }
}

function Get-ManagerContext {
    param([string]$UserName)

    $profileInfo = Get-LocalUserProfileInfo -UserName $UserName
    $mountName = ''
    $mainRoot = ("Registry::HKEY_USERS\{0}" -f [string]$profileInfo.Sid)
    if (-not (Test-Path -LiteralPath $mainRoot)) {
        $mountName = 'AzVm10001Manager'
        $mainRoot = Mount-RegistryHive -MountName $mountName -HiveFilePath (Join-Path ([string]$profileInfo.ProfilePath) 'NTUSER.DAT')
    }

    return [pscustomobject]@{
        ProfileInfo = $profileInfo
        MainRoot = [string]$mainRoot
        MountName = [string]$mountName
        QualifiedUserName = ('{0}\{1}' -f $env:COMPUTERNAME, [string]$profileInfo.UserName)
        StartupFolder = (Join-Path ([string]$profileInfo.ProfilePath) 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup')
        StartupApprovedStartupFolderPath = ("{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder" -f [string]$mainRoot)
        RunPath = ("{0}\Software\Microsoft\Windows\CurrentVersion\Run" -f [string]$mainRoot)
        RunApprovalPath = ("{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" -f [string]$mainRoot)
        Run32Path = ("{0}\Software\Microsoft\Windows\CurrentVersion\Run32" -f [string]$mainRoot)
        Run32ApprovalPath = ("{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32" -f [string]$mainRoot)
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
            RunPath = [string]$machineRunPath
            ApprovalPath = [string]$machineRunApprovalPath
        }
        [pscustomobject]@{
            Scope = 'LocalMachine'
            EntryType = 'Run32'
            Kind = 'Run'
            RunPath = [string]$machineRun32Path
            ApprovalPath = [string]$machineRun32ApprovalPath
        }
        [pscustomobject]@{
            Scope = 'LocalMachine'
            EntryType = 'StartupFolder'
            Kind = 'StartupFolder'
            DirectoryPath = [string]$machineStartupFolder
            ApprovalPath = [string]$machineStartupApprovedFolderPath
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

function Get-CompatStartupEntryName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace([string]$Name)) {
        return ''
    }

    return ('AzVm Startup Compat - {0}' -f $Name)
}

function Remove-CompatScheduledTaskIfPresent {
    param([string]$TaskName)

    if ([string]::IsNullOrWhiteSpace([string]$TaskName)) {
        return
    }

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        return
    }

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    Write-Host ("autostart-entry-removed: scheduled-task => {0}" -f [string]$TaskName)
}

function Ensure-CompatScheduledTask {
    param(
        [string]$TaskName,
        [pscustomobject]$ManagerContext,
        [string]$TargetPath,
        [string]$Arguments = ""
    )

    if ([string]::IsNullOrWhiteSpace([string]$TaskName)) {
        throw "Compatibility startup task name is empty."
    }
    if ($null -eq $ManagerContext -or [string]::IsNullOrWhiteSpace([string]$ManagerContext.QualifiedUserName)) {
        throw "Manager context is missing the qualified user name for compatibility startup."
    }

    $compatContract = Get-CompatRunEntryContract -TargetPath $TargetPath -Arguments $Arguments
    $action = New-ScheduledTaskAction -Execute ([string]$compatContract.TargetPath) -Argument ([string]$compatContract.Arguments)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User ([string]$ManagerContext.QualifiedUserName)
    $principal = New-ScheduledTaskPrincipal -UserId ([string]$ManagerContext.QualifiedUserName) -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

    $registeredTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $registeredTask) {
        throw ("Compatibility startup task registration failed for '{0}'." -f [string]$TaskName)
    }

    Write-Host ("autostart-ok: {0} => scheduled-task" -f [string]$TaskName)
}

function Resolve-StartupLocationDefinition {
    param(
        [object[]]$LocationDefinitions,
        [string]$Scope,
        [string]$EntryType
    )

    return @(
        @($LocationDefinitions) |
            Where-Object {
                [string]::Equals([string]$_.Scope, [string]$Scope, [System.StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals([string]$_.EntryType, [string]$EntryType, [System.StringComparison]::OrdinalIgnoreCase)
            } |
            Select-Object -First 1
    )[0]
}

function Clear-OwnedStartupArtifacts {
    param(
        [psobject]$Spec,
        [object[]]$LocationDefinitions
    )

    foreach ($ownedName in @($Spec.OwnedNames)) {
        foreach ($location in @($LocationDefinitions)) {
            if ([string]::Equals([string]$location.Kind, 'Run', [System.StringComparison]::OrdinalIgnoreCase)) {
                Remove-RunEntryIfPresent -RunPath ([string]$location.RunPath) -ApprovalPath ([string]$location.ApprovalPath) -Name ([string]$ownedName)
            }
            else {
                Remove-StartupShortcutIfPresent -DirectoryPath ([string]$location.DirectoryPath) -ApprovalPath ([string]$location.ApprovalPath) -Name ([string]$ownedName)
            }
        }
    }

    $compatEntryName = Get-CompatStartupEntryName -Name ([string]$Spec.Name)
    if (-not [string]::IsNullOrWhiteSpace([string]$compatEntryName)) {
        $currentUserRunLocation = Resolve-StartupLocationDefinition -LocationDefinitions $LocationDefinitions -Scope 'CurrentUser' -EntryType 'Run'
        if ($null -ne $currentUserRunLocation) {
            Remove-RunEntryIfPresent -RunPath ([string]$currentUserRunLocation.RunPath) -ApprovalPath ([string]$currentUserRunLocation.ApprovalPath) -Name $compatEntryName
        }

        $currentUserStartupLocation = Resolve-StartupLocationDefinition -LocationDefinitions $LocationDefinitions -Scope 'CurrentUser' -EntryType 'StartupFolder'
        if ($null -ne $currentUserStartupLocation) {
            Remove-StartupShortcutIfPresent -DirectoryPath ([string]$currentUserStartupLocation.DirectoryPath) -ApprovalPath ([string]$currentUserStartupLocation.ApprovalPath) -Name $compatEntryName
        }

        Remove-CompatScheduledTaskIfPresent -TaskName $compatEntryName
    }
}

function Ensure-AppStartupLocation {
    param(
        [psobject]$Spec,
        [psobject]$ProfileEntry,
        [object[]]$LocationDefinitions,
        [pscustomobject]$ManagerContext
    )

    $targetPath = [string]$Spec.TargetPath
    if (-not (Test-StartupSpecEligible -Spec ([pscustomobject]$Spec))) {
        Write-Warning ("autostart-skip: {0} => target or embedded startup command could not be resolved." -f [string]$Spec.Name)
        return
    }

    $requestedLocation = Resolve-RequestedStartupLocation -ProfileEntry $ProfileEntry -LocationDefinitions $LocationDefinitions
    if ($null -eq $requestedLocation) {
        Write-Warning ("autostart-skip: {0} => unsupported host startup method '{1}/{2}'." -f [string]$Spec.Name, [string]$ProfileEntry.Scope, [string]$ProfileEntry.EntryType)
        return
    }

    $enableLocalMachineCompat = $true
    if ($Spec.PSObject.Properties.Match('EnableLocalMachineCompat').Count -gt 0) {
        $enableLocalMachineCompat = [bool]$Spec.EnableLocalMachineCompat
    }

    if ([string]::Equals([string]$requestedLocation.Kind, 'Run', [System.StringComparison]::OrdinalIgnoreCase)) {
        Ensure-RunEntry -RunPath ([string]$requestedLocation.RunPath) -ApprovalPath ([string]$requestedLocation.ApprovalPath) -Name ([string]$Spec.Name) -TargetPath $targetPath -Arguments ([string]$Spec.Arguments)
        if (
            [string]::Equals([string]$requestedLocation.Scope, 'LocalMachine', [System.StringComparison]::OrdinalIgnoreCase) -and
            $enableLocalMachineCompat
        ) {
            $compatEntryName = Get-CompatStartupEntryName -Name ([string]$Spec.Name)
            Ensure-CompatScheduledTask -TaskName $compatEntryName -ManagerContext $ManagerContext -TargetPath $targetPath -Arguments ([string]$Spec.Arguments)
            Write-Host ("autostart-compat => {0} => ScheduledTask/AtLogOn" -f [string]$Spec.Name)
        }
        Write-Host ("autostart-method => {0} => {1}/{2}" -f [string]$Spec.Name, [string]$requestedLocation.Scope, [string]$requestedLocation.EntryType)
        return
    }

    Ensure-StartupShortcut -DirectoryPath ([string]$requestedLocation.DirectoryPath) -ApprovalPath ([string]$requestedLocation.ApprovalPath) -Name ([string]$Spec.Name) -TargetPath $targetPath -Arguments ([string]$Spec.Arguments) -WorkingDirectory ([string]$Spec.WorkingDirectory) -IconLocation ([string]$Spec.IconLocation)
    Write-Host ("autostart-method => {0} => {1}/{2}" -f [string]$Spec.Name, [string]$requestedLocation.Scope, [string]$requestedLocation.EntryType)
}

Refresh-SessionPath

$cmdExe = Resolve-CommandPath -CommandName "cmd.exe" -FallbackCandidates @("C:\Windows\System32\cmd.exe")
$explorerExe = Resolve-CommandPath -CommandName "explorer.exe" -FallbackCandidates @("C:\Windows\explorer.exe")
$dockerDesktopExe = Resolve-CommandPath -CommandName "Docker Desktop.exe" -FallbackCandidates @("C:\Program Files\Docker\Docker\Docker Desktop.exe")
$iTunesHelperExe = Resolve-CommandPath -CommandName "iTunesHelper.exe" -FallbackCandidates @(
    'C:\Program Files\iTunes\iTunesHelper.exe',
    'C:\Program Files (x86)\iTunes\iTunesHelper.exe'
)
$oneDriveExe = Resolve-CommandPath -CommandName "OneDrive.exe" -FallbackCandidates @(
    'C:\Program Files\Microsoft OneDrive\OneDrive.exe',
    ("C:\Users\{0}\AppData\Local\Microsoft\OneDrive\OneDrive.exe" -f $managerUser)
)
$teamsExe = Resolve-CommandPath -CommandName "ms-teams.exe" -FallbackCandidates @(
    'C:\Program Files\WindowsApps\MSTeams_8wekyb3d8bbwe\ms-teams.exe',
    ("C:\Users\{0}\AppData\Local\Microsoft\WindowsApps\MSTeams_8wekyb3d8bbwe\ms-teams.exe" -f $managerUser)
)
$ollamaAppExe = Resolve-CommandPath -CommandName "ollama app.exe" -FallbackCandidates @(
    ("C:\Users\{0}\AppData\Local\Programs\Ollama\ollama app.exe" -f $managerUser),
    (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe')
)
$googleDriveExe = Resolve-CommandPath -CommandName "GoogleDriveFS.exe" -FallbackCandidates @('C:\Program Files\Google\Drive File Stream\GoogleDriveFS.exe')
if ([string]::IsNullOrWhiteSpace([string]$googleDriveExe)) {
    $googleDriveExe = Resolve-ExecutableUnderDirectory -RootPaths @('C:\Program Files\Google\Drive File Stream') -ExecutableName 'GoogleDriveFS.exe'
}
$windscribeExe = Resolve-CommandPath -CommandName "Windscribe.exe" -FallbackCandidates @(
    'C:\Program Files\Windscribe\Windscribe.exe',
    'C:\Program Files (x86)\Windscribe\Windscribe.exe'
)
$anyDeskExe = Resolve-CommandPath -CommandName "AnyDesk.exe" -FallbackCandidates @(
    'C:\Program Files\AnyDesk\AnyDesk.exe',
    'C:\Program Files (x86)\AnyDesk\AnyDesk.exe'
)
$jawsExe = Resolve-CommandPath -CommandName "jfw.exe" -FallbackCandidates @(
    'C:\Program Files\Freedom Scientific\JAWS\2025\jfw.exe',
    'C:\Program Files (x86)\Freedom Scientific\JAWS\2025\jfw.exe'
)
$codexAppExe = Resolve-AppPackageExecutablePath -NameFragment 'codex' -PackageNameHints @('OpenAI.Codex', '2p2nqsd0c76g0') -ExecutableName 'Codex.exe'
$teamsAppId = Resolve-StoreAppId -NameFragment 'teams' -PackageNameHints @('MSTeams', 'MicrosoftTeams', 'teams')
$codexAppId = Resolve-StoreAppId -NameFragment 'codex' -PackageNameHints @('OpenAI.Codex', '2p2nqsd0c76g0')

$hostStartupProfile = @(Convert-Base64JsonToObjectArray -Base64Text $hostStartupProfileJsonBase64)
$hostStartupProfileByKey = @{}
foreach ($entry in @($hostStartupProfile)) {
    if ($null -eq $entry) {
        continue
    }

    $key = if ($entry.PSObject.Properties.Match('Key').Count -gt 0) { [string]$entry.Key } else { '' }
    if ([string]::IsNullOrWhiteSpace([string]$key) -or $hostStartupProfileByKey.ContainsKey($key)) {
        continue
    }

    $hostStartupProfileByKey[$key] = $entry
}

$hostStartupSummary = @(
    @($hostStartupProfileByKey.Keys | Sort-Object) |
        ForEach-Object {
            $entry = $hostStartupProfileByKey[[string]$_]
            ("{0}:{1}:{2}" -f [string]$_, [string]$entry.EntryType, [string]$entry.Scope)
        }
)
if (@($hostStartupSummary).Count -eq 0) {
    Write-Host 'host-startup-profile => none'
}
else {
    Write-Host ("host-startup-profile => {0}" -f ($hostStartupSummary -join ', '))
}

$supportedSpecs = [ordered]@{
    'docker-desktop' = [pscustomobject]@{
        Name = 'Docker Desktop'
        OwnedNames = @('Docker Desktop')
        TargetPath = $dockerDesktopExe
        Arguments = '--minimized'
        WorkingDirectory = if ([string]::IsNullOrWhiteSpace([string]$dockerDesktopExe)) { '' } else { Split-Path -Path $dockerDesktopExe -Parent }
        IconLocation = if ([string]::IsNullOrWhiteSpace([string]$dockerDesktopExe)) { '' } else { "$dockerDesktopExe,0" }
    }
    'ollama' = [pscustomobject]@{
        Name = 'Ollama'
        OwnedNames = @('Ollama')
        TargetPath = $cmdExe
        Arguments = '/c if exist "%LOCALAPPDATA%\Programs\Ollama\ollama app.exe" start "" "%LOCALAPPDATA%\Programs\Ollama\ollama app.exe"'
        WorkingDirectory = 'C:\Users'
        IconLocation = if ([string]::IsNullOrWhiteSpace([string]$ollamaAppExe)) { '' } else { "$ollamaAppExe,0" }
    }
    'onedrive' = [pscustomobject]@{
        Name = 'OneDrive'
        OwnedNames = @('OneDrive')
        TargetPath = $oneDriveExe
        Arguments = '/background'
        WorkingDirectory = if ([string]::IsNullOrWhiteSpace([string]$oneDriveExe)) { '' } else { Split-Path -Path $oneDriveExe -Parent }
        IconLocation = if ([string]::IsNullOrWhiteSpace([string]$oneDriveExe)) { '' } else { "$oneDriveExe,0" }
    }
    'teams' = [pscustomobject]@{
        Name = 'Teams'
        OwnedNames = @('Teams')
        TargetPath = if (-not [string]::IsNullOrWhiteSpace([string]$teamsAppId)) { $explorerExe } elseif (-not [string]::IsNullOrWhiteSpace([string]$teamsExe) -and -not $teamsExe.ToLowerInvariant().Contains('\users\')) { $teamsExe } else { $cmdExe }
        Arguments = if (-not [string]::IsNullOrWhiteSpace([string]$teamsAppId)) { ("shell:AppsFolder\" + $teamsAppId) } elseif (-not [string]::IsNullOrWhiteSpace([string]$teamsExe) -and -not $teamsExe.ToLowerInvariant().Contains('\users\')) { 'msteams:system-initiated' } else { '/c start "" ms-teams.exe msteams:system-initiated' }
        WorkingDirectory = if (-not [string]::IsNullOrWhiteSpace([string]$teamsAppId)) { 'C:\Windows' } elseif (-not [string]::IsNullOrWhiteSpace([string]$teamsExe) -and -not $teamsExe.ToLowerInvariant().Contains('\users\')) { Split-Path -Path $teamsExe -Parent } else { 'C:\Users' }
        IconLocation = if (-not [string]::IsNullOrWhiteSpace([string]$teamsExe)) { "$teamsExe,0" } else { "$explorerExe,0" }
    }
    'itunes-helper' = [pscustomobject]@{
        Name = 'iTunesHelper'
        OwnedNames = @('iTunesHelper')
        TargetPath = $iTunesHelperExe
        Arguments = ''
        WorkingDirectory = if ([string]::IsNullOrWhiteSpace([string]$iTunesHelperExe)) { '' } else { Split-Path -Path $iTunesHelperExe -Parent }
        IconLocation = if ([string]::IsNullOrWhiteSpace([string]$iTunesHelperExe)) { '' } else { "$iTunesHelperExe,0" }
    }
    'google-drive' = [pscustomobject]@{
        Name = 'Google Drive'
        OwnedNames = @('Google Drive')
        TargetPath = $googleDriveExe
        Arguments = ''
        WorkingDirectory = if ([string]::IsNullOrWhiteSpace([string]$googleDriveExe)) { '' } else { Split-Path -Path $googleDriveExe -Parent }
        IconLocation = if ([string]::IsNullOrWhiteSpace([string]$googleDriveExe)) { '' } else { "$googleDriveExe,0" }
    }
    'windscribe' = [pscustomobject]@{
        Name = 'Windscribe'
        OwnedNames = @('Windscribe')
        TargetPath = $windscribeExe
        Arguments = ''
        WorkingDirectory = if ([string]::IsNullOrWhiteSpace([string]$windscribeExe)) { '' } else { Split-Path -Path $windscribeExe -Parent }
        IconLocation = if ([string]::IsNullOrWhiteSpace([string]$windscribeExe)) { '' } else { "$windscribeExe,0" }
    }
    'anydesk' = [pscustomobject]@{
        Name = 'AnyDesk'
        OwnedNames = @('AnyDesk')
        TargetPath = $anyDeskExe
        Arguments = ''
        WorkingDirectory = if ([string]::IsNullOrWhiteSpace([string]$anyDeskExe)) { '' } else { Split-Path -Path $anyDeskExe -Parent }
        IconLocation = if ([string]::IsNullOrWhiteSpace([string]$anyDeskExe)) { '' } else { "$anyDeskExe,0" }
    }
    'codex-app' = [pscustomobject]@{
        Name = 'Codex App'
        OwnedNames = @('Codex App')
        TargetPath = if (-not [string]::IsNullOrWhiteSpace([string]$codexAppExe)) { $codexAppExe } else { $explorerExe }
        Arguments = if (-not [string]::IsNullOrWhiteSpace([string]$codexAppExe)) { '' } elseif (-not [string]::IsNullOrWhiteSpace([string]$codexAppId)) { ("shell:AppsFolder\" + $codexAppId) } else { '' }
        WorkingDirectory = if (-not [string]::IsNullOrWhiteSpace([string]$codexAppExe)) { Split-Path -Path $codexAppExe -Parent } else { 'C:\Windows' }
        IconLocation = if (-not [string]::IsNullOrWhiteSpace([string]$codexAppExe)) { "$codexAppExe,0" } else { "$explorerExe,0" }
    }
    'jaws' = [pscustomobject]@{
        Name = 'JAWS'
        OwnedNames = @('JAWS')
        TargetPath = $jawsExe
        Arguments = '/run'
        WorkingDirectory = if ([string]::IsNullOrWhiteSpace([string]$jawsExe)) { '' } else { Split-Path -Path $jawsExe -Parent }
        IconLocation = if ([string]::IsNullOrWhiteSpace([string]$jawsExe)) { '' } else { "$jawsExe,0" }
        ForcedLocation = [pscustomobject]@{
            Scope = 'LocalMachine'
            EntryType = 'Run'
        }
        EnableLocalMachineCompat = $false
    }
}

$managedStartupSummary = @(
    @($supportedSpecs.Keys) |
        ForEach-Object {
            $spec = $supportedSpecs[[string]$_]
            if ($spec.PSObject.Properties.Match('ForcedLocation').Count -ge 1 -and $null -ne $spec.ForcedLocation) {
                ("{0}:{1}:{2}" -f [string]$_, [string]$spec.ForcedLocation.EntryType, [string]$spec.ForcedLocation.Scope)
            }
        } |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
)
if (@($managedStartupSummary).Count -eq 0) {
    Write-Host 'managed-startup-profile => none'
}
else {
    Write-Host ("managed-startup-profile => {0}" -f ($managedStartupSummary -join ', '))
}

$managerContext = $null
try {
    $managerContext = Get-ManagerContext -UserName $managerUser
    $locationDefinitions = @(Get-StartupLocationDefinitions -ManagerContext $managerContext)

    foreach ($profileKey in @($hostStartupProfileByKey.Keys | Sort-Object)) {
        if (-not $supportedSpecs.Contains($profileKey)) {
            Write-Warning ("autostart-skip: unsupported host app key '{0}'." -f $profileKey)
        }
    }

    foreach ($startupKey in @($supportedSpecs.Keys)) {
        $spec = $supportedSpecs[$startupKey]
        Clear-OwnedStartupArtifacts -Spec $spec -LocationDefinitions $locationDefinitions

        $forcedLocation = $null
        if ($spec.PSObject.Properties.Match('ForcedLocation').Count -gt 0) {
            $forcedLocation = $spec.ForcedLocation
        }
        if ($null -ne $forcedLocation) {
            Write-Host ("autostart-managed => {0} => {1}/{2}" -f [string]$spec.Name, [string]$forcedLocation.Scope, [string]$forcedLocation.EntryType)
            Ensure-AppStartupLocation -Spec $spec -ProfileEntry $forcedLocation -LocationDefinitions $locationDefinitions -ManagerContext $managerContext
            continue
        }

        if (-not $hostStartupProfileByKey.ContainsKey($startupKey)) {
            Write-Host ("autostart-cleared: {0} => host-disabled-or-absent" -f [string]$spec.Name)
            continue
        }

        Ensure-AppStartupLocation -Spec $spec -ProfileEntry $hostStartupProfileByKey[$startupKey] -LocationDefinitions $locationDefinitions -ManagerContext $managerContext
    }
}
finally {
    if ($null -ne $managerContext -and -not [string]::IsNullOrWhiteSpace([string]$managerContext.MountName)) {
        Dismount-RegistryHive -MountName ([string]$managerContext.MountName)
    }
}

Write-Host 'configure-startup-settings-completed'
Write-Host "Update task completed: configure-startup-settings"

