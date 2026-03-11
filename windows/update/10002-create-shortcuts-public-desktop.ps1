$ErrorActionPreference = "Stop"
Write-Host "Update task started: create-shortcuts-public-desktop"

$companyName = "__COMPANY_NAME__"
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

if (Test-InvalidCompanyName -Value $companyName) {
    throw "company_name is required for the Windows public desktop shortcut flow. Set company_name in .env before running 10002-create-shortcuts-public-desktop."
}

$chromeRemoteArgsPrefix = ('--new-window --start-maximized --disable-extensions --disable-default-apps --no-first-run --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --no-default-browser-check --user-data-dir="{0}" --profile-directory="{1}"' -f $publicChromeUserDataDir, $companyName)
$chromeSetupArgsPrefix = ('--new-window --start-maximized --no-first-run --no-default-browser-check --user-data-dir="{0}" --profile-directory="{1}"' -f $publicChromeUserDataDir, $companyName)
$chromeBankArgsPrefix = ('--new-window --start-maximized --profile-directory="{0}"' -f $companyName)

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
        [string]$ValidationKind = "generic"
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
$anyDeskExe = Resolve-ExistingOrFallbackPath -PreferredPath "C:\Program Files\AnyDesk\AnyDesk.exe" -ResolvedPath (Resolve-CommandPath -CommandName "AnyDesk.exe" -FallbackCandidates @(
    "C:\Program Files\AnyDesk\AnyDesk.exe",
    "C:\Program Files (x86)\AnyDesk\AnyDesk.exe"
)) -FallbackPath "C:\Program Files\AnyDesk\AnyDesk.exe"
$windscribeExe = Resolve-CommandPath -CommandName "Windscribe.exe" -FallbackCandidates @(
    "C:\Program Files\Windscribe\Windscribe.exe",
    "C:\Program Files (x86)\Windscribe\Windscribe.exe"
)
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
    @{ Name = "s1LinkedIn Kurumsal"; Url = "https://tr.linkedin.com/company/exampleorg" },
    @{ Name = "s2LinkedIn Bireysel"; Url = "https://linkedin.com/in/<social-handle>" },
    @{ Name = "s3YouTube Kurumsal"; Url = "https://www.youtube.com/@exampleorg" },
    @{ Name = "s4YouTube Bireysel"; Url = "https://www.youtube.com/@hasanozdemir8" },
    @{ Name = "s5GitHub Kurumsal"; Url = "https://github.com/exampleorg" },
    @{ Name = "s6GitHub Bireysel"; Url = "https://github.com/" },
    @{ Name = "s7TikTok Kurumsal"; Url = "https://www.tiktok.com/@exampleorg" },
    @{ Name = "s8TikTok Bireysel"; Url = "https://www.tiktok.com/@exampleorg" },
    @{ Name = "s9Instagram Kurumsal"; Url = "https://instagram.com/exampleorg" },
    @{ Name = "s10Instagram Bireysel"; Url = "https://instagram.com/hasanozdemirnet" },
    @{ Name = "s11Facebook Kurumsal"; Url = "https://www.facebook.com/people/exampleorg-Teknoloji/61577930401447" },
    @{ Name = "s12Facebook Bireysel"; Url = "https://facebook.com/ozdemirhasan" },
    @{ Name = "s13X-Twitter Kurumsal"; Url = "https://x.com/exampleorg" },
    @{ Name = "s14X-Twitter Bireysel"; Url = "https://x.com/hasanozdemirnet" },
    @{ Name = ("s15{0} Web" -f $companyName); Url = "https://www.exampleorg.com" },
    @{ Name = ("s16{0} Blog" -f $companyName); Url = "https://www.exampleorg.com/blog" },
    @{ Name = "s17SnapChat Kurumsal"; Url = "https://www.snapchat.com/@exampleorg" },
    @{ Name = "s18Next Sosyal"; Url = "https://sosyal.teknofest.app/@exampleorg" }
)
$bankShortcuts = @(
    @{ Name = "b1GarantiBank Kurumsal"; Url = "https://sube.garantibbva.com.tr/isube/login/login/passwordentrycorporate-tr" },
    @{ Name = "b2GarantiBank Bireysel"; Url = "https://sube.garantibbva.com.tr/isube/login/login/passwordentrypersonal-tr" },
    @{ Name = "b3QnbBank Kurumsal"; Url = "https://internetsubesi.qnb.com.tr/Login/LoginPage.aspx?FromDK=true" },
    @{ Name = "b4QnbBank Bireysel"; Url = "https://internetsubesi.qnb.com.tr/Login/LoginPage.aspx" },
    @{ Name = "b5AktifBank Kurumsal"; Url = "https://kurumsal.aktifbank.com.tr/default.aspx?lang=tr-TR" },
    @{ Name = "b6AktifBank Bireysel"; Url = "https://online.aktifbank.com.tr/default.aspx?lang=tr-TR" },
    @{ Name = "b7ZiraatBank Kurumsal"; Url = "https://kurumsal.ziraatbank.com.tr/Transactions/Login/FirstLogin.aspx?customertype=crp" },
    @{ Name = "b8ZiraatBank Bireysel"; Url = "https://bireysel.ziraatbank.com.tr/Transactions/Login/FirstLogin.aspx" }
)

Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a1ChatGPT Web" -TargetPath $chromeTarget -Arguments ($chromeRemoteArgsPrefix + ' "https://chatgpt.com"') -IconLocation ($chromeTarget + ",0") -AllowMissingTargetPath $true -ValidationKind "chrome-web")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a2CodexApp" -TargetPath $codexAppExe -AllowMissingTargetPath $true -ValidationKind "app")
if (-not [string]::IsNullOrWhiteSpace([string]$beMyEyesAppId)) {
    Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a3Be My Eyes" -TargetPath $explorerExe -Arguments ("shell:AppsFolder\" + $beMyEyesAppId) -IconLocation ($explorerExe + ",0") -ValidationKind "store-appid")
}
else {
    Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a3Be My Eyes" -TargetPath $explorerExe -Arguments $beMyEyesStoreUri -IconLocation ($explorerExe + ",0") -ValidationKind "store-deeplink")
}
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a4WhatsApp Kurumsal" -TargetPath $whatsAppBusinessTarget -AllowMissingTargetPath $true -ValidationKind "app")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a5WhatsApp Bireysel" -TargetPath $chromeTarget -Arguments ($chromeRemoteArgsPrefix + ' "https://web.whatsapp.com"') -IconLocation ($chromeTarget + ",0") -AllowMissingTargetPath $true -ValidationKind "chrome-web")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a6AnyDesk" -TargetPath $anyDeskExe -AllowMissingTargetPath $true -ValidationKind "app")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a7Docker Desktop" -TargetPath $dockerDesktopExe -AllowMissingTargetPath $true -ValidationKind "app")
if (-not [string]::IsNullOrWhiteSpace([string]$windscribeExe)) {
    Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a8WindScribe" -TargetPath $windscribeExe -AllowMissingTargetPath $true -ValidationKind "app")
}
elseif (-not [string]::IsNullOrWhiteSpace([string]$windscribeAppId)) {
    Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a8WindScribe" -TargetPath $explorerExe -Arguments ("shell:AppsFolder\" + $windscribeAppId) -IconLocation ($explorerExe + ",0") -ValidationKind "store-appid")
}
else {
    Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a8WindScribe" -TargetPath "C:\Program Files\Windscribe\Windscribe.exe" -AllowMissingTargetPath $true -ValidationKind "app")
}
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a9VLC Player" -TargetPath $vlcExe -AllowMissingTargetPath $true -ValidationKind "app")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a10NVDA" -TargetPath $nvdaExe -Hotkey "Ctrl+Alt+N" -AllowMissingTargetPath $true -ValidationKind "app")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a11MS Edge" -TargetPath $edgeExe -AllowMissingTargetPath $true -ValidationKind "app")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "a12Itunes" -TargetPath $itunesExe -AllowMissingTargetPath $true -ValidationKind "app")

foreach ($spec in @($bankShortcuts)) {
    Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name ([string]$spec.Name) -TargetPath $chromeTarget -Arguments ($chromeBankArgsPrefix + ' "' + [string]$spec.Url + '"') -IconLocation ($chromeTarget + ",0") -AllowMissingTargetPath $true -ValidationKind "chrome-bank")
}

Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "c1Cmd" -TargetPath $cmdExe -Arguments "/k cd /d %UserProfile%" -WorkingDirectory "%UserProfile%" -IconLocation ($cmdExe + ",0") -ValidationKind "console")

Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "d1RClone CLI" -TargetPath $cmdExe -Arguments "/k cd /d %UserProfile% & rclone" -WorkingDirectory "%UserProfile%" -IconLocation (Resolve-IconLocation -PreferredPath $rcloneExe -FallbackPath $cmdExe) -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "d2One Drive" -TargetPath $oneDriveExe -AllowMissingTargetPath $true -ValidationKind "app")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "d3Google Drive" -TargetPath $googleDriveExe -AllowMissingTargetPath $true -ValidationKind "app")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "d4ICloud" -TargetPath $iCloudExe -AllowMissingTargetPath $true -ValidationKind "app")

Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "i1Internet" -TargetPath $chromeTarget -Arguments ($chromeRemoteArgsPrefix + ' "https://www.google.com"') -IconLocation ($chromeTarget + ",0") -AllowMissingTargetPath $true -ValidationKind "chrome-web")

Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "k1Codex CLI" -TargetPath $cmdExe -Arguments ('/c cd /d %UserProfile% & start "" "{0}" --enable multi_agent --yolo -s danger-full-access --cd "%UserProfile%" --search' -f $codexCmdPath) -WorkingDirectory "%UserProfile%" -IconLocation ($cmdExe + ",0") -AllowMissingTargetPath $true -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "k2Gemini CLI" -TargetPath $cmdExe -Arguments ('/c cd /d %UserProfile% & start "" "{0}" --screen-reader --yolo' -f $geminiCmdPath) -WorkingDirectory "%UserProfile%" -IconLocation ($cmdExe + ",0") -AllowMissingTargetPath $true -ValidationKind "console")

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

foreach ($spec in @($socialWebShortcuts)) {
    Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name ([string]$spec.Name) -TargetPath $chromeTarget -Arguments ($chromeRemoteArgsPrefix + ' "' + [string]$spec.Url + '"') -IconLocation ($chromeTarget + ",0") -AllowMissingTargetPath $true -ValidationKind "chrome-web")
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
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t10AZD CLI" -TargetPath $cmdExe -Arguments "/k cd /d %UserProfile% & azd" -WorkingDirectory "%UserProfile%" -IconLocation (Resolve-IconLocation -PreferredPath $azdExe -FallbackPath $cmdExe) -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t11GH CLI" -TargetPath $cmdExe -Arguments "/k cd /d %UserProfile% & gh" -WorkingDirectory "%UserProfile%" -IconLocation (Resolve-IconLocation -PreferredPath $ghExe -FallbackPath $cmdExe) -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t12FFmpeg CLI" -TargetPath $cmdExe -Arguments "/k cd /d %UserProfile% & ffmpeg -version" -WorkingDirectory "%UserProfile%" -IconLocation (Resolve-IconLocation -PreferredPath $ffmpegExe -FallbackPath $cmdExe) -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t13Seven Zip CLI" -TargetPath $cmdExe -Arguments ('/k cd /d %UserProfile% & "{0}"' -f $sevenZipCliPath) -WorkingDirectory "%UserProfile%" -IconLocation ($sevenZipCliPath + ",0") -ValidationKind "console")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t14Process Explorer" -TargetPath $processExplorerExe -AllowMissingTargetPath $true -ValidationKind "app")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "t15Io Unlocker" -TargetPath $ioUnlockerExe -AllowMissingTargetPath $true -ValidationKind "app")

Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "u1User Files" -TargetPath $explorerExe -Arguments "shell:UsersFilesFolder" -IconLocation ($explorerExe + ",0") -ValidationKind "explorer-shell")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "u2This PC" -TargetPath $explorerExe -Arguments "shell:MyComputerFolder" -IconLocation ($explorerExe + ",0") -ValidationKind "explorer-shell")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "u3Control Panel" -TargetPath $explorerExe -Arguments "shell:ControlPanelFolder" -IconLocation ($explorerExe + ",0") -ValidationKind "explorer-shell")

Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "v5VS Code" -TargetPath $powershellExe -Arguments "-command ""&'%LocalAppData%\Programs\Microsoft VS Code\bin\code.cmd'""" -WorkingDirectory "%UserProfile%" -IconLocation ($powershellExe + ",0") -ValidationKind "app")

Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "z1Google Account Setup" -TargetPath $chromeTarget -Arguments ($chromeSetupArgsPrefix + ' "chrome://settings/syncSetup"') -IconLocation ($chromeTarget + ",0") -AllowMissingTargetPath $true -ValidationKind "chrome-setup")
Add-Spec -List $shortcutSpecs -Spec (New-ShortcutSpec -Name "z2Office365 Account Setup" -TargetPath $chromeTarget -Arguments ($chromeSetupArgsPrefix + ' "https://portal.office.com"') -IconLocation ($chromeTarget + ",0") -AllowMissingTargetPath $true -ValidationKind "chrome-setup")

$managedShortcutNames = @($shortcutSpecs | ForEach-Object { [string]$_.Name })
if (@($managedShortcutNames | Select-Object -Unique).Count -ne @($managedShortcutNames).Count) {
    throw "The public desktop shortcut manifest contains duplicate shortcut names."
}

$stagingRoot = Join-Path $env:TEMP ("az-vm-public-desktop-" + [guid]::NewGuid().ToString("N"))
Ensure-Directory -Path $stagingRoot

try {
    foreach ($shortcutSpec in $shortcutSpecs) {
        try {
            New-ShortcutFromSpec -Spec $shortcutSpec -OutputDirectory $stagingRoot
        }
        catch {
            throw ("Failed while creating public shortcut '{0}': {1}" -f [string]$shortcutSpec.Name, $_.Exception.Message)
        }
    }

    Get-ChildItem -LiteralPath $publicDesktop -Filter "*.lnk" -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
            Write-Host ("public-desktop-removed: {0}" -f $_.Name)
        }
        catch {
            throw ("Failed to remove existing public shortcut '{0}': {1}" -f $_.FullName, $_.Exception.Message)
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

    $unexpectedShortcutPaths = @(
        Get-ChildItem -LiteralPath $publicDesktop -Filter "*.lnk" -File -ErrorAction SilentlyContinue |
            Where-Object { $managedShortcutNames -notcontains [System.IO.Path]::GetFileNameWithoutExtension([string]$_.Name) }
    )
    foreach ($unexpectedShortcut in @($unexpectedShortcutPaths)) {
        try {
            Remove-Item -LiteralPath $unexpectedShortcut.FullName -Force -ErrorAction Stop
            Write-Host ("unexpected-shortcut-removed: {0}" -f $unexpectedShortcut.FullName)
        }
        catch {
            throw ("Failed to remove unexpected public shortcut '{0}': {1}" -f $unexpectedShortcut.FullName, $_.Exception.Message)
        }
    }
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "create-shortcuts-public-desktop-completed"
Write-Host "Update task completed: create-shortcuts-public-desktop"
