$ErrorActionPreference = "Stop"
Write-Host "Update task started: create-shortcuts-public-desktop"

$companyName = "__COMPANY_NAME__"
$employeeEmailAddress = "__EMPLOYEE_EMAIL_ADDRESS__"
$employeeFullName = "__EMPLOYEE_FULL_NAME__"
$managerUser = "__VM_ADMIN_USER__"
$assistantUser = "__ASSISTANT_USER__"
$publicDesktop = "C:\Users\Public\Desktop"
$publicChromeUserDataDir = "C:\Users\Public\AppData\Local\Google\Chrome\UserData"
$beMyEyesStoreProductId = "9MSW46LTDWGF"
$beMyEyesStoreUri = "ms-windows-store://pdp/?ProductId=9MSW46LTDWGF"
$codexAppFallbackPath = Join-Path $env:ProgramFiles "WindowsApps\OpenAI.Codex_26.306.996.0_x64__2p2nqsd0c76g0\app\Codex.exe"
$whatsAppFallbackPath = "C:\Program Files\WindowsApps\5319275A.WhatsAppDesktop_2.2606.102.0_x64__cv1g1gvanyjgm\WhatsApp.Root.exe"
$iCloudFallbackPath = "C:\Program Files\WindowsApps\AppleInc.iCloud_15.7.56.0_x64__nzyj5cx40ttqa\iCloud\iCloudHome.exe"
$shortcutRunAsAdminFlag = 0x00002000
$unresolvedCompanyNameToken = ('__' + 'COMPANY_NAME' + '__')
$unresolvedEmployeeEmailAddressToken = ('__' + 'EMPLOYEE_EMAIL_ADDRESS' + '__')
$unresolvedEmployeeFullNameToken = ('__' + 'EMPLOYEE_FULL_NAME' + '__')

function Test-InvalidCompanyName {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return $true
    }

    $trimmed = $Value.Trim()
    if ([string]::Equals($trimmed, $unresolvedCompanyNameToken, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ([string]::Equals($trimmed, "company_name", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($trimmed.StartsWith("__", [System.StringComparison]::Ordinal) -and $trimmed.EndsWith("__", [System.StringComparison]::Ordinal)) {
        return $true
    }

    return $false
}

function Test-InvalidEmployeeEmailAddress {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return $true
    }

    $trimmed = $Value.Trim()
    if ([string]::Equals($trimmed, $unresolvedEmployeeEmailAddressToken, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ([string]::Equals($trimmed, 'employee_email_address', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($trimmed.StartsWith('__', [System.StringComparison]::Ordinal) -and $trimmed.EndsWith('__', [System.StringComparison]::Ordinal)) {
        return $true
    }
    if (($trimmed -split '@').Count -lt 2) {
        return $true
    }

    return $false
}

function Test-InvalidEmployeeFullName {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return $true
    }

    $trimmed = $Value.Trim()
    if ([string]::Equals($trimmed, $unresolvedEmployeeFullNameToken, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ([string]::Equals($trimmed, 'employee_full_name', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($trimmed.StartsWith('__', [System.StringComparison]::Ordinal) -and $trimmed.EndsWith('__', [System.StringComparison]::Ordinal)) {
        return $true
    }

    return $false
}

function Get-EmployeeEmailBaseName {
    param([string]$EmailAddress)

    if (Test-InvalidEmployeeEmailAddress -Value $EmailAddress) {
        throw "employee_email_address must be a non-placeholder email address before running 10002-create-shortcuts-public-desktop."
    }

    return [string]($EmailAddress.Trim().Split('@')[0])
}

function ConvertTo-LowerInvariantText {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return ""
    }

    return [string]$Value.Trim().ToLowerInvariant()
}

function ConvertTo-TitleCaseShortcutText {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return ""
    }

    $textInfo = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo
    return [string]$textInfo.ToTitleCase($Value.Trim().ToLowerInvariant())
}

if (Test-InvalidCompanyName -Value $companyName) {
    throw "company_name is required for the Windows business public desktop shortcut flow. Set company_name in .env before running 10002-create-shortcuts-public-desktop."
}
if (Test-InvalidEmployeeEmailAddress -Value $employeeEmailAddress) {
    throw "employee_email_address is required for the Windows public desktop shortcut flow. Set employee_email_address in .env before running 10002-create-shortcuts-public-desktop."
}
if (Test-InvalidEmployeeFullName -Value $employeeFullName) {
    throw "employee_full_name is required for the Windows public desktop shortcut flow. Set employee_full_name in .env before running 10002-create-shortcuts-public-desktop."
}

$companyName = $companyName.Trim()
$employeeEmailAddress = $employeeEmailAddress.Trim()
$employeeFullName = $employeeFullName.Trim()
$employeeEmailBaseName = Get-EmployeeEmailBaseName -EmailAddress $employeeEmailAddress
$companyDisplayName = ConvertTo-TitleCaseShortcutText -Value $companyName
$companyChromeProfileDirectory = ConvertTo-LowerInvariantText -Value $companyName
$employeeEmailBaseName = ConvertTo-LowerInvariantText -Value $employeeEmailBaseName

function Get-ChromeProfileDirectoryForShortcut {
    param(
        [ValidateSet('business','personal')]
        [string]$ProfileKind = 'business'
    )

    if ([string]::Equals([string]$ProfileKind, 'personal', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [string]$employeeEmailBaseName
    }

    return [string]$companyChromeProfileDirectory
}

function Get-ChromeArgsPrefix {
    param(
        [ValidateSet('business','personal')]
        [string]$ProfileKind = 'business',
        [ValidateSet('remote','setup','bank')]
        [string]$Variant = 'remote'
    )

    $profileDirectory = Get-ChromeProfileDirectoryForShortcut -ProfileKind $ProfileKind
    switch ([string]$Variant) {
        'setup' {
            return ('--new-window --start-maximized --no-first-run --no-default-browser-check --user-data-dir="{0}" --profile-directory="{1}"' -f $publicChromeUserDataDir, $profileDirectory)
        }
        'bank' {
            return ('--new-window --start-maximized --profile-directory="{0}"' -f $profileDirectory)
        }
        default {
            return ('--new-window --start-maximized --disable-extensions --disable-default-apps --no-first-run --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --no-default-browser-check --user-data-dir="{0}" --profile-directory="{1}"' -f $publicChromeUserDataDir, $profileDirectory)
        }
    }
}

function Refresh-SessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path -LiteralPath $refreshEnvCmd) {
        cmd.exe /d /c "`"$refreshEnvCmd`"" | Out-Null
    }

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace([string]$userPath)) {
        $env:Path = $machinePath
    }
    else {
        $env:Path = "$machinePath;$userPath"
    }
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

function Resolve-OfficeExecutable {
    param([string]$ExeName)

    if ([string]::IsNullOrWhiteSpace([string]$ExeName)) {
        return ""
    }

    foreach ($root in @(
        "C:\Program Files\Microsoft Office\root\Office16",
        "C:\Program Files (x86)\Microsoft Office\root\Office16",
        "C:\Program Files\Microsoft Office\Office16",
        "C:\Program Files (x86)\Microsoft Office\Office16"
    )) {
        $candidate = Join-Path $root $ExeName
        if (Test-Path -LiteralPath $candidate) {
            return [string]$candidate
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
            if ([string]::IsNullOrWhiteSpace([string]$installLocation)) {
                return $false
            }
            if ([string]::IsNullOrWhiteSpace([string]$pkgName) -and [string]::IsNullOrWhiteSpace([string]$pkgFamily)) {
                return $false
            }

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
        $manifestPath = Join-Path ([string]$package.InstallLocation) "AppxManifest.xml"
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            continue
        }

        try {
            [xml]$manifestXml = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop
            $appNodes = @($manifestXml.SelectNodes("//*[local-name()='Application']"))
            foreach ($appNode in @($appNodes)) {
                $applicationId = [string]$appNode.GetAttribute("Id")
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
            if ([string]::IsNullOrWhiteSpace([string]$installLocation)) {
                return $false
            }
            if ([string]::IsNullOrWhiteSpace([string]$pkgName) -and [string]::IsNullOrWhiteSpace([string]$pkgFamily)) {
                return $false
            }

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

function Resolve-ExistingOrFallbackPath {
    param(
        [string]$PreferredPath,
        [string]$ResolvedPath,
        [string]$FallbackPath
    )

    foreach ($candidate in @($PreferredPath, $ResolvedPath, $FallbackPath)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }

        if ((Test-Path -LiteralPath $candidate) -or [string]::Equals([string]$candidate, [string]$FallbackPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [string]$candidate
        }
    }

    return ""
}

function Resolve-ICloudExecutablePath {
    $resolvedFromPackage = Resolve-AppPackageExecutablePath -NameFragment "icloud" -PackageNameHints @("icloud", "AppleInc.iCloud", "9PKTQ5699M62") -ExecutableName "iCloudHome.exe"
    $resolvedPath = Resolve-ExistingOrFallbackPath -PreferredPath "" -ResolvedPath $resolvedFromPackage -FallbackPath ""
    if (-not [string]::IsNullOrWhiteSpace([string]$resolvedPath)) {
        return [string]$resolvedPath
    }

    foreach ($candidate in @(
        "C:\Program Files\iCloud\iCloudHome.exe",
        "C:\Program Files (x86)\iCloud\iCloudHome.exe",
        $iCloudFallbackPath
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return [string]$candidate
        }
    }

    return [string]$iCloudFallbackPath
}

function Ensure-Directory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace([string]$Path)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Clear-DesktopEntries {
    param([string]$DesktopPath)

    if ([string]::IsNullOrWhiteSpace([string]$DesktopPath) -or -not (Test-Path -LiteralPath $DesktopPath)) {
        return
    }

    Get-ChildItem -LiteralPath $DesktopPath -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            if ($_.PSIsContainer) {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
            }
            else {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
            }

            Write-Host ("user-desktop-entry-removed: {0}" -f $_.FullName)
        }
        catch {
            throw ("Failed to remove user desktop entry '{0}': {1}" -f $_.FullName, $_.Exception.Message)
        }
    }
}

function Get-ShortcutDetails {
    param([string]$ShortcutPath)

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    return [pscustomobject]@{
        TargetPath = [string]$shortcut.TargetPath
        Arguments = [string]$shortcut.Arguments
        WorkingDirectory = [string]$shortcut.WorkingDirectory
        IconLocation = [string]$shortcut.IconLocation
        Hotkey = [string]$shortcut.Hotkey
        WindowStyle = [int]$shortcut.WindowStyle
    }
}

function Set-ShortcutRunAsAdministratorFlag {
    param(
        [string]$ShortcutPath,
        [bool]$Enabled = $true
    )

    if ([string]::IsNullOrWhiteSpace([string]$ShortcutPath) -or -not (Test-Path -LiteralPath $ShortcutPath)) {
        throw ("Shortcut path was not found for admin flag patching: {0}" -f $ShortcutPath)
    }

    $bytes = [System.IO.File]::ReadAllBytes($ShortcutPath)
    if ($bytes.Length -lt 0x18) {
        throw ("Shortcut header is too small for admin flag patching: {0}" -f $ShortcutPath)
    }

    $linkFlags = [System.BitConverter]::ToUInt32($bytes, 0x14)
    if ($Enabled) {
        $linkFlags = $linkFlags -bor [uint32]$shortcutRunAsAdminFlag
    }
    else {
        $linkFlags = $linkFlags -band (-bnot [uint32]$shortcutRunAsAdminFlag)
    }

    $flagBytes = [System.BitConverter]::GetBytes([uint32]$linkFlags)
    [System.Array]::Copy($flagBytes, 0, $bytes, 0x14, $flagBytes.Length)
    [System.IO.File]::WriteAllBytes($ShortcutPath, $bytes)
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

function Test-ShortcutValueMatch {
    param(
        [string]$ExpectedValue,
        [string]$ActualValue
    )

    return [string]::Equals([string]$ExpectedValue, [string]$ActualValue, [System.StringComparison]::OrdinalIgnoreCase)
}

function Normalize-ShortcutHotkey {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return ""
    }

    $parts = @(
        $Value -split '\+' |
        ForEach-Object { [string]$_ } |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    if (-not $parts -or $parts.Count -eq 0) {
        return ""
    }

    $modifierOrder = @('CTRL', 'ALT', 'SHIFT')
    $normalizedParts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($modifier in $modifierOrder) {
        foreach ($part in $parts) {
            if ([string]::Equals($part, $modifier, [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$normalizedParts.Add($modifier)
            }
        }
    }

    foreach ($part in $parts) {
        $upperPart = $part.ToUpperInvariant()
        if ($modifierOrder -contains $upperPart) {
            continue
        }

        [void]$normalizedParts.Add($upperPart)
    }

    return ($normalizedParts -join '+')
}

function New-ShortcutSpec {
    param(
        [string]$Name,
        [string]$TargetPath,
        [string]$Arguments = "",
        [string]$WorkingDirectory = "",
        [string]$IconLocation = "",
        [string]$Hotkey = "",
        [int]$ShowCmd = 3,
        [bool]$RunAsAdmin = $true,
        [bool]$AllowMissingTargetPath = $false,
        [string]$ValidationKind = "generic",
        [string]$ProfileKind = "",
        [string]$DestinationUrl = "",
        [string[]]$CleanupAliases = @(),
        [bool]$CleanupMatchTargetOnly = $false,
        [bool]$CleanupAliasMatchByNameOnly = $false
    )

    return [pscustomobject]@{
        Name = [string]$Name
        TargetPath = [string]$TargetPath
        Arguments = [string]$Arguments
        WorkingDirectory = [string]$WorkingDirectory
        IconLocation = [string]$IconLocation
        Hotkey = [string]$Hotkey
        ShowCmd = [int]$ShowCmd
        RunAsAdmin = [bool]$RunAsAdmin
        AllowMissingTargetPath = [bool]$AllowMissingTargetPath
        ValidationKind = [string]$ValidationKind
        ProfileKind = [string]$ProfileKind
        DestinationUrl = [string]$DestinationUrl
        CleanupAliases = @($CleanupAliases | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        CleanupMatchTargetOnly = [bool]$CleanupMatchTargetOnly
        CleanupAliasMatchByNameOnly = [bool]$CleanupAliasMatchByNameOnly
    }
}

function New-ShortcutFromSpec {
    param(
        [pscustomobject]$Spec,
        [string]$OutputDirectory
    )

    if ($null -eq $Spec) {
        throw "Shortcut spec is required."
    }

    $name = [string]$Spec.Name
    $targetPath = [string]$Spec.TargetPath
    if ([string]::IsNullOrWhiteSpace([string]$name)) {
        throw "Shortcut name is empty."
    }
    if ([string]::IsNullOrWhiteSpace([string]$targetPath)) {
        throw ("Shortcut target is empty for '{0}'." -f $name)
    }
    if (-not [bool]$Spec.AllowMissingTargetPath -and -not (Test-Path -LiteralPath $targetPath)) {
        throw ("Shortcut target was not found for '{0}': {1}" -f $name, $targetPath)
    }

    Ensure-Directory -Path $OutputDirectory
    $shortcutPath = Join-Path $OutputDirectory ($name + ".lnk")
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $targetPath
    $shortcut.Arguments = [string]$Spec.Arguments
    $expectedWorkingDirectory = ""
    if (-not [string]::IsNullOrWhiteSpace([string]$Spec.WorkingDirectory)) {
        $expectedWorkingDirectory = [string]$Spec.WorkingDirectory
        $shortcut.WorkingDirectory = $expectedWorkingDirectory
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string](Split-Path -Path $targetPath -Parent))) {
        $expectedWorkingDirectory = [string](Split-Path -Path $targetPath -Parent)
        $shortcut.WorkingDirectory = $expectedWorkingDirectory
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Spec.IconLocation)) {
        $shortcut.IconLocation = [string]$Spec.IconLocation
    }
    else {
        $shortcut.IconLocation = ("{0},0" -f $targetPath)
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Spec.Hotkey)) {
        $shortcut.Hotkey = [string]$Spec.Hotkey
    }
    $shortcut.WindowStyle = [int]$Spec.ShowCmd
    $shortcut.Save()

    if ([bool]$Spec.RunAsAdmin) {
        Set-ShortcutRunAsAdministratorFlag -ShortcutPath $shortcutPath -Enabled $true
    }

    $writtenDetails = Get-ShortcutDetails -ShortcutPath $shortcutPath
    if (-not (Test-ShortcutValueMatch -ExpectedValue $targetPath -ActualValue ([string]$writtenDetails.TargetPath))) {
        throw ("Shortcut target validation failed for '{0}'." -f $name)
    }
    if (-not (Test-ShortcutValueMatch -ExpectedValue ([string]$Spec.Arguments) -ActualValue ([string]$writtenDetails.Arguments))) {
        throw ("Shortcut arguments validation failed for '{0}'." -f $name)
    }
    if (-not (Test-ShortcutValueMatch -ExpectedValue $expectedWorkingDirectory -ActualValue ([string]$writtenDetails.WorkingDirectory))) {
        throw ("Shortcut working directory validation failed for '{0}'." -f $name)
    }
    if ((Normalize-ShortcutHotkey -Value ([string]$Spec.Hotkey)) -ne (Normalize-ShortcutHotkey -Value ([string]$writtenDetails.Hotkey))) {
        throw ("Shortcut hotkey validation failed for '{0}'." -f $name)
    }
    if ([int]$writtenDetails.WindowStyle -ne [int]$Spec.ShowCmd) {
        throw ("Shortcut window style validation failed for '{0}'." -f $name)
    }
    if ([bool]$Spec.RunAsAdmin -ne (Get-ShortcutRunAsAdministratorFlag -ShortcutPath $shortcutPath)) {
        throw ("Shortcut admin flag validation failed for '{0}'." -f $name)
    }

    Write-Host ("shortcut-ok: {0}" -f $name)
}

function Add-Spec {
    param(
        [System.Collections.Generic.List[object]]$List,
        [pscustomobject]$Spec
    )

    if ($null -eq $List -or $null -eq $Spec) {
        return
    }

    [void]$List.Add($Spec)
}

function New-ChromeShortcutSpec {
    param(
        [string]$Name,
        [string]$Url,
        [ValidateSet('business','personal')]
        [string]$ProfileKind = 'business',
        [ValidateSet('remote','setup','bank')]
        [string]$Variant = 'remote',
        [string[]]$CleanupAliases = @()
    )

    return (New-ShortcutSpec `
        -Name $Name `
        -TargetPath $chromeTarget `
        -Arguments ((Get-ChromeArgsPrefix -ProfileKind $ProfileKind -Variant $Variant) + ' "' + [string]$Url + '"') `
        -IconLocation ($chromeTarget + ",0") `
        -AllowMissingTargetPath $true `
        -ValidationKind ("chrome-" + [string]$Variant) `
        -ProfileKind $ProfileKind `
        -DestinationUrl ([string]$Url) `
        -CleanupAliases $CleanupAliases)
}

function Get-NormalizedShortcutNameKey {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return ""
    }

    return ([regex]::Replace($Value.Trim().ToLowerInvariant(), '[^a-z0-9]+', ''))
}

function Get-NormalizedShortcutPath {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return ""
    }

    return ([string]$Value).Trim().Trim('"').ToLowerInvariant()
}

function Get-NormalizedShortcutUrl {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return ""
    }

    return [string]$Value.Trim().Trim('"').ToLowerInvariant()
}

function Get-ShortcutUrlFromArguments {
    param([string]$Arguments)

    if ([string]::IsNullOrWhiteSpace([string]$Arguments)) {
        return ""
    }

    $match = [regex]::Match([string]$Arguments, '(?i)"((?:https?://|chrome://)[^"]+)"')
    if (-not $match.Success) {
        return ""
    }

    return [string]$match.Groups[1].Value
}

function Test-ShortcutDetailsMatchManagedSpec {
    param(
        [pscustomobject]$Details,
        [string]$ShortcutBaseName,
        [pscustomobject]$Spec
    )

    if ($null -eq $Details -or $null -eq $Spec) {
        return $false
    }

    $existingNameKey = Get-NormalizedShortcutNameKey -Value $ShortcutBaseName
    $managedNameKey = Get-NormalizedShortcutNameKey -Value ([string]$Spec.Name)
    if (-not [string]::IsNullOrWhiteSpace([string]$managedNameKey) -and [string]::Equals($existingNameKey, $managedNameKey, [System.StringComparison]::Ordinal)) {
        return $true
    }

    $existingTargetPath = Get-NormalizedShortcutPath -Value ([string]$Details.TargetPath)
    $managedTargetPath = Get-NormalizedShortcutPath -Value ([string]$Spec.TargetPath)
    $existingArguments = [string]$Details.Arguments
    $managedArguments = [string]$Spec.Arguments
    $normalizedExistingUrl = Get-NormalizedShortcutUrl -Value (Get-ShortcutUrlFromArguments -Arguments $existingArguments)
    $normalizedManagedUrl = Get-NormalizedShortcutUrl -Value ([string]$Spec.DestinationUrl)

    foreach ($cleanupAlias in @($Spec.CleanupAliases)) {
        if (-not [string]::Equals($existingNameKey, (Get-NormalizedShortcutNameKey -Value ([string]$cleanupAlias)), [System.StringComparison]::Ordinal)) {
            continue
        }

        if ([bool]$Spec.CleanupAliasMatchByNameOnly) {
            return $true
        }

        if ([string]::Equals($existingTargetPath, $managedTargetPath, [System.StringComparison]::Ordinal)) {
            return $true
        }

        if (($Spec.ValidationKind -like 'chrome-*') -and [string]::Equals($existingTargetPath, (Get-NormalizedShortcutPath -Value $chromeTarget), [System.StringComparison]::Ordinal)) {
            return $true
        }
    }

    if ($Spec.ValidationKind -like 'chrome-*') {
        if ([string]::Equals($existingTargetPath, (Get-NormalizedShortcutPath -Value $chromeTarget), [System.StringComparison]::Ordinal) -and
            -not [string]::IsNullOrWhiteSpace([string]$normalizedExistingUrl) -and
            [string]::Equals($normalizedExistingUrl, $normalizedManagedUrl, [System.StringComparison]::Ordinal)) {
            return $true
        }

        return $false
    }

    if ([bool]$Spec.CleanupMatchTargetOnly -and
        -not [string]::IsNullOrWhiteSpace([string]$managedTargetPath) -and
        [string]::Equals($existingTargetPath, $managedTargetPath, [System.StringComparison]::Ordinal)) {
        return $true
    }

    if (($Spec.ValidationKind -in @('store-appid', 'store-deeplink', 'explorer-shell')) -and
        [string]::Equals($existingTargetPath, $managedTargetPath, [System.StringComparison]::Ordinal) -and
        [string]::Equals(([string]$existingArguments).Trim(), ([string]$managedArguments).Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return $false
}

function Find-ManagedShortcutSpecByName {
    param(
        [object[]]$Specs,
        [string]$ShortcutBaseName
    )

    $shortcutNameKey = Get-NormalizedShortcutNameKey -Value $ShortcutBaseName
    foreach ($spec in @($Specs)) {
        if ($null -eq $spec) {
            continue
        }

        $specNameKey = Get-NormalizedShortcutNameKey -Value ([string]$spec.Name)
        if ([string]::Equals($shortcutNameKey, $specNameKey, [System.StringComparison]::Ordinal)) {
            return $spec
        }
    }

    return $null
}

function Find-ManagedShortcutSpecByDetails {
    param(
        [object[]]$Specs,
        [pscustomobject]$Details,
        [string]$ShortcutBaseName
    )

    foreach ($spec in @($Specs)) {
        if ($null -eq $spec) {
            continue
        }

        if (Test-ShortcutDetailsMatchManagedSpec -Details $Details -ShortcutBaseName $ShortcutBaseName -Spec $spec) {
            return $spec
        }
    }

    return $null
}

function Test-PublicDesktopAlreadyNormalized {
    param(
        [string]$PublicDesktopPath,
        [object[]]$Specs
    )

    foreach ($spec in @($Specs)) {
        if ($null -eq $spec) {
            continue
        }

        $managedShortcutPath = Join-Path $PublicDesktopPath (([string]$spec.Name) + '.lnk')
        if (-not (Test-Path -LiteralPath $managedShortcutPath)) {
            return $false
        }

        try {
            $managedDetails = Get-ShortcutDetails -ShortcutPath $managedShortcutPath
        }
        catch {
            return $false
        }

        if (-not (Test-ShortcutDetailsMatchManagedSpec -Details $managedDetails -ShortcutBaseName ([string]$spec.Name) -Spec $spec)) {
            return $false
        }
    }

    foreach ($existingShortcutFile in @(Get-ChildItem -LiteralPath $PublicDesktopPath -Filter "*.lnk" -File -ErrorAction SilentlyContinue)) {
        $shortcutBaseName = [System.IO.Path]::GetFileNameWithoutExtension([string]$existingShortcutFile.Name)
        $matchedSpec = Find-ManagedShortcutSpecByName -Specs $Specs -ShortcutBaseName $shortcutBaseName
        if ($null -ne $matchedSpec) {
            continue
        }

        try {
            $existingDetails = Get-ShortcutDetails -ShortcutPath ([string]$existingShortcutFile.FullName)
        }
        catch {
            return $false
        }

        if ($null -ne (Find-ManagedShortcutSpecByDetails -Specs $Specs -Details $existingDetails -ShortcutBaseName $shortcutBaseName)) {
            return $false
        }
    }

    return $true
}

function Resolve-IconLocation {
    param(
        [string]$PreferredPath,
        [string]$FallbackPath
    )

    $iconTarget = [string]$FallbackPath
    if (-not [string]::IsNullOrWhiteSpace([string]$PreferredPath)) {
        $iconTarget = [string]$PreferredPath
    }

    return ($iconTarget + ",0")
}

Refresh-SessionPath
Ensure-Directory -Path $publicDesktop
Ensure-Directory -Path $publicChromeUserDataDir

$explorerExe = Resolve-CommandPath -CommandName "explorer.exe" -FallbackCandidates @("C:\Windows\explorer.exe")
$chromeExe = Resolve-CommandPath -CommandName "chrome.exe" -FallbackCandidates @(
    "C:\Program Files\Google\Chrome\Application\chrome.exe",
    "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
)
$chromeTarget = Resolve-ExistingOrFallbackPath -PreferredPath "C:\Program Files\Google\Chrome\Application\chrome.exe" -ResolvedPath $chromeExe -FallbackPath "C:\Program Files\Google\Chrome\Application\chrome.exe"
$chromeSyncSetupCommand = ('/c start "" "{0}" --new-window --start-maximized --user-data-dir="{1}" --profile-directory={2} "chrome://settings/syncSetup"' -f $chromeTarget, $publicChromeUserDataDir, $companyChromeProfileDirectory)
$controlExe = Resolve-CommandPath -CommandName "control.exe" -FallbackCandidates @("C:\Windows\System32\control.exe")
$cmdExe = Resolve-CommandPath -CommandName "cmd.exe" -FallbackCandidates @("C:\Windows\System32\cmd.exe")
$powershellExe = Resolve-CommandPath -CommandName "powershell.exe" -FallbackCandidates @("C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe")
$pwshExe = Resolve-CommandPath -CommandName "pwsh.exe" -FallbackCandidates @("C:\Program Files\PowerShell\7\pwsh.exe")
$dockerDesktopExe = Resolve-ExistingOrFallbackPath -PreferredPath "C:\Program Files\Docker\Docker\Docker Desktop.exe" -ResolvedPath (Resolve-CommandPath -CommandName "Docker Desktop.exe" -FallbackCandidates @("C:\Program Files\Docker\Docker\Docker Desktop.exe")) -FallbackPath "C:\Program Files\Docker\Docker\Docker Desktop.exe"
$gitBashExe = Resolve-CommandPath -CommandName "git-bash.exe" -FallbackCandidates @("C:\Program Files\Git\git-bash.exe")
$pythonExe = Resolve-CommandPath -CommandName "python.exe" -FallbackCandidates @("C:\Python312\python.exe")
$nodeExe = Resolve-CommandPath -CommandName "node.exe" -FallbackCandidates @("C:\Program Files\nodejs\node.exe")
$rcloneExe = Resolve-CommandPath -CommandName "rclone.exe" -FallbackCandidates @(
    "C:\ProgramData\chocolatey\bin\rclone.exe",
    "C:\Program Files\rclone\rclone.exe"
)
$wslExe = Resolve-CommandPath -CommandName "wsl.exe" -FallbackCandidates @("C:\Windows\System32\wsl.exe")
$dockerExe = Resolve-CommandPath -CommandName "docker.exe" -FallbackCandidates @("C:\Program Files\Docker\Docker\resources\bin\docker.exe")
$azExe = Resolve-CommandPath -CommandName "az.cmd" -FallbackCandidates @(
    "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",
    "C:\ProgramData\chocolatey\bin\az.cmd"
)
$azdExe = Resolve-CommandPath -CommandName "azd.exe" -FallbackCandidates @("C:\Program Files\Azure Developer CLI\azd.exe")
$ghExe = Resolve-CommandPath -CommandName "gh.exe" -FallbackCandidates @("C:\Program Files\GitHub CLI\gh.exe")
$ffmpegExe = Resolve-CommandPath -CommandName "ffmpeg.exe" -FallbackCandidates @("C:\ProgramData\chocolatey\bin\ffmpeg.exe")
$sevenZipExe = Resolve-CommandPath -CommandName "7z.exe" -FallbackCandidates @(
    "C:\ProgramData\chocolatey\bin\7z.exe",
    "C:\Program Files\7-Zip\7z.exe",
    "C:\Program Files\7-Zip\7zFM.exe"
)
$processExplorerExe = Resolve-CommandPath -CommandName "procexp64.exe" -FallbackCandidates @(
    "C:\ProgramData\chocolatey\lib\sysinternals\tools\procexp64.exe",
    "C:\ProgramData\chocolatey\bin\procexp64.exe",
    "C:\ProgramData\chocolatey\bin\procexp.exe",
    "C:\Windows\System32\procexp64.exe"
)
$ioUnlockerExe = Resolve-CommandPath -CommandName "IObitUnlocker.exe" -FallbackCandidates @(
    "C:\Program Files (x86)\IObit\IObit Unlocker\IObitUnlocker.exe",
    "C:\Program Files\IObit\IObit Unlocker\IObitUnlocker.exe",
    "C:\ProgramData\chocolatey\bin\IObitUnlocker.exe"
)
$anyDeskExe = Resolve-ExistingOrFallbackPath -PreferredPath "C:\Program Files (x86)\AnyDesk\AnyDesk.exe" -ResolvedPath (Resolve-CommandPath -CommandName "AnyDesk.exe" -FallbackCandidates @(
    "C:\Program Files (x86)\AnyDesk\AnyDesk.exe",
    "C:\Program Files\AnyDesk\AnyDesk.exe"
)) -FallbackPath "C:\Program Files (x86)\AnyDesk\AnyDesk.exe"
$windscribeExe = Resolve-CommandPath -CommandName "Windscribe.exe" -FallbackCandidates @(
    "C:\Program Files\Windscribe\Windscribe.exe",
    "C:\Program Files (x86)\Windscribe\Windscribe.exe"
)
$vs2022CommunityExe = "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\devenv.exe"
$vsCodeCmdPath = Resolve-ExistingOrFallbackPath -PreferredPath ("%LocalAppData%\Programs\Microsoft VS Code\bin\code.cmd") -ResolvedPath (Resolve-CommandPath -CommandName "code.cmd" -FallbackCandidates @(
    ("C:\Users\{0}\AppData\Local\Programs\Microsoft VS Code\bin\code.cmd" -f $managerUser),
    ("C:\Users\{0}\AppData\Local\Programs\Microsoft VS Code\bin\code.cmd" -f $assistantUser)
)) -FallbackPath ("%LocalAppData%\Programs\Microsoft VS Code\bin\code.cmd")
$codexCmdPath = Resolve-ExistingOrFallbackPath -PreferredPath ("C:\Users\{0}\AppData\Roaming\npm\codex.cmd" -f $managerUser) -ResolvedPath (Resolve-CommandPath -CommandName "codex.cmd" -FallbackCandidates @(
    ("C:\Users\{0}\AppData\Roaming\npm\codex.cmd" -f $managerUser),
    ("C:\Users\{0}\AppData\Roaming\npm\codex.cmd" -f $assistantUser),
    "C:\Program Files\nodejs\codex.cmd"
)) -FallbackPath ("C:\Users\{0}\AppData\Roaming\npm\codex.cmd" -f $managerUser)
$geminiCmdPath = Resolve-ExistingOrFallbackPath -PreferredPath ("C:\Users\{0}\AppData\Roaming\npm\gemini.cmd" -f $managerUser) -ResolvedPath (Resolve-CommandPath -CommandName "gemini.cmd" -FallbackCandidates @(
    ("C:\Users\{0}\AppData\Roaming\npm\gemini.cmd" -f $managerUser),
    ("C:\Users\{0}\AppData\Roaming\npm\gemini.cmd" -f $assistantUser),
    "C:\Program Files\nodejs\gemini.cmd"
)) -FallbackPath ("C:\Users\{0}\AppData\Roaming\npm\gemini.cmd" -f $managerUser)
$itunesExe = Resolve-ExistingOrFallbackPath -PreferredPath "C:\Program Files\iTunes\iTunes.exe" -ResolvedPath (Resolve-CommandPath -CommandName "iTunes.exe" -FallbackCandidates @(
    "C:\Program Files\iTunes\iTunes.exe",
    "C:\Program Files (x86)\iTunes\iTunes.exe"
)) -FallbackPath "C:\Program Files\iTunes\iTunes.exe"
$nvdaExe = "C:\Program Files (x86)\NVDA\nvda.exe"
$edgeExe = Resolve-ExistingOrFallbackPath -PreferredPath "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" -ResolvedPath (Resolve-CommandPath -CommandName "msedge.exe" -FallbackCandidates @(
    "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
)) -FallbackPath "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
$vlcExe = Resolve-ExistingOrFallbackPath -PreferredPath "C:\Program Files\VideoLAN\VLC\vlc.exe" -ResolvedPath (Resolve-CommandPath -CommandName "vlc.exe" -FallbackCandidates @(
    "C:\Program Files\VideoLAN\VLC\vlc.exe",
    "C:\Program Files (x86)\VideoLAN\VLC\vlc.exe"
)) -FallbackPath "C:\Program Files\VideoLAN\VLC\vlc.exe"
$oneDriveExe = Resolve-ExistingOrFallbackPath -PreferredPath "C:\Program Files\Microsoft OneDrive\OneDrive.exe" -ResolvedPath (Resolve-CommandPath -CommandName "OneDrive.exe" -FallbackCandidates @(
    "C:\Program Files\Microsoft OneDrive\OneDrive.exe",
    ("C:\Users\{0}\AppData\Local\Microsoft\OneDrive\OneDrive.exe" -f $managerUser),
    ("C:\Users\{0}\AppData\Local\Microsoft\OneDrive\OneDrive.exe" -f $assistantUser)
)) -FallbackPath "C:\Program Files\Microsoft OneDrive\OneDrive.exe"
$googleDriveResolvedExe = Resolve-CommandPath -CommandName "GoogleDriveFS.exe" -FallbackCandidates @("C:\Program Files\Google\Drive File Stream\GoogleDriveFS.exe")
if ([string]::IsNullOrWhiteSpace([string]$googleDriveResolvedExe)) {
    $googleDriveResolvedExe = Resolve-ExecutableUnderDirectory -RootPaths @("C:\Program Files\Google\Drive File Stream") -ExecutableName "GoogleDriveFS.exe"
}
$googleDriveExe = Resolve-ExistingOrFallbackPath -PreferredPath "C:\Program Files\Google\Drive File Stream\GoogleDriveFS.exe" -ResolvedPath $googleDriveResolvedExe -FallbackPath "C:\Program Files\Google\Drive File Stream\GoogleDriveFS.exe"
$iCloudExe = Resolve-ICloudExecutablePath

$teamsAppId = Resolve-StoreAppId -NameFragment "teams" -PackageNameHints @("teams")
$windscribeAppId = Resolve-StoreAppId -NameFragment "windscribe" -PackageNameHints @("windscribe")
$beMyEyesAppId = Resolve-StoreAppId -NameFragment "be my eyes" -PackageNameHints @("be my eyes", $beMyEyesStoreProductId)
$codexAppResolvedExe = Resolve-AppPackageExecutablePath -NameFragment "codex" -PackageNameHints @("OpenAI.Codex", "2p2nqsd0c76g0") -ExecutableName "Codex.exe"
$whatsAppRootExe = Resolve-AppPackageExecutablePath -NameFragment "whatsapp" -PackageNameHints @("whatsapp", "5319275A.WhatsAppDesktop") -ExecutableName "WhatsApp.Root.exe"

$outlookExe = Resolve-OfficeExecutable -ExeName "OUTLOOK.EXE"
$wordExe = Resolve-OfficeExecutable -ExeName "WINWORD.EXE"
$excelExe = Resolve-OfficeExecutable -ExeName "EXCEL.EXE"
$powerPointExe = Resolve-OfficeExecutable -ExeName "POWERPNT.EXE"
$oneNoteExe = Resolve-OfficeExecutable -ExeName "ONENOTE.EXE"

$codexAppExe = if (Test-Path -LiteralPath $codexAppFallbackPath) {
    [string]$codexAppFallbackPath
}
elseif (-not [string]::IsNullOrWhiteSpace([string]$codexAppResolvedExe) -and (Test-Path -LiteralPath $codexAppResolvedExe)) {
    [string]$codexAppResolvedExe
}
else {
    [string]$codexAppFallbackPath
}
$whatsAppBusinessTarget = Resolve-ExistingOrFallbackPath -PreferredPath $whatsAppRootExe -ResolvedPath $whatsAppRootExe -FallbackPath $whatsAppFallbackPath
$sevenZipCliPath = Resolve-ExistingOrFallbackPath -PreferredPath "C:\ProgramData\chocolatey\bin\7z.exe" -ResolvedPath $sevenZipExe -FallbackPath "C:\ProgramData\chocolatey\bin\7z.exe"

$shortcutSpecs = New-Object 'System.Collections.Generic.List[object]'

$socialWebShortcuts = @(
    @{ Name = "s1LinkedIn Business"; Url = "https://tr.linkedin.com/company/exampleorg"; ProfileKind = "business" },
    @{ Name = "s2LinkedIn Personal"; Url = "https://linkedin.com/in/<social-handle>"; ProfileKind = "personal" },
    @{ Name = "s3YouTube Business"; Url = "https://www.youtube.com/@exampleorg"; ProfileKind = "business" },
    @{ Name = "s4YouTube Personal"; Url = "https://www.youtube.com/@hasanozdemir8"; ProfileKind = "personal" },
    @{ Name = "s5GitHub Business"; Url = "https://github.com/exampleorg"; ProfileKind = "business" },
    @{ Name = "s6GitHub Personal"; Url = "https://github.com/"; ProfileKind = "personal" },
    @{ Name = "s7TikTok Business"; Url = "https://www.tiktok.com/@exampleorg"; ProfileKind = "business" },
    @{ Name = "s8TikTok Personal"; Url = "https://www.tiktok.com/@exampleorg"; ProfileKind = "personal" },
    @{ Name = "s9Instagram Business"; Url = "https://instagram.com/exampleorg"; ProfileKind = "business" },
    @{ Name = "s10Instagram Personal"; Url = "https://instagram.com/hasanozdemirnet"; ProfileKind = "personal" },
    @{ Name = "s11Facebook Business"; Url = "https://www.facebook.com/people/exampleorg-Teknoloji/61577930401447"; ProfileKind = "business" },
    @{ Name = "s12Facebook Personal"; Url = "https://facebook.com/ozdemirhasan"; ProfileKind = "personal" },
    @{ Name = "s13X-Twitter Business"; Url = "https://x.com/exampleorg"; ProfileKind = "business" },
    @{ Name = "s14X-Twitter Personal"; Url = "https://x.com/hasanozdemirnet"; ProfileKind = "personal" },
    @{ Name = ("s15{0} Web" -f $companyDisplayName); Url = "https://www.exampleorg.com"; ProfileKind = "business" },
    @{ Name = ("s16{0} Blog" -f $companyDisplayName); Url = "https://www.exampleorg.com/blog"; ProfileKind = "business" },
    @{ Name = "s17SnapChat Business"; Url = "https://www.snapchat.com/@exampleorg"; ProfileKind = "business" },
    @{ Name = "s18NextSosyal Business"; Url = "https://sosyal.teknofest.app/@exampleorg"; ProfileKind = "business" }
)
$bankShortcuts = @(
    @{ Name = "b1GarantiBank Business"; Url = "https://sube.garantibbva.com.tr/isube/login/login/passwordentrycorporate-tr"; ProfileKind = "business" },
    @{ Name = "b2GarantiBank Personal"; Url = "https://sube.garantibbva.com.tr/isube/login/login/passwordentrypersonal-tr"; ProfileKind = "personal" },
    @{ Name = "b3QnbBank Business"; Url = "https://internetsubesi.qnb.com.tr/Login/LoginPage.aspx?FromDK=true"; ProfileKind = "business" },
    @{ Name = "b4QnbBank Personal"; Url = "https://internetsubesi.qnb.com.tr/Login/LoginPage.aspx"; ProfileKind = "personal" },
    @{ Name = "b5AktifBank Business"; Url = "https://kurumsal.aktifbank.com.tr/default.aspx?lang=tr-TR"; ProfileKind = "business" },
    @{ Name = "b6AktifBank Personal"; Url = "https://online.aktifbank.com.tr/default.aspx?lang=tr-TR"; ProfileKind = "personal" },
    @{ Name = "b7ZiraatBank Business"; Url = "https://kurumsal.ziraatbank.com.tr/Transactions/Login/FirstLogin.aspx?customertype=crp"; ProfileKind = "business" },
    @{ Name = "b8ZiraatBank Personal"; Url = "https://bireysel.ziraatbank.com.tr/Transactions/Login/FirstLogin.aspx"; ProfileKind = "personal" }
)
$developerWebShortcuts = @(
    @{ Name = "g1Apple Developer"; Url = "https://developer.apple.com/account" },
    @{ Name = "g2Google Developer"; Url = "https://play.google.com/console/signin" },
    @{ Name = "g3Microsoft Developer"; Url = "https://aka.ms/submitwindowsapp" },
    @{ Name = "g4Azure Portal"; Url = "https://portal.azure.com" }
)
$marketplaceWebShortcuts = @(
    @{ Name = "m1Digital Tax Office"; Url = "https://dijital.gib.gov.tr/portal/login"; ProfileKind = "business" },
    @{ Name = "r1Sahibinden Business"; Url = "https://secure.sahibinden.com/giris"; ProfileKind = "business" },
    @{ Name = "r2Sahibinden Personal"; Url = "https://www.sahibinden.com"; ProfileKind = "personal" },
    @{ Name = "r3Letgo Business"; Url = "https://www.letgo.com"; ProfileKind = "business" },
    @{ Name = "r4Letgo Personal"; Url = "https://www.letgo.com"; ProfileKind = "personal" },
    @{ Name = "r5Trendyol Business"; Url = "https://partner.trendyol.com"; ProfileKind = "business" },
    @{ Name = "r6Trendyol Personal"; Url = "https://www.trendyol.com/uyelik"; ProfileKind = "personal" },
    @{ Name = "r7Amazon TR Business"; Url = "https://sellercentral.amazon.com.tr"; ProfileKind = "business" },
    @{ Name = "r8Amazon TR Personal"; Url = "https://www.amazon.com.tr/ap/signin"; ProfileKind = "personal" },
    @{ Name = "r9HepsiBurada Business"; Url = "https://merchant.hepsiburada.com"; ProfileKind = "business" },
    @{ Name = "r10HepsiBurada Personal"; Url = "https://giris.hepsiburada.com"; ProfileKind = "personal" },
    @{ Name = "r11N11 Business"; Url = "https://so.n11.com"; ProfileKind = "business" },
    @{ Name = "r12N11 Personal"; Url = "https://www.n11.com/giris-yap"; ProfileKind = "personal" },
    @{ Name = "r13ÇiçekSepeti Business"; Url = "https://seller.ciceksepeti.com/giris"; ProfileKind = "business" },
    @{ Name = "r14ÇiçekSepeti Personal"; Url = "https://www.ciceksepeti.com/uye-girisi"; ProfileKind = "personal" },
    @{ Name = "r15Pazarama Business"; Url = "https://isortagim.pazarama.com"; ProfileKind = "business" },
    @{ Name = "r16Pazarama Personal"; Url = "https://account.pazarama.com/giris"; ProfileKind = "personal" },
    @{ Name = "r17PTTAVM Business"; Url = "https://merchant.pttavm.com/magaza-giris"; ProfileKind = "business" },
    @{ Name = "r18PTTAVM Personal"; Url = "https://www.pttavm.com"; ProfileKind = "personal" },
    @{ Name = "r19Ozon Business"; Url = "https://seller.ozon.ru/app/registration/signin?locale=en"; ProfileKind = "business" },
    @{ Name = "r20Ozon Personal"; Url = "https://www-ozon-ru.translate.goog/?_x_tr_sl=ru&_x_tr_tl=en&_x_tr_hl=en&_x_tr_hist=true"; ProfileKind = "personal" },
    @{ Name = "r21Getir Business"; Url = "https://panel.getircarsi.com/login"; ProfileKind = "business" },
    @{ Name = "r22Getir Personal"; Url = "https://getir.com"; ProfileKind = "personal" }
)
$quickAccessWebShortcuts = @(
    @{ Name = "q1SourTimes"; Url = "https://www.eksisozluk.com"; ProfileKind = "business" },
    @{ Name = "q2Spotify"; Url = "https://accounts.spotify.com/en/login?continue=https%3A%2F%2Fopen.spotify.com" },
    @{ Name = "q3Netflix"; Url = "https://www.netflix.com/tr-en/login" },
    @{ Name = "q4eGovernment"; Url = "https://www.turkiye.gov.tr" },
    @{ Name = "q5Apple Account"; Url = "https://account.apple.com/sign-in" },
    @{ Name = "q6AJet Flights"; Url = "https://ajet.com" },
    @{ Name = "q7TCDD Train"; Url = "https://ebilet.tcddtasimacilik.gov.tr" },
    @{ Name = "q8OBilet Bus"; Url = "https://www.obilet.com/?giris" }
)

Add-Spec -List $shortcutSpecs -Spec (New-ChromeShortcutSpec -Name "a1ChatGPT Web" -Url "https://chatgpt.com" -ProfileKind 'business' -Variant 'remote')
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a2CodexApp" -TargetPath $codexAppExe -AllowMissingTargetPath $true -ValidationKind "app")
if (-not [string]::IsNullOrWhiteSpace([string]$beMyEyesAppId)) {
    Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a3Be My Eyes" -TargetPath $explorerExe -Arguments ("shell:AppsFolder\" + $beMyEyesAppId) -IconLocation ($explorerExe + ",0") -ValidationKind "store-appid")
}
else {
    Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a3Be My Eyes" -TargetPath $explorerExe -Arguments $beMyEyesStoreUri -IconLocation ($explorerExe + ",0") -ValidationKind "store-deeplink")
}
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a4WhatsApp Business" -TargetPath $whatsAppBusinessTarget -AllowMissingTargetPath $true -ValidationKind "app")
Add-Spec -List $shortcutSpecs -Spec (New-ChromeShortcutSpec -Name "a5WhatsApp Personal" -Url "https://web.whatsapp.com" -ProfileKind 'personal' -Variant 'remote')
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a6AnyDesk" -TargetPath $anyDeskExe -AllowMissingTargetPath $true -ValidationKind "app" -CleanupAliases @("AnyDesk") -CleanupMatchTargetOnly $true)
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a7Docker Desktop" -TargetPath $dockerDesktopExe -AllowMissingTargetPath $true -ValidationKind "app")
if (-not [string]::IsNullOrWhiteSpace([string]$windscribeExe)) {
    Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a8WindScribe" -TargetPath $windscribeExe -AllowMissingTargetPath $true -ValidationKind "app" -CleanupAliases @("Windscribe") -CleanupMatchTargetOnly $true)
}
elseif (-not [string]::IsNullOrWhiteSpace([string]$windscribeAppId)) {
    Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a8WindScribe" -TargetPath $explorerExe -Arguments ("shell:AppsFolder\" + $windscribeAppId) -IconLocation ($explorerExe + ",0") -ValidationKind "store-appid" -CleanupAliases @("Windscribe"))
}
else {
    Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a8WindScribe" -TargetPath "C:\Program Files\Windscribe\Windscribe.exe" -AllowMissingTargetPath $true -ValidationKind "app" -CleanupAliases @("Windscribe") -CleanupMatchTargetOnly $true)
}
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a9VLC Player" -TargetPath $vlcExe -AllowMissingTargetPath $true -ValidationKind "app" -CleanupAliases @("VLC media player") -CleanupMatchTargetOnly $true)
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a10NVDA" -TargetPath $nvdaExe -Hotkey "Ctrl+Alt+N" -AllowMissingTargetPath $true -ValidationKind "app" -CleanupAliases @("NVDA") -CleanupAliasMatchByNameOnly $true)
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a11MS Edge" -TargetPath $edgeExe -AllowMissingTargetPath $true -ValidationKind "app" -CleanupAliases @("Microsoft Edge") -CleanupMatchTargetOnly $true)
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a12Itunes" -TargetPath $itunesExe -AllowMissingTargetPath $true -ValidationKind "app" -CleanupAliases @("iTunes") -CleanupMatchTargetOnly $true)

foreach ($spec in @($bankShortcuts)) {
    Add-Spec -List $shortcutSpecs -Spec (New-ChromeShortcutSpec -Name ([string]$spec.Name) -Url ([string]$spec.Url) -ProfileKind ([string]$spec.ProfileKind) -Variant 'bank')
}

Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "c1Cmd" -TargetPath $cmdExe -Arguments "/k cd /d %UserProfile%" -WorkingDirectory "%UserProfile%" -IconLocation ($cmdExe + ",0") -ValidationKind "console")

Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "d1RClone CLI" -TargetPath $cmdExe -Arguments "/k cd /d %UserProfile% & rclone" -WorkingDirectory "%UserProfile%" -IconLocation (Resolve-IconLocation -PreferredPath $rcloneExe -FallbackPath $cmdExe) -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "d2One Drive" -TargetPath $oneDriveExe -AllowMissingTargetPath $true -ValidationKind "app")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "d3Google Drive" -TargetPath $googleDriveExe -AllowMissingTargetPath $true -ValidationKind "app")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "d4ICloud" -TargetPath $iCloudExe -AllowMissingTargetPath $true -ValidationKind "app")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name ("e1Mail {0}" -f $employeeEmailAddress) -TargetPath $cmdExe -Arguments ('/c start outlook.exe /select "outlook:\\{0}\\Inbox"' -f $employeeEmailAddress) -IconLocation (Resolve-IconLocation -PreferredPath $outlookExe -FallbackPath $cmdExe) -AllowMissingTargetPath $true -ValidationKind "app")

foreach ($spec in @($developerWebShortcuts)) {
    Add-Spec -List $shortcutSpecs -Spec (New-ChromeShortcutSpec -Name ([string]$spec.Name) -Url ([string]$spec.Url) -ProfileKind 'business' -Variant 'remote')
}

Add-Spec -List $shortcutSpecs -Spec (New-ChromeShortcutSpec -Name "i1Internet Business" -Url "https://www.exampleorg.com" -ProfileKind 'business' -Variant 'remote' -CleanupAliases @("Google Chrome", "Chrome"))
Add-Spec -List $shortcutSpecs -Spec (New-ChromeShortcutSpec -Name "i2Internet Personal" -Url "https://www.google.com" -ProfileKind 'personal' -Variant 'remote')

Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "k1Codex CLI" -TargetPath $cmdExe -Arguments ('/c cd /d %UserProfile% & start "" "{0}" --enable multi_agent --yolo -s danger-full-access --cd "%UserProfile%" --search' -f $codexCmdPath) -WorkingDirectory "%UserProfile%" -IconLocation ($cmdExe + ",0") -AllowMissingTargetPath $true -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "k2Gemini CLI" -TargetPath $cmdExe -Arguments ('/c cd /d %UserProfile% & start "" "{0}" --screen-reader --yolo' -f $geminiCmdPath) -WorkingDirectory "%UserProfile%" -IconLocation ($cmdExe + ",0") -AllowMissingTargetPath $true -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "k3Github Copilot CLI" -TargetPath $cmdExe -Arguments '/c cd /d %UserProfile% & %UserProfile%\AppData\Roaming\npm\copilot.cmd --screen-reader --yolo --no-ask-user --model claude-haiku-4.5' -WorkingDirectory "%UserProfile%" -IconLocation ($cmdExe + ",0") -AllowMissingTargetPath $true -ValidationKind "console")

foreach ($spec in @($marketplaceWebShortcuts)) {
    Add-Spec -List $shortcutSpecs -Spec (New-ChromeShortcutSpec -Name ([string]$spec.Name) -Url ([string]$spec.Url) -ProfileKind ([string]$spec.ProfileKind) -Variant 'remote')
}

Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "n1Notepad" -TargetPath "C:\Windows\System32\notepad.exe" -ValidationKind "app")

Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "o1Outlook" -TargetPath $outlookExe -AllowMissingTargetPath $true -ValidationKind "office")
if (-not [string]::IsNullOrWhiteSpace([string]$teamsAppId)) {
    Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "o2Teams" -TargetPath $explorerExe -Arguments ("shell:AppsFolder\" + $teamsAppId) -IconLocation ($explorerExe + ",0") -ValidationKind "store-appid")
}
else {
    $teamsExe = Resolve-CommandPath -CommandName "ms-teams.exe" -FallbackCandidates @("C:\Program Files\WindowsApps\MSTeams_8wekyb3d8bbwe\ms-teams.exe")
    Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "o2Teams" -TargetPath $teamsExe -AllowMissingTargetPath $true -ValidationKind "app")
}
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "o3Word" -TargetPath $wordExe -AllowMissingTargetPath $true -ValidationKind "office")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "o4Excel" -TargetPath $excelExe -AllowMissingTargetPath $true -ValidationKind "office")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "o5Power Point" -TargetPath $powerPointExe -AllowMissingTargetPath $true -ValidationKind "office")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "o6OneNote" -TargetPath $oneNoteExe -AllowMissingTargetPath $true -ValidationKind "office")

foreach ($spec in @($quickAccessWebShortcuts)) {
    $profileKind = if ($spec.ContainsKey('ProfileKind')) { [string]$spec.ProfileKind } else { 'business' }
    Add-Spec -List $shortcutSpecs -Spec (New-ChromeShortcutSpec -Name ([string]$spec.Name) -Url ([string]$spec.Url) -ProfileKind $profileKind -Variant 'remote')
}

foreach ($spec in @($socialWebShortcuts)) {
    Add-Spec -List $shortcutSpecs -Spec (New-ChromeShortcutSpec -Name ([string]$spec.Name) -Url ([string]$spec.Url) -ProfileKind ([string]$spec.ProfileKind) -Variant 'remote')
}

Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t1Git Bash" -TargetPath $gitBashExe -WorkingDirectory "%UserProfile%" -AllowMissingTargetPath $true -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t2Python CLI" -TargetPath $cmdExe -Arguments "/c cd /d %UserProfile% & python" -WorkingDirectory "%UserProfile%" -IconLocation (Resolve-IconLocation -PreferredPath $pythonExe -FallbackPath $cmdExe) -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t3NodeJS CLI" -TargetPath $cmdExe -Arguments "/c cd /d %UserProfile% & node" -WorkingDirectory "%UserProfile%" -IconLocation (Resolve-IconLocation -PreferredPath $nodeExe -FallbackPath $cmdExe) -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t4Ollama App" -TargetPath $cmdExe -Arguments '/c cd /d %UserProfile% & TaskKill -im "ollama app.exe" & start "" "%LOCALAPPDATA%\Programs\Ollama\ollama app.exe"' -WorkingDirectory "%UserProfile%" -IconLocation ($cmdExe + ",0") -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t5Pwsh" -TargetPath $cmdExe -Arguments "/k cd /d %UserProfile% & pwsh" -WorkingDirectory "%UserProfile%" -IconLocation (Resolve-IconLocation -PreferredPath $pwshExe -FallbackPath $cmdExe) -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t6PS" -TargetPath $cmdExe -Arguments "/k cd /d %UserProfile% & powershell" -WorkingDirectory "%UserProfile%" -IconLocation ($powershellExe + ",0") -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t7Azure CLI" -TargetPath $cmdExe -Arguments "/k cd /d %UserProfile% & az" -WorkingDirectory "%UserProfile%" -IconLocation (Resolve-IconLocation -PreferredPath $azExe -FallbackPath $cmdExe) -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t8WSL" -TargetPath $cmdExe -Arguments "/k cd /d %UserProfile% & wsl" -WorkingDirectory "%UserProfile%" -IconLocation (Resolve-IconLocation -PreferredPath $wslExe -FallbackPath $cmdExe) -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t9Docker CLI" -TargetPath $cmdExe -Arguments "/k cd /d %UserProfile% & docker info" -WorkingDirectory "%UserProfile%" -IconLocation (Resolve-IconLocation -PreferredPath $dockerExe -FallbackPath $cmdExe) -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t10Azd CLI" -TargetPath $cmdExe -Arguments "/k cd /d %UserProfile% & azd" -WorkingDirectory "%UserProfile%" -IconLocation (Resolve-IconLocation -PreferredPath $azdExe -FallbackPath $cmdExe) -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t11GH CLI" -TargetPath $cmdExe -Arguments "/k cd /d %UserProfile% & gh" -WorkingDirectory "%UserProfile%" -IconLocation (Resolve-IconLocation -PreferredPath $ghExe -FallbackPath $cmdExe) -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t12FFmpeg CLI" -TargetPath $cmdExe -Arguments "/k cd /d %UserProfile% & ffmpeg -version" -WorkingDirectory "%UserProfile%" -IconLocation (Resolve-IconLocation -PreferredPath $ffmpegExe -FallbackPath $cmdExe) -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t13Seven Zip CLI" -TargetPath $cmdExe -Arguments ('/k cd /d %UserProfile% & "{0}"' -f $sevenZipCliPath) -WorkingDirectory "%UserProfile%" -IconLocation ($sevenZipCliPath + ",0") -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t14Process Explorer" -TargetPath $processExplorerExe -AllowMissingTargetPath $true -ValidationKind "app")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t15Io Unlocker" -TargetPath $ioUnlockerExe -AllowMissingTargetPath $true -ValidationKind "app" -CleanupAliases @("IObit Unlocker") -CleanupMatchTargetOnly $true)

Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "u1User Files" -TargetPath $explorerExe -Arguments "shell:UsersFilesFolder" -IconLocation ($explorerExe + ",0") -ValidationKind "explorer-shell")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "u2This PC" -TargetPath $explorerExe -Arguments "shell:MyComputerFolder" -IconLocation ($explorerExe + ",0") -ValidationKind "explorer-shell")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "u3Control Panel" -TargetPath $explorerExe -Arguments "shell:ControlPanelFolder" -IconLocation ($explorerExe + ",0") -ValidationKind "explorer-shell")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "u7Network and Sharing" -TargetPath $controlExe -Arguments "/name Microsoft.NetworkAndSharingCenter" -IconLocation ($controlExe + ",0") -ValidationKind "app")

Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "v1VS2022Com" -TargetPath $vs2022CommunityExe -WorkingDirectory (Split-Path -Path $vs2022CommunityExe -Parent) -IconLocation (Resolve-IconLocation -PreferredPath $vs2022CommunityExe -FallbackPath $powershellExe) -AllowMissingTargetPath $true -ValidationKind "app" -CleanupAliases @("Visual Studio 2022") -CleanupMatchTargetOnly $true)
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "v5VS Code" -TargetPath $powershellExe -Arguments "-command ""&'%LocalAppData%\Programs\Microsoft VS Code\bin\code.cmd'""" -WorkingDirectory "%UserProfile%" -IconLocation ($powershellExe + ",0") -ValidationKind "app")

Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "z1Google Account Setup" -TargetPath $cmdExe -Arguments $chromeSyncSetupCommand -IconLocation ($chromeTarget + ",0") -ValidationKind "chrome-setup")
Add-Spec -List $shortcutSpecs -Spec (New-ChromeShortcutSpec -Name "z2Office365 Account Setup" -Url "https://portal.office.com" -ProfileKind 'business' -Variant 'setup')

$managedShortcutNames = @($shortcutSpecs | ForEach-Object { [string]$_.Name })
if (@($managedShortcutNames | Select-Object -Unique).Count -ne @($managedShortcutNames).Count) {
    throw "The public desktop shortcut manifest contains duplicate shortcut names."
}

$managedUserDesktopRoots = @(
    ("C:\Users\{0}\Desktop" -f $managerUser),
    ("C:\Users\{0}\Desktop" -f $assistantUser),
    "C:\Users\Default\Desktop"
)
$stagingRoot = ''
$publicDesktopAlreadyNormalized = Test-PublicDesktopAlreadyNormalized -PublicDesktopPath $publicDesktop -Specs $shortcutSpecs

try {
    if ($publicDesktopAlreadyNormalized) {
        Write-Host "public-desktop-normalized: no changes required"
    }
    else {
        $stagingRoot = Join-Path $env:TEMP ("az-vm-public-desktop-" + [guid]::NewGuid().ToString("N"))
        Ensure-Directory -Path $stagingRoot

        foreach ($shortcutSpec in $shortcutSpecs) {
            try {
                New-ShortcutFromSpec -Spec $shortcutSpec -OutputDirectory $stagingRoot
            }
            catch {
                throw ("Failed while creating public shortcut '{0}': {1}" -f [string]$shortcutSpec.Name, $_.Exception.Message)
            }
        }

        foreach ($existingShortcutFile in @(Get-ChildItem -LiteralPath $publicDesktop -Filter "*.lnk" -File -ErrorAction SilentlyContinue)) {
            $shortcutBaseName = [System.IO.Path]::GetFileNameWithoutExtension([string]$existingShortcutFile.Name)
            $matchedSpec = Find-ManagedShortcutSpecByName -Specs $shortcutSpecs -ShortcutBaseName $shortcutBaseName

            if ($null -eq $matchedSpec) {
                $existingDetails = $null
                try {
                    $existingDetails = Get-ShortcutDetails -ShortcutPath ([string]$existingShortcutFile.FullName)
                }
                catch {
                    Write-Warning ("public-desktop-inspect-skip: {0} => {1}" -f $existingShortcutFile.FullName, $_.Exception.Message)
                    continue
                }

                $matchedSpec = Find-ManagedShortcutSpecByDetails -Specs $shortcutSpecs -Details $existingDetails -ShortcutBaseName $shortcutBaseName
            }

            if ($null -eq $matchedSpec) {
                continue
            }

            try {
                Remove-Item -LiteralPath $existingShortcutFile.FullName -Force -ErrorAction Stop
                Write-Host ("public-desktop-removed: {0} => managed-by {1}" -f $existingShortcutFile.Name, [string]$matchedSpec.Name)
            }
            catch {
                throw ("Failed to remove existing public shortcut '{0}': {1}" -f $existingShortcutFile.FullName, $_.Exception.Message)
            }
        }

        Get-ChildItem -LiteralPath $stagingRoot -Filter "*.lnk" -File -ErrorAction SilentlyContinue | ForEach-Object {
            Move-Item -LiteralPath $_.FullName -Destination (Join-Path $publicDesktop $_.Name) -Force
        }

        foreach ($expectedShortcutName in @($managedShortcutNames)) {
            $expectedShortcutPath = Join-Path $publicDesktop ($expectedShortcutName + ".lnk")
            if (-not (Test-Path -LiteralPath $expectedShortcutPath)) {
                throw ("Managed public shortcut was not created: {0}" -f $expectedShortcutPath)
            }
        }
    }

    foreach ($managedUserDesktopRoot in @($managedUserDesktopRoots)) {
        Clear-DesktopEntries -DesktopPath ([string]$managedUserDesktopRoot)
    }
}
finally {
    if (-not [string]::IsNullOrWhiteSpace([string]$stagingRoot) -and (Test-Path -LiteralPath $stagingRoot)) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "create-shortcuts-public-desktop-completed"
Write-Host "Update task completed: create-shortcuts-public-desktop"
