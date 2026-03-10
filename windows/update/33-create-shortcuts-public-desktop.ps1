$ErrorActionPreference = "Stop"
Write-Host "Update task started: create-shortcuts-public-desktop"

$vmName = "__VM_NAME__"
$chromeProfileDirectoryName = "__COMPANY_NAME__"
$managerUser = "__VM_ADMIN_USER__"
$assistantUser = "__ASSISTANT_USER__"
$publicDesktop = "C:\Users\Public\Desktop"
$publicChromeUserDataDir = "C:\Users\Public\AppData\Local\Google\Chrome\UserData"
$chromeRemoteArgsPrefix = ('--new-window --start-maximized --disable-extensions --disable-default-apps --no-first-run --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --no-default-browser-check --user-data-dir="{0}" --profile-directory="{1}"' -f $publicChromeUserDataDir, $chromeProfileDirectoryName)
$chromeSetupArgsPrefix = ('--new-window --start-maximized --no-first-run --no-default-browser-check --user-data-dir="{0}" --profile-directory="{1}"' -f $publicChromeUserDataDir, $chromeProfileDirectoryName)
$chromeBankArgsPrefix = ('--new-window --start-maximized --profile-directory="{0}"' -f $chromeProfileDirectoryName)
$beMyEyesStoreProductId = "9MSW46LTDWGF"
$beMyEyesStoreUri = "ms-windows-store://pdp/?ProductId=9MSW46LTDWGF"
$codexAppFallbackPath = Join-Path $env:ProgramFiles "WindowsApps\OpenAI.Codex_26.306.996.0_x64__2p2nqsd0c76g0\app\Codex.exe"
$whatsAppFallbackPath = "C:\Program Files\WindowsApps\5319275A.WhatsAppDesktop_2.2606.102.0_x64__cv1g1gvanyjgm\WhatsApp.Root.exe"
$q1EksisozlukName = ("q1Ek{0}iS{1}zl{2}k" -f [char]0x015F, [char]0x00F6, [char]0x00FC)
$commonWebShortcuts = @(
    @{ Name = 'a1ChatGPT Web'; Url = 'https://chatgpt.com'; Profile = 'remote' },
    @{ Name = 'i0Internet'; Url = 'https://www.google.com'; Profile = 'remote' },
    @{ Name = 'i2WhatsApp Bireysel'; Url = 'https://web.whatsapp.com'; Profile = 'remote' },
    @{ Name = 'z1Google Account Setup'; Url = 'chrome://settings/syncSetup'; Profile = 'setup' },
    @{ Name = 'z2Office365 Account Setup'; Url = 'https://portal.office.com'; Profile = 'setup' }
)
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
    @{ Name = "s15Web Sitesi Kurumsal"; Url = "https://www.exampleorg.com" },
    @{ Name = "s16Blog Sitesi Kurumsal"; Url = "https://www.exampleorg.com/blog" },
    @{ Name = $q1EksisozlukName; Url = "https://www.eksisozluk.com" }
)
$bankShortcuts = @(
    @{ Name = "b1GarantiBank Bireysel"; Url = "https://sube.garantibbva.com.tr/isube/login/login/passwordentrypersonal-tr" },
    @{ Name = "b2GarantiBank Kurumsal"; Url = "https://sube.garantibbva.com.tr/isube/login/login/passwordentrycorporate-tr" },
    @{ Name = "b3QnbBank Bireysel"; Url = "https://internetsubesi.qnb.com.tr/Login/LoginPage.aspx" },
    @{ Name = "b4QnbBank Kurumsal"; Url = "https://internetsubesi.qnb.com.tr/Login/LoginPage.aspx?FromDK=true" },
    @{ Name = "b5AktifBank Bireysel"; Url = "https://online.aktifbank.com.tr/default.aspx?lang=tr-TR" },
    @{ Name = "b6AktifBank Kurumsal"; Url = "https://kurumsal.aktifbank.com.tr/default.aspx?lang=tr-TR" },
    @{ Name = "b7ZiraatBank Bireysel"; Url = "https://bireysel.ziraatbank.com.tr/Transactions/Login/FirstLogin.aspx" },
    @{ Name = "b8ZiraatBank Kurumsal"; Url = "https://kurumsal.ziraatbank.com.tr/Transactions/Login/FirstLogin.aspx?customertype=crp" }
)
$managedShortcutNames = @(
    'a2Be My Eyes',
    'a3CodexApp',
    'a7Docker Desktop',
    'a10NVDA',
    'a11MS Edge',
    'a14VLC Player',
    'a17Itunes',
    'c0Cmd',
    'd0Rclone CLI',
    'd1One Drive',
    'd2Google Drive',
    'i1WhatsApp Kurumsal',
    'i8AnyDesk',
    'i9Windscribe',
    'o0Outlook',
    'o1Teams',
    'o2Word',
    'o3Excel',
    'o4Power Point',
    'o5OneNote',
    't0Git Bash',
    't1Python CLI',
    't2Nodejs CLI',
    't3Ollama App',
    't4Pwsh',
    't5PS',
    't6Azure CLI',
    't7WSL',
    't8Docker CLI',
    't9AZD CLI',
    't10GH CLI',
    't11FFmpeg CLI',
    't12SevenZip CLI',
    't13Sysinternals',
    't14Io Unlocker',
    't15Codex CLI',
    't16Gemini CLI',
    'u7Network and Sharing',
    'v5VS Code'
)
$managedShortcutNames += @($commonWebShortcuts | ForEach-Object { [string]$_.Name })
$managedShortcutNames += @($socialWebShortcuts | ForEach-Object { [string]$_.Name })
$managedShortcutNames += @($bankShortcuts | ForEach-Object { [string]$_.Name })

if ([string]::IsNullOrWhiteSpace([string]$chromeProfileDirectoryName) -or [string]::Equals([string]$chromeProfileDirectoryName, "__COMPANY_NAME__", [System.StringComparison]::Ordinal)) {
    $chromeProfileDirectoryName = $vmName
}

function Refresh-SessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path -LiteralPath $refreshEnvCmd) {
        cmd.exe /d /c "`"$refreshEnvCmd`""
    }

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) {
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
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
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
        if ([string]::IsNullOrWhiteSpace([string]$nameText)) { return $false }
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
        catch { }
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

function Convert-StringToCharCodeLiteral {
    param([string]$Value)

    $codes = @()
    if ($null -ne $Value) {
        $codes = @([int[]][char[]][string]$Value)
    }

    if (@($codes).Count -eq 0) {
        return '@()'
    }

    return ('@(' + (($codes | ForEach-Object { [string]$_ }) -join ',') + ')')
}

function New-DesktopShortcutViaPwsh {
    param(
        [string]$Name,
        [string]$TargetPath,
        [string]$Arguments = "",
        [string]$WorkingDirectory = "",
        [string]$IconLocation = "",
        [string]$Hotkey = ""
    )

    if ([string]::IsNullOrWhiteSpace([string]$pwshExe) -or -not (Test-Path -LiteralPath $pwshExe)) {
        throw "pwsh.exe is required for non-ASCII shortcut creation."
    }

    $nameChars = Convert-StringToCharCodeLiteral -Value $Name
    $targetChars = Convert-StringToCharCodeLiteral -Value $TargetPath
    $argumentsChars = Convert-StringToCharCodeLiteral -Value $Arguments
    $workingDirectoryChars = Convert-StringToCharCodeLiteral -Value $WorkingDirectory
    $iconChars = Convert-StringToCharCodeLiteral -Value $IconLocation
    $hotkeyChars = Convert-StringToCharCodeLiteral -Value $Hotkey
    $desktopChars = Convert-StringToCharCodeLiteral -Value $publicDesktop

    $scriptText = @"
`$publicDesktop = -join ($desktopChars | ForEach-Object { [char]`$_ })
`$name = -join ($nameChars | ForEach-Object { [char]`$_ })
`$targetPath = -join ($targetChars | ForEach-Object { [char]`$_ })
`$arguments = -join ($argumentsChars | ForEach-Object { [char]`$_ })
`$workingDirectory = -join ($workingDirectoryChars | ForEach-Object { [char]`$_ })
`$iconLocation = -join ($iconChars | ForEach-Object { [char]`$_ })
`$hotkey = -join ($hotkeyChars | ForEach-Object { [char]`$_ })
if (-not (Test-Path -LiteralPath `$publicDesktop)) {
    New-Item -Path `$publicDesktop -ItemType Directory -Force | Out-Null
}
`$shortcutPath = Join-Path `$publicDesktop (`$name + '.lnk')
`$tempShortcutPath = Join-Path `$publicDesktop (('az-vm-shortcut-{0}.lnk' -f [System.Guid]::NewGuid().ToString('N')))
`$shell = New-Object -ComObject WScript.Shell
`$shortcut = `$shell.CreateShortcut(`$tempShortcutPath)
`$shortcut.TargetPath = `$targetPath
`$shortcut.Arguments = `$arguments
if ([string]::IsNullOrWhiteSpace([string]`$workingDirectory)) {
    `$parentPath = Split-Path -Path `$targetPath -Parent
    if (-not [string]::IsNullOrWhiteSpace([string]`$parentPath)) {
        `$shortcut.WorkingDirectory = `$parentPath
    }
}
else {
    `$shortcut.WorkingDirectory = `$workingDirectory
}
if ([string]::IsNullOrWhiteSpace([string]`$iconLocation)) {
    `$shortcut.IconLocation = ('{0},0' -f `$targetPath)
}
else {
    `$shortcut.IconLocation = `$iconLocation
}
if (-not [string]::IsNullOrWhiteSpace([string]`$hotkey)) {
    `$shortcut.Hotkey = `$hotkey
}
`$shortcut.Save()
Move-Item -LiteralPath `$tempShortcutPath -Destination `$shortcutPath -Force
"@

    & $pwshExe -NoProfile -Command $scriptText | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw ("pwsh-based shortcut creation failed for '{0}'." -f $Name)
    }
}

function New-DesktopShortcut {
    param(
        [string]$Name,
        [string]$TargetPath,
        [string]$Arguments = "",
        [string]$WorkingDirectory = "",
        [string]$IconLocation = "",
        [string]$Hotkey = "",
        [switch]$AllowMissingTargetPath
    )

    if ([string]::IsNullOrWhiteSpace([string]$Name)) {
        throw "Shortcut name is empty."
    }
    if ([string]::IsNullOrWhiteSpace([string]$TargetPath)) {
        throw "Shortcut target is empty."
    }
    if (-not $AllowMissingTargetPath -and -not (Test-Path -LiteralPath $TargetPath)) {
        throw "Shortcut target was not found: $TargetPath"
    }

    if (-not (Test-Path -LiteralPath $publicDesktop)) {
        New-Item -Path $publicDesktop -ItemType Directory -Force | Out-Null
    }

    if ($Name -cmatch '[^\u0000-\u007F]') {
        New-DesktopShortcutViaPwsh -Name $Name -TargetPath $TargetPath -Arguments $Arguments -WorkingDirectory $WorkingDirectory -IconLocation $IconLocation -Hotkey $Hotkey
        return
    }

    $shortcutPath = Join-Path $publicDesktop ($Name + ".lnk")
    $tempShortcutPath = Join-Path $publicDesktop (("az-vm-shortcut-{0}.lnk" -f [System.Guid]::NewGuid().ToString("N")))
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($tempShortcutPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = $Arguments
    if ([string]::IsNullOrWhiteSpace([string]$WorkingDirectory)) {
        $parentPath = Split-Path -Path $TargetPath -Parent
        if (-not [string]::IsNullOrWhiteSpace([string]$parentPath)) {
            $shortcut.WorkingDirectory = $parentPath
        }
    }
    else {
        $shortcut.WorkingDirectory = $WorkingDirectory
    }
    if ([string]::IsNullOrWhiteSpace([string]$IconLocation)) {
        $shortcut.IconLocation = "$TargetPath,0"
    }
    else {
        $shortcut.IconLocation = $IconLocation
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Hotkey)) {
        $shortcut.Hotkey = [string]$Hotkey
    }
    $shortcut.Save()
    Move-Item -LiteralPath $tempShortcutPath -Destination $shortcutPath -Force
}

function New-DesktopShortcutFromAppId {
    param(
        [string]$Name,
        [string]$AppId
    )

    if ([string]::IsNullOrWhiteSpace([string]$AppId)) {
        throw "AppId was not found for '$Name'."
    }

    $explorerExe = Join-Path $env:WINDIR "explorer.exe"
    if (-not (Test-Path -LiteralPath $explorerExe)) {
        throw "explorer.exe was not found."
    }

    New-DesktopShortcut -Name $Name -TargetPath $explorerExe -Arguments ("shell:AppsFolder\" + $AppId)
}

function New-StoreDeeplinkShortcut {
    param(
        [string]$Name,
        [string]$StoreUri
    )

    if ([string]::IsNullOrWhiteSpace([string]$StoreUri)) {
        throw "Store URI is empty."
    }

    $explorerExe = Join-Path $env:WINDIR "explorer.exe"
    if (-not (Test-Path -LiteralPath $explorerExe)) {
        throw "explorer.exe was not found."
    }

    New-DesktopShortcut -Name $Name -TargetPath $explorerExe -Arguments $StoreUri -IconLocation "$explorerExe,0"
}

function New-ConsoleToolShortcut {
    param(
        [string]$Name,
        [string]$CommandText,
        [string]$IconLocation = ""
    )

    if ([string]::IsNullOrWhiteSpace([string]$CommandText)) {
        throw "Console command text is empty."
    }

    New-DesktopShortcut -Name $Name -TargetPath $cmdExe -Arguments ("/k " + $CommandText) -IconLocation $IconLocation
}

function New-CmdWrappedShortcut {
    param(
        [string]$Name,
        [string]$CommandArguments,
        [string]$IconLocation = "",
        [string]$WorkingDirectory = ""
    )

    if ([string]::IsNullOrWhiteSpace([string]$cmdExe)) {
        throw "cmd.exe was not found."
    }
    if ([string]::IsNullOrWhiteSpace([string]$CommandArguments)) {
        throw "Wrapped command arguments are empty."
    }

    New-DesktopShortcut -Name $Name -TargetPath $cmdExe -Arguments $CommandArguments -IconLocation $IconLocation -WorkingDirectory $WorkingDirectory
}

function Invoke-ShortcutAction {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    try {
        & $Action
        Write-Host "shortcut-ok: $Name"
    }
    catch {
        Write-Warning "shortcut-skip: $Name => $($_.Exception.Message)"
    }
}

Refresh-SessionPath

if (-not (Test-Path -LiteralPath $publicDesktop)) {
    New-Item -Path $publicDesktop -ItemType Directory -Force | Out-Null
}

Get-ChildItem -LiteralPath $publicDesktop -Filter "*.lnk" -File -ErrorAction SilentlyContinue | ForEach-Object {
    $shortcutName = [System.IO.Path]::GetFileNameWithoutExtension([string]$_.Name)
    if ($managedShortcutNames -notcontains $shortcutName) {
        return
    }

    try {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
    }
    catch {
        Write-Warning "public-desktop-cleanup-skip: $($_.FullName) => $($_.Exception.Message)"
    }
}

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
$sysinternalsExe = Resolve-CommandPath -CommandName "procexp64.exe" -FallbackCandidates @(
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
$vsCodeExe = Resolve-ExistingOrFallbackPath -PreferredPath "C:\Program Files\Microsoft VS Code\Code.exe" -ResolvedPath (Resolve-CommandPath -CommandName "code.exe" -FallbackCandidates @(
    "C:\Program Files\Microsoft VS Code\Code.exe",
    ("C:\Users\{0}\AppData\Local\Programs\Microsoft VS Code\Code.exe" -f $managerUser),
    ("C:\Users\{0}\AppData\Local\Programs\Microsoft VS Code\Code.exe" -f $assistantUser)
)) -FallbackPath "C:\Program Files\Microsoft VS Code\Code.exe"
$codexExe = Resolve-CommandPath -CommandName "codex.cmd" -FallbackCandidates @(
    ("C:\Users\{0}\AppData\Roaming\npm\codex.cmd" -f $managerUser),
    ("C:\Users\{0}\AppData\Roaming\npm\codex.cmd" -f $assistantUser),
    "C:\Program Files\nodejs\codex.cmd"
)
$geminiExe = Resolve-CommandPath -CommandName "gemini.cmd" -FallbackCandidates @(
    ("C:\Users\{0}\AppData\Roaming\npm\gemini.cmd" -f $managerUser),
    ("C:\Users\{0}\AppData\Roaming\npm\gemini.cmd" -f $assistantUser),
    "C:\Program Files\nodejs\gemini.cmd"
)
$itunesResolvedExe = Resolve-CommandPath -CommandName "iTunes.exe" -FallbackCandidates @(
    "C:\Program Files\iTunes\iTunes.exe",
    "C:\Program Files (x86)\iTunes\iTunes.exe"
)
$itunesExe = Resolve-ExistingOrFallbackPath -PreferredPath "C:\Program Files\iTunes\iTunes.exe" -ResolvedPath $itunesResolvedExe -FallbackPath "C:\Program Files\iTunes\iTunes.exe"
$nvdaResolvedExe = Resolve-CommandPath -CommandName "nvda.exe" -FallbackCandidates @(
    "C:\Program Files\NVDA\nvda.exe",
    "C:\Program Files (x86)\NVDA\nvda.exe"
)
$nvdaExe = Resolve-ExistingOrFallbackPath -PreferredPath "C:\Program Files\NVDA\nvda.exe" -ResolvedPath $nvdaResolvedExe -FallbackPath "C:\Program Files\NVDA\nvda.exe"
$edgeResolvedExe = Resolve-CommandPath -CommandName "msedge.exe" -FallbackCandidates @(
    "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
)
$edgeExe = Resolve-ExistingOrFallbackPath -PreferredPath "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" -ResolvedPath $edgeResolvedExe -FallbackPath "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
$vlcResolvedExe = Resolve-CommandPath -CommandName "vlc.exe" -FallbackCandidates @(
    "C:\Program Files\VideoLAN\VLC\vlc.exe",
    "C:\Program Files (x86)\VideoLAN\VLC\vlc.exe"
)
$vlcExe = Resolve-ExistingOrFallbackPath -PreferredPath "C:\Program Files\VideoLAN\VLC\vlc.exe" -ResolvedPath $vlcResolvedExe -FallbackPath "C:\Program Files\VideoLAN\VLC\vlc.exe"
$oneDriveResolvedExe = Resolve-CommandPath -CommandName "OneDrive.exe" -FallbackCandidates @(
    "C:\Program Files\Microsoft OneDrive\OneDrive.exe",
    ("C:\Users\{0}\AppData\Local\Microsoft\OneDrive\OneDrive.exe" -f $managerUser),
    ("C:\Users\{0}\AppData\Local\Microsoft\OneDrive\OneDrive.exe" -f $assistantUser)
)
$oneDriveExe = Resolve-ExistingOrFallbackPath -PreferredPath "C:\Program Files\Microsoft OneDrive\OneDrive.exe" -ResolvedPath $oneDriveResolvedExe -FallbackPath "C:\Program Files\Microsoft OneDrive\OneDrive.exe"
$googleDriveResolvedExe = Resolve-CommandPath -CommandName "GoogleDriveFS.exe" -FallbackCandidates @("C:\Program Files\Google\Drive File Stream\GoogleDriveFS.exe")
if ([string]::IsNullOrWhiteSpace([string]$googleDriveResolvedExe)) {
    $googleDriveResolvedExe = Resolve-ExecutableUnderDirectory -RootPaths @("C:\Program Files\Google\Drive File Stream") -ExecutableName "GoogleDriveFS.exe"
}
$googleDriveExe = Resolve-ExistingOrFallbackPath -PreferredPath "C:\Program Files\Google\Drive File Stream\GoogleDriveFS.exe" -ResolvedPath $googleDriveResolvedExe -FallbackPath "C:\Program Files\Google\Drive File Stream\GoogleDriveFS.exe"

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
$controlExe = Resolve-CommandPath -CommandName "control.exe" -FallbackCandidates @("C:\Windows\System32\control.exe")

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
$codexCmdPath = Resolve-ExistingOrFallbackPath -PreferredPath ("C:\Users\{0}\AppData\Roaming\npm\codex.cmd" -f $managerUser) -ResolvedPath $codexExe -FallbackPath ("C:\Users\{0}\AppData\Roaming\npm\codex.cmd" -f $managerUser)
$geminiCmdPath = Resolve-ExistingOrFallbackPath -PreferredPath ("C:\Users\{0}\AppData\Roaming\npm\gemini.cmd" -f $managerUser) -ResolvedPath $geminiExe -FallbackPath ("C:\Users\{0}\AppData\Roaming\npm\gemini.cmd" -f $managerUser)

Invoke-ShortcutAction -Name "a2Be My Eyes" -Action {
    if (-not [string]::IsNullOrWhiteSpace([string]$beMyEyesAppId)) {
        New-DesktopShortcutFromAppId -Name "a2Be My Eyes" -AppId $beMyEyesAppId
    }
    else {
        New-StoreDeeplinkShortcut -Name "a2Be My Eyes" -StoreUri $beMyEyesStoreUri
    }
}
Invoke-ShortcutAction -Name "a3CodexApp" -Action { New-DesktopShortcut -Name "a3CodexApp" -TargetPath $codexAppExe -AllowMissingTargetPath }
Invoke-ShortcutAction -Name "a7Docker Desktop" -Action { New-DesktopShortcut -Name "a7Docker Desktop" -TargetPath $dockerDesktopExe -AllowMissingTargetPath }
Invoke-ShortcutAction -Name "a10NVDA" -Action { New-DesktopShortcut -Name "a10NVDA" -TargetPath $nvdaExe -AllowMissingTargetPath }
Invoke-ShortcutAction -Name "a11MS Edge" -Action { New-DesktopShortcut -Name "a11MS Edge" -TargetPath $edgeExe -AllowMissingTargetPath }
Invoke-ShortcutAction -Name "a14VLC Player" -Action { New-DesktopShortcut -Name "a14VLC Player" -TargetPath $vlcExe -AllowMissingTargetPath }
Invoke-ShortcutAction -Name "a17Itunes" -Action { New-DesktopShortcut -Name "a17Itunes" -TargetPath $itunesExe -AllowMissingTargetPath }
Invoke-ShortcutAction -Name "i1WhatsApp Kurumsal" -Action { New-DesktopShortcut -Name "i1WhatsApp Kurumsal" -TargetPath $whatsAppBusinessTarget -AllowMissingTargetPath }

foreach ($spec in @($commonWebShortcuts)) {
    $shortcutName = [string]$spec.Name
    $shortcutUrl = [string]$spec.Url
    $profileMode = [string]$spec.Profile
    $argumentsPrefix = if ([string]::Equals($profileMode, 'setup', [System.StringComparison]::OrdinalIgnoreCase)) {
        $chromeSetupArgsPrefix
    }
    else {
        $chromeRemoteArgsPrefix
    }

    Invoke-ShortcutAction -Name $shortcutName -Action {
        New-DesktopShortcut -Name $shortcutName -TargetPath $chromeTarget -Arguments ($argumentsPrefix + ' "' + $shortcutUrl + '"') -IconLocation "$chromeTarget,0"
    }
}

foreach ($spec in @($socialWebShortcuts)) {
    $shortcutName = [string]$spec.Name
    $shortcutUrl = [string]$spec.Url
    Invoke-ShortcutAction -Name $shortcutName -Action { New-DesktopShortcut -Name $shortcutName -TargetPath $chromeTarget -Arguments ($chromeRemoteArgsPrefix + ' "' + $shortcutUrl + '"') -IconLocation "$chromeTarget,0" }
}

foreach ($spec in @($bankShortcuts)) {
    $shortcutName = [string]$spec.Name
    $shortcutUrl = [string]$spec.Url
    Invoke-ShortcutAction -Name $shortcutName -Action { New-DesktopShortcut -Name $shortcutName -TargetPath $chromeTarget -Arguments ($chromeBankArgsPrefix + ' "' + $shortcutUrl + '"') -IconLocation "$chromeTarget,0" }
}

Invoke-ShortcutAction -Name "c0Cmd" -Action { New-DesktopShortcut -Name "c0Cmd" -TargetPath $cmdExe }
Invoke-ShortcutAction -Name "d0Rclone CLI" -Action {
    if (-not [string]::IsNullOrWhiteSpace([string]$rcloneExe)) {
        New-CmdWrappedShortcut -Name "d0Rclone CLI" -CommandArguments ('/k "{0}" version' -f $rcloneExe) -IconLocation "$rcloneExe,0"
    }
    else {
        New-CmdWrappedShortcut -Name "d0Rclone CLI" -CommandArguments '/k rclone version'
    }
}
Invoke-ShortcutAction -Name "d1One Drive" -Action { New-DesktopShortcut -Name "d1One Drive" -TargetPath $oneDriveExe -AllowMissingTargetPath }
Invoke-ShortcutAction -Name "d2Google Drive" -Action { New-DesktopShortcut -Name "d2Google Drive" -TargetPath $googleDriveExe -AllowMissingTargetPath }
Invoke-ShortcutAction -Name "o0Outlook" -Action { New-DesktopShortcut -Name "o0Outlook" -TargetPath $outlookExe }
Invoke-ShortcutAction -Name "o1Teams" -Action {
    if (-not [string]::IsNullOrWhiteSpace([string]$teamsAppId)) {
        New-DesktopShortcutFromAppId -Name "o1Teams" -AppId $teamsAppId
    }
    else {
        $teamsExe = Resolve-CommandPath -CommandName "ms-teams.exe" -FallbackCandidates @("C:\Program Files\WindowsApps\MSTeams_8wekyb3d8bbwe\ms-teams.exe")
        New-DesktopShortcut -Name "o1Teams" -TargetPath $teamsExe
    }
}
Invoke-ShortcutAction -Name "o2Word" -Action { New-DesktopShortcut -Name "o2Word" -TargetPath $wordExe }
Invoke-ShortcutAction -Name "o3Excel" -Action { New-DesktopShortcut -Name "o3Excel" -TargetPath $excelExe }
Invoke-ShortcutAction -Name "o4Power Point" -Action { New-DesktopShortcut -Name "o4Power Point" -TargetPath $powerPointExe }
Invoke-ShortcutAction -Name "o5OneNote" -Action { New-DesktopShortcut -Name "o5OneNote" -TargetPath $oneNoteExe }
Invoke-ShortcutAction -Name "t0Git Bash" -Action { New-DesktopShortcut -Name "t0Git Bash" -TargetPath $gitBashExe }
Invoke-ShortcutAction -Name "t1Python CLI" -Action { New-ConsoleToolShortcut -Name "t1Python CLI" -CommandText "python" -IconLocation "$pythonExe,0" }
Invoke-ShortcutAction -Name "t2Nodejs CLI" -Action { New-ConsoleToolShortcut -Name "t2Nodejs CLI" -CommandText "node" -IconLocation "$nodeExe,0" }
Invoke-ShortcutAction -Name "t3Ollama App" -Action { New-CmdWrappedShortcut -Name "t3Ollama App" -CommandArguments '/c TaskKill -im "ollama app.exe" & "%LOCALAPPDATA%\Programs\Ollama\ollama app.exe"' }
Invoke-ShortcutAction -Name "t4Pwsh" -Action { New-DesktopShortcut -Name "t4Pwsh" -TargetPath $pwshExe }
Invoke-ShortcutAction -Name "t5PS" -Action { New-DesktopShortcut -Name "t5PS" -TargetPath $powershellExe }
Invoke-ShortcutAction -Name "t6Azure CLI" -Action { New-CmdWrappedShortcut -Name "t6Azure CLI" -CommandArguments '/k cd /d c:\users\public & az --version' -IconLocation "$azExe,0" -WorkingDirectory "C:\Users\Public" }
Invoke-ShortcutAction -Name "t7WSL" -Action { New-DesktopShortcut -Name "t7WSL" -TargetPath $wslExe }
Invoke-ShortcutAction -Name "t8Docker CLI" -Action { New-ConsoleToolShortcut -Name "t8Docker CLI" -CommandText "docker" -IconLocation "$dockerExe,0" }
Invoke-ShortcutAction -Name "t9AZD CLI" -Action { New-ConsoleToolShortcut -Name "t9AZD CLI" -CommandText "azd" -IconLocation "$azdExe,0" }
Invoke-ShortcutAction -Name "t10GH CLI" -Action { New-ConsoleToolShortcut -Name "t10GH CLI" -CommandText "gh" -IconLocation "$ghExe,0" }
Invoke-ShortcutAction -Name "t11FFmpeg CLI" -Action { New-ConsoleToolShortcut -Name "t11FFmpeg CLI" -CommandText "ffmpeg -version" -IconLocation "$ffmpegExe,0" }
Invoke-ShortcutAction -Name "t12SevenZip CLI" -Action { New-CmdWrappedShortcut -Name "t12SevenZip CLI" -CommandArguments ('/c "{0}"' -f $sevenZipCliPath) -IconLocation "$sevenZipCliPath,0" }
Invoke-ShortcutAction -Name "t13Sysinternals" -Action {
    if (-not [string]::IsNullOrWhiteSpace([string]$sysinternalsExe)) {
        New-DesktopShortcut -Name "t13Sysinternals" -TargetPath $sysinternalsExe
    }
    else {
        New-ConsoleToolShortcut -Name "t13Sysinternals" -CommandText "procexp64"
    }
}
Invoke-ShortcutAction -Name "t14Io Unlocker" -Action { New-DesktopShortcut -Name "t14Io Unlocker" -TargetPath $ioUnlockerExe }
Invoke-ShortcutAction -Name "t15Codex CLI" -Action { New-CmdWrappedShortcut -Name "t15Codex CLI" -CommandArguments ('/c start "" "{0}" --enable multi_agent --yolo -s danger-full-access --cd "c:\users\public" --search' -f $codexCmdPath) }
Invoke-ShortcutAction -Name "t16Gemini CLI" -Action { New-CmdWrappedShortcut -Name "t16Gemini CLI" -CommandArguments ('/c start "" "{0}" --screen-reader --yolo' -f $geminiCmdPath) }
Invoke-ShortcutAction -Name "i8AnyDesk" -Action { New-DesktopShortcut -Name "i8AnyDesk" -TargetPath $anyDeskExe -AllowMissingTargetPath }
Invoke-ShortcutAction -Name "i9Windscribe" -Action {
    if (-not [string]::IsNullOrWhiteSpace([string]$windscribeExe)) {
        New-DesktopShortcut -Name "i9Windscribe" -TargetPath $windscribeExe
    }
    else {
        New-DesktopShortcutFromAppId -Name "i9Windscribe" -AppId $windscribeAppId
    }
}
Invoke-ShortcutAction -Name "u7Network and Sharing" -Action { New-DesktopShortcut -Name "u7Network and Sharing" -TargetPath $controlExe -Arguments "/name Microsoft.NetworkAndSharingCenter" }
Invoke-ShortcutAction -Name "v5VS Code" -Action { New-DesktopShortcut -Name "v5VS Code" -TargetPath $vsCodeExe -AllowMissingTargetPath }

Write-Host "create-shortcuts-public-desktop-completed"
Write-Host "Update task completed: create-shortcuts-public-desktop"
