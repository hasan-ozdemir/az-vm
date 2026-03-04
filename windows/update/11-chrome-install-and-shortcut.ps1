$ErrorActionPreference = "Stop"

$serverName = "__SERVER_NAME__"
$chromeArgs = "--new-window --start-maximized --disable-extensions --disable-default-apps --no-first-run --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --profile-directory=$serverName https://www.google.com"

function Install-ChromeWithWinget {
    function Resolve-WingetCommand {
        $candidates = @()
        $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            $candidates += [string]$cmd.Source
        }

        $localAlias = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"
        if (Test-Path -LiteralPath $localAlias) {
            $candidates += $localAlias
        }
        foreach ($chocoWingetCandidate in @(
            "$env:ProgramData\chocolatey\bin\winget.exe",
            "$env:ProgramData\chocolatey\lib\winget\tools\winget.exe"
        )) {
            if (Test-Path -LiteralPath $chocoWingetCandidate) {
                $candidates += $chocoWingetCandidate
            }
        }
        foreach ($chocoWingetCandidate in @(
            "$env:ProgramData\chocolatey\bin\winget.exe",
            "$env:ProgramData\chocolatey\lib\winget\tools\winget.exe"
        )) {
            if (Test-Path -LiteralPath $chocoWingetCandidate) {
                $candidates += $chocoWingetCandidate
            }
        }

        try {
            Add-AppxPackage -RegisterByFamilyName -MainPackage "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" -ErrorAction SilentlyContinue | Out-Null
        }
        catch { }
        try {
            $appInstallerPackages = @(Get-AppxPackage -AllUsers -Name "Microsoft.DesktopAppInstaller*" -ErrorAction SilentlyContinue)
            foreach ($pkg in @($appInstallerPackages)) {
                if ([string]::IsNullOrWhiteSpace([string]$pkg.InstallLocation)) {
                    continue
                }
                $pkgWinget = Join-Path ([string]$pkg.InstallLocation) "winget.exe"
                if (Test-Path -LiteralPath $pkgWinget) {
                    $candidates += $pkgWinget
                }
            }
        }
        catch { }

        $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            $candidates += [string]$cmd.Source
        }

        foreach ($candidate in @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)) {
            try {
                & $candidate --version | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    return [string]$candidate
                }
            }
            catch {
                Write-Host ("winget candidate rejected: {0} => {1}" -f $candidate, $_.Exception.Message) -ForegroundColor DarkGray
            }
        }

        return ""
    }

    function Refresh-SessionPath {
        $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
        if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
        $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ([string]::IsNullOrWhiteSpace($userPath)) {
            $env:Path = $machinePath
        }
        else {
            $env:Path = "$machinePath;$userPath"
        }
    }

    $wingetExe = Resolve-WingetCommand
    if (-not [string]::IsNullOrWhiteSpace($wingetExe)) {
        try {
            & $wingetExe install -e --id Google.Chrome --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Null
            if ($LASTEXITCODE -eq 0) {
                return $true
            }
            Write-Warning ("winget install failed for Google.Chrome with exit code {0}." -f $LASTEXITCODE)
        }
        catch {
            Write-Warning ("winget install failed for Google.Chrome: {0}" -f $_.Exception.Message)
        }
    }
    else {
        Write-Host "winget command is not available. Falling back to Chocolatey for Google Chrome." -ForegroundColor DarkGray
    }

    $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (-not (Test-Path -LiteralPath $chocoExe)) {
        Write-Warning "choco command is not available. Google Chrome install step is skipped."
        return $false
    }

    & $chocoExe upgrade googlechrome -y --no-progress --ignore-detected-reboot | Out-Null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
        Write-Warning ("choco upgrade failed for googlechrome with exit code {0}. Trying install." -f $LASTEXITCODE)
        & $chocoExe install googlechrome -y --no-progress --ignore-detected-reboot --ignore-checksums | Out-Null
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
            Write-Warning ("choco install failed for googlechrome with exit code {0}." -f $LASTEXITCODE)
            return $false
        }
    }
    Refresh-SessionPath

    return $true
}

function Resolve-ChromeExecutable {
    $cmd = Get-Command chrome.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        foreach ($candidate in @([string]$cmd.Source, [string]$cmd.Path, [string]$cmd.Definition)) {
            if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
                continue
            }
            if (([System.IO.Path]::IsPathRooted([string]$candidate)) -and (Test-Path -LiteralPath $candidate)) {
                return [string]$candidate
            }
        }
    }

    foreach ($candidate in @(
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return ""
}

function Set-ChromeShortcut {
    param(
        [string]$ShortcutPath,
        [string]$ChromeExe,
        [string]$Args
    )

    if ([string]::IsNullOrWhiteSpace([string]$ChromeExe) -or (-not ([System.IO.Path]::IsPathRooted([string]$ChromeExe))) -or (-not (Test-Path -LiteralPath $ChromeExe))) {
        throw ("Chrome executable path is invalid: '{0}'." -f [string]$ChromeExe)
    }

    $shortcutDir = Split-Path -Path $ShortcutPath -Parent
    if ([string]::IsNullOrWhiteSpace([string]$shortcutDir)) {
        throw ("Shortcut directory is invalid for path '{0}'." -f [string]$ShortcutPath)
    }
    if (-not (Test-Path -LiteralPath $shortcutDir)) {
        New-Item -Path $shortcutDir -ItemType Directory -Force | Out-Null
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $ChromeExe
    $shortcut.Arguments = $Args
    $shortcut.WorkingDirectory = (Split-Path -Path $ChromeExe -Parent)
    $shortcut.IconLocation = "$ChromeExe,0"
    $shortcut.Save()
}

$installed = Install-ChromeWithWinget
$chromeExe = Resolve-ChromeExecutable
if ([string]::IsNullOrWhiteSpace([string]$chromeExe) -or (-not ([System.IO.Path]::IsPathRooted([string]$chromeExe))) -or (-not (Test-Path -LiteralPath $chromeExe))) {
    if ($installed) {
        Write-Warning "Google Chrome install command completed but executable path was not detected."
    }
    else {
        Write-Warning "Google Chrome install failed or was skipped."
    }
    Write-Output "chrome-install-and-shortcut-completed"
    return
}

$shortcutTargets = @(
    "C:\Users\Public\Desktop\Google Chrome.lnk",
    "C:\Users\__VM_USER__\Desktop\Google Chrome.lnk",
    "C:\Users\__ASSISTANT_USER__\Desktop\Google Chrome.lnk"
)
foreach ($shortcutPath in @($shortcutTargets)) {
    try {
        Set-ChromeShortcut -ShortcutPath $shortcutPath -ChromeExe $chromeExe -Args $chromeArgs
        Write-Output ("Chrome shortcut configured: {0}" -f $shortcutPath)
    }
    catch {
        Write-Warning ("Chrome shortcut configuration failed for '{0}': {1}" -f $shortcutPath, $_.Exception.Message)
    }
}

Write-Output "chrome-install-and-shortcut-completed"
