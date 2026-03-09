$ErrorActionPreference = "Stop"
Write-Host "Update task started: windows-ux-public-desktop-shortcuts"

$vmName = "__VM_NAME__"
$managerUser = "__VM_ADMIN_USER__"
$assistantUser = "__ASSISTANT_USER__"
$publicDesktop = "C:\Users\Public\Desktop"
$publicChromeUserDataDir = "C:\Users\Public\AppData\Local\Google\Chrome\UserData"
$chromeRemoteArgsPrefix = ('--new-window --start-maximized --disable-extensions --disable-default-apps --no-first-run --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --no-default-browser-check --user-data-dir="{0}" --profile-directory="{1}"' -f $publicChromeUserDataDir, $vmName)
$chromeSetupArgsPrefix = ('--new-window --start-maximized --no-first-run --no-default-browser-check --user-data-dir="{0}" --profile-directory="{1}"' -f $publicChromeUserDataDir, $vmName)
$chromeBankArgsPrefix = ("--new-window --start-maximized --profile-directory={0}" -f $vmName)
$whatsAppFallbackPath = "C:\Program Files\WindowsApps\5319275A.WhatsAppDesktop_2.2606.102.0_x64__cv1g1gvanyjgm\WhatsApp.Root.exe"

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

function New-DesktopShortcut {
    param(
        [string]$Name,
        [string]$TargetPath,
        [string]$Arguments = "",
        [string]$WorkingDirectory = "",
        [string]$IconLocation = "",
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

    $shortcutPath = Join-Path $publicDesktop ($Name + ".lnk")
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
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
    $shortcut.Save()
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
    try {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
    }
    catch {
        Write-Warning "public-desktop-cleanup-skip: $($_.FullName) => $($_.Exception.Message)"
    }
}

$chromeExe = Resolve-CommandPath -CommandName "chrome.exe" -FallbackCandidates @(
    "C:\Program Files\Google\Chrome\Application\chrome.exe",
    "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
)
$chromeTarget = Resolve-ExistingOrFallbackPath -PreferredPath "C:\Program Files\Google\Chrome\Application\chrome.exe" -ResolvedPath $chromeExe -FallbackPath "C:\Program Files\Google\Chrome\Application\chrome.exe"
$cmdExe = Resolve-CommandPath -CommandName "cmd.exe" -FallbackCandidates @("C:\Windows\System32\cmd.exe")
$powershellExe = Resolve-CommandPath -CommandName "powershell.exe" -FallbackCandidates @("C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe")
$pwshExe = Resolve-CommandPath -CommandName "pwsh.exe" -FallbackCandidates @(
    "C:\Program Files\PowerShell\7\pwsh.exe"
)
$dockerDesktopExe = Resolve-CommandPath -CommandName "Docker Desktop.exe" -FallbackCandidates @(
    "C:\Program Files\Docker\Docker\Docker Desktop.exe"
)
$localOnlyAccessibilityExe = Resolve-CommandPath -CommandName "local-accessibility.exe" -FallbackCandidates @(
    "C:\Program Files\local accessibility vendor\private local-only accessibility\2025\local-accessibility.exe",
    "C:\Program Files\local accessibility vendor\private local-only accessibility\2023\local-accessibility.exe",
    "C:\Program Files (x86)\local accessibility vendor\private local-only accessibility\2025\local-accessibility.exe"
)
$gitBashExe = Resolve-CommandPath -CommandName "git-bash.exe" -FallbackCandidates @(
    "C:\Program Files\Git\git-bash.exe"
)
$pythonExe = Resolve-CommandPath -CommandName "python.exe" -FallbackCandidates @(
    "C:\Python312\python.exe"
)
$nodeExe = Resolve-CommandPath -CommandName "node.exe" -FallbackCandidates @(
    "C:\Program Files\nodejs\node.exe"
)
$wslExe = Resolve-CommandPath -CommandName "wsl.exe" -FallbackCandidates @(
    "C:\Windows\System32\wsl.exe"
)
$dockerExe = Resolve-CommandPath -CommandName "docker.exe" -FallbackCandidates @(
    "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
)
$azExe = Resolve-CommandPath -CommandName "az.cmd" -FallbackCandidates @(
    "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",
    "C:\ProgramData\chocolatey\bin\az.cmd"
)
$azdExe = Resolve-CommandPath -CommandName "azd.exe" -FallbackCandidates @(
    "C:\Program Files\Azure Developer CLI\azd.exe"
)
$ghExe = Resolve-CommandPath -CommandName "gh.exe" -FallbackCandidates @(
    "C:\Program Files\GitHub CLI\gh.exe"
)
$ffmpegExe = Resolve-CommandPath -CommandName "ffmpeg.exe" -FallbackCandidates @(
    "C:\ProgramData\chocolatey\bin\ffmpeg.exe"
)
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
$anyDeskExe = Resolve-CommandPath -CommandName "AnyDesk.exe" -FallbackCandidates @(
    "C:\Program Files (x86)\AnyDesk\AnyDesk.exe",
    "C:\Program Files\AnyDesk\AnyDesk.exe"
)
$windscribeExe = Resolve-CommandPath -CommandName "Windscribe.exe" -FallbackCandidates @(
    "C:\Program Files\Windscribe\Windscribe.exe",
    "C:\Program Files (x86)\Windscribe\Windscribe.exe"
)
$vsCodeExe = Resolve-CommandPath -CommandName "code.exe" -FallbackCandidates @(
    "C:\Program Files\Microsoft VS Code\Code.exe",
    "C:\Users\__VM_ADMIN_USER__\AppData\Local\Programs\Microsoft VS Code\Code.exe",
    "C:\Users\__ASSISTANT_USER__\AppData\Local\Programs\Microsoft VS Code\Code.exe"
)
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

$teamsAppId = Resolve-StoreAppId -NameFragment "teams" -PackageNameHints @("teams")
$windscribeAppId = Resolve-StoreAppId -NameFragment "windscribe" -PackageNameHints @("windscribe")
$whatsAppRootExe = Resolve-AppPackageExecutablePath -NameFragment "whatsapp" -PackageNameHints @("whatsapp", "5319275A.WhatsAppDesktop") -ExecutableName "WhatsApp.Root.exe"

$outlookExe = Resolve-OfficeExecutable -ExeName "OUTLOOK.EXE"
$wordExe = Resolve-OfficeExecutable -ExeName "WINWORD.EXE"
$excelExe = Resolve-OfficeExecutable -ExeName "EXCEL.EXE"
$powerPointExe = Resolve-OfficeExecutable -ExeName "POWERPNT.EXE"
$oneNoteExe = Resolve-OfficeExecutable -ExeName "ONENOTE.EXE"
$controlExe = Resolve-CommandPath -CommandName "control.exe" -FallbackCandidates @("C:\Windows\System32\control.exe")

$whatsAppBusinessTarget = Resolve-ExistingOrFallbackPath -PreferredPath $whatsAppRootExe -ResolvedPath $whatsAppRootExe -FallbackPath $whatsAppFallbackPath
$sevenZipCliPath = Resolve-ExistingOrFallbackPath -PreferredPath "C:\ProgramData\chocolatey\bin\7z.exe" -ResolvedPath $sevenZipExe -FallbackPath "C:\ProgramData\chocolatey\bin\7z.exe"
$codexCmdPath = Resolve-ExistingOrFallbackPath -PreferredPath ("C:\Users\{0}\AppData\Roaming\npm\codex.cmd" -f $managerUser) -ResolvedPath $codexExe -FallbackPath ("C:\Users\{0}\AppData\Roaming\npm\codex.cmd" -f $managerUser)
$geminiCmdPath = Resolve-ExistingOrFallbackPath -PreferredPath ("C:\Users\{0}\AppData\Roaming\npm\gemini.cmd" -f $managerUser) -ResolvedPath $geminiExe -FallbackPath ("C:\Users\{0}\AppData\Roaming\npm\gemini.cmd" -f $managerUser)

Invoke-ShortcutAction -Name "a1ChatGPT Web" -Action { New-DesktopShortcut -Name "a1ChatGPT Web" -TargetPath $chromeTarget -Arguments ($chromeRemoteArgsPrefix + ' "https://chatgpt.com"') -IconLocation "$chromeTarget,0" }
Invoke-ShortcutAction -Name "i0internet" -Action { New-DesktopShortcut -Name "i0internet" -TargetPath $chromeTarget -Arguments ($chromeRemoteArgsPrefix + ' "https://www.google.com"') -IconLocation "$chromeTarget,0" }
Invoke-ShortcutAction -Name "i1WhatsApp Kurumsal" -Action { New-DesktopShortcut -Name "i1WhatsApp Kurumsal" -TargetPath $whatsAppBusinessTarget -AllowMissingTargetPath }
Invoke-ShortcutAction -Name "i2WhatsApp Bireysel" -Action { New-DesktopShortcut -Name "i2WhatsApp Bireysel" -TargetPath $chromeTarget -Arguments ($chromeRemoteArgsPrefix + ' "https://web.whatsapp.com"') -IconLocation "$chromeTarget,0" }
Invoke-ShortcutAction -Name "z1google account setup" -Action { New-DesktopShortcut -Name "z1google account setup" -TargetPath $chromeTarget -Arguments ($chromeSetupArgsPrefix + ' "chrome://settings/syncSetup"') -IconLocation "$chromeTarget,0" }
Invoke-ShortcutAction -Name "z2Office365 account setup" -Action { New-DesktopShortcut -Name "z2Office365 account setup" -TargetPath $chromeTarget -Arguments ($chromeSetupArgsPrefix + ' "https://portal.office.com"') -IconLocation "$chromeTarget,0" }

Invoke-ShortcutAction -Name "b1GarantiBank Bireysel" -Action { New-DesktopShortcut -Name "b1GarantiBank Bireysel" -TargetPath $chromeTarget -Arguments ($chromeBankArgsPrefix + ' "https://sube.garantibbva.com.tr/isube/login/login/passwordentrypersonal-tr"') -IconLocation "$chromeTarget,0" }
Invoke-ShortcutAction -Name "b2GarantiBank Kurumsal" -Action { New-DesktopShortcut -Name "b2GarantiBank Kurumsal" -TargetPath $chromeTarget -Arguments ($chromeBankArgsPrefix + ' "https://sube.garantibbva.com.tr/isube/login/login/passwordentrycorporate-tr"') -IconLocation "$chromeTarget,0" }
Invoke-ShortcutAction -Name "b3QnbBank Bireysel" -Action { New-DesktopShortcut -Name "b3QnbBank Bireysel" -TargetPath $chromeTarget -Arguments ($chromeBankArgsPrefix + ' "https://internetsubesi.qnb.com.tr/Login/LoginPage.aspx"') -IconLocation "$chromeTarget,0" }
Invoke-ShortcutAction -Name "b4QnbBank Kurumsal" -Action { New-DesktopShortcut -Name "b4QnbBank Kurumsal" -TargetPath $chromeTarget -Arguments ($chromeBankArgsPrefix + ' "https://internetsubesi.qnb.com.tr/Login/LoginPage.aspx?FromDK=true"') -IconLocation "$chromeTarget,0" }
Invoke-ShortcutAction -Name "b5AktifBank Bireysel" -Action { New-DesktopShortcut -Name "b5AktifBank Bireysel" -TargetPath $chromeTarget -Arguments ($chromeBankArgsPrefix + ' "https://online.aktifbank.com.tr/default.aspx?lang=tr-TR"') -IconLocation "$chromeTarget,0" }
Invoke-ShortcutAction -Name "b6AktifBank Kurumsal" -Action { New-DesktopShortcut -Name "b6AktifBank Kurumsal" -TargetPath $chromeTarget -Arguments ($chromeBankArgsPrefix + ' "https://kurumsal.aktifbank.com.tr/default.aspx?lang=tr-TR"') -IconLocation "$chromeTarget,0" }
Invoke-ShortcutAction -Name "b7ZiraatBank Bireysel" -Action { New-DesktopShortcut -Name "b7ZiraatBank Bireysel" -TargetPath $chromeTarget -Arguments ($chromeBankArgsPrefix + ' "https://bireysel.ziraatbank.com.tr/Transactions/Login/FirstLogin.aspx"') -IconLocation "$chromeTarget,0" }
Invoke-ShortcutAction -Name "b8ZiraatBank Kurumsal" -Action { New-DesktopShortcut -Name "b8ZiraatBank Kurumsal" -TargetPath $chromeTarget -Arguments ($chromeBankArgsPrefix + ' "https://kurumsal.ziraatbank.com.tr/Transactions/Login/FirstLogin.aspx?customertype=crp"') -IconLocation "$chromeTarget,0" }

Invoke-ShortcutAction -Name "c0cmd" -Action { New-DesktopShortcut -Name "c0cmd" -TargetPath $cmdExe }
Invoke-ShortcutAction -Name "local-only-shortcut" -Action { New-DesktopShortcut -Name "local-only-shortcut" -TargetPath $localOnlyAccessibilityExe }
Invoke-ShortcutAction -Name "a7docker desktop" -Action { New-DesktopShortcut -Name "a7docker desktop" -TargetPath $dockerDesktopExe }

Invoke-ShortcutAction -Name "o0outlook" -Action { New-DesktopShortcut -Name "o0outlook" -TargetPath $outlookExe }
Invoke-ShortcutAction -Name "o1teams" -Action {
    if (-not [string]::IsNullOrWhiteSpace([string]$teamsAppId)) {
        New-DesktopShortcutFromAppId -Name "o1teams" -AppId $teamsAppId
    }
    else {
        $teamsExe = Resolve-CommandPath -CommandName "ms-teams.exe" -FallbackCandidates @(
            "C:\Program Files\WindowsApps\MSTeams_8wekyb3d8bbwe\ms-teams.exe"
        )
        New-DesktopShortcut -Name "o1teams" -TargetPath $teamsExe
    }
}
Invoke-ShortcutAction -Name "o2word" -Action { New-DesktopShortcut -Name "o2word" -TargetPath $wordExe }
Invoke-ShortcutAction -Name "o3excel" -Action { New-DesktopShortcut -Name "o3excel" -TargetPath $excelExe }
Invoke-ShortcutAction -Name "o4power point" -Action { New-DesktopShortcut -Name "o4power point" -TargetPath $powerPointExe }
Invoke-ShortcutAction -Name "o5onenote" -Action { New-DesktopShortcut -Name "o5onenote" -TargetPath $oneNoteExe }

Invoke-ShortcutAction -Name "u7network and sharing" -Action { New-DesktopShortcut -Name "u7network and sharing" -TargetPath $controlExe -Arguments "/name Microsoft.NetworkAndSharingCenter" }

Invoke-ShortcutAction -Name "t0git bash" -Action { New-DesktopShortcut -Name "t0git bash" -TargetPath $gitBashExe }
Invoke-ShortcutAction -Name "t1python cli" -Action { New-ConsoleToolShortcut -Name "t1python cli" -CommandText "python" -IconLocation "$pythonExe,0" }
Invoke-ShortcutAction -Name "t2nodejs cli" -Action { New-ConsoleToolShortcut -Name "t2nodejs cli" -CommandText "node" -IconLocation "$nodeExe,0" }
Invoke-ShortcutAction -Name "t3OllamaApp" -Action { New-CmdWrappedShortcut -Name "t3OllamaApp" -CommandArguments '/c TaskKill -im "ollama app.exe" & "%LOCALAPPDATA%\Programs\Ollama\ollama app.exe"' }
Invoke-ShortcutAction -Name "t4pwsh" -Action { New-DesktopShortcut -Name "t4pwsh" -TargetPath $pwshExe }
Invoke-ShortcutAction -Name "t5ps" -Action { New-DesktopShortcut -Name "t5ps" -TargetPath $powershellExe }
Invoke-ShortcutAction -Name "t6azure-cli" -Action { New-CmdWrappedShortcut -Name "t6azure-cli" -CommandArguments '/k cd /d c:\users\public & az --version' -IconLocation "$azExe,0" -WorkingDirectory "C:\Users\Public" }
Invoke-ShortcutAction -Name "t7wsl" -Action { New-DesktopShortcut -Name "t7wsl" -TargetPath $wslExe }
Invoke-ShortcutAction -Name "t8docker cli" -Action { New-ConsoleToolShortcut -Name "t8docker cli" -CommandText "docker" -IconLocation "$dockerExe,0" }
Invoke-ShortcutAction -Name "t9azd cli" -Action { New-ConsoleToolShortcut -Name "t9azd cli" -CommandText "azd" -IconLocation "$azdExe,0" }
Invoke-ShortcutAction -Name "t10gh cli" -Action { New-ConsoleToolShortcut -Name "t10gh cli" -CommandText "gh" -IconLocation "$ghExe,0" }
Invoke-ShortcutAction -Name "t11ffmpeg cli" -Action { New-ConsoleToolShortcut -Name "t11ffmpeg cli" -CommandText "ffmpeg -version" -IconLocation "$ffmpegExe,0" }
Invoke-ShortcutAction -Name "t12SevenZip-cli" -Action { New-CmdWrappedShortcut -Name "t12SevenZip-cli" -CommandArguments ('/c "{0}"' -f $sevenZipCliPath) -IconLocation "$sevenZipCliPath,0" }
Invoke-ShortcutAction -Name "t13sysinternals" -Action {
    if (-not [string]::IsNullOrWhiteSpace([string]$sysinternalsExe)) {
        New-DesktopShortcut -Name "t13sysinternals" -TargetPath $sysinternalsExe
    }
    else {
        New-ConsoleToolShortcut -Name "t13sysinternals" -CommandText "procexp64"
    }
}
Invoke-ShortcutAction -Name "t14io-unlocker" -Action { New-DesktopShortcut -Name "t14io-unlocker" -TargetPath $ioUnlockerExe }
Invoke-ShortcutAction -Name "t15codex-cli" -Action { New-CmdWrappedShortcut -Name "t15codex-cli" -CommandArguments ('/c start "" "{0}" --enable multi_agent --yolo -s danger-full-access --cd "c:\users\public" --search' -f $codexCmdPath) }
Invoke-ShortcutAction -Name "t16gemini-cli" -Action { New-CmdWrappedShortcut -Name "t16gemini-cli" -CommandArguments ('/c start "" "{0}" --screen-reader --yolo' -f $geminiCmdPath) }

Invoke-ShortcutAction -Name "i8anydesk" -Action { New-DesktopShortcut -Name "i8anydesk" -TargetPath $anyDeskExe }
Invoke-ShortcutAction -Name "i9windscribe" -Action {
    if (-not [string]::IsNullOrWhiteSpace([string]$windscribeExe)) {
        New-DesktopShortcut -Name "i9windscribe" -TargetPath $windscribeExe
    }
    else {
        New-DesktopShortcutFromAppId -Name "i9windscribe" -AppId $windscribeAppId
    }
}
Invoke-ShortcutAction -Name "v5vscode" -Action { New-DesktopShortcut -Name "v5vscode" -TargetPath $vsCodeExe }

Write-Host "windows-ux-public-desktop-shortcuts-completed"
Write-Host "Update task completed: windows-ux-public-desktop-shortcuts"
