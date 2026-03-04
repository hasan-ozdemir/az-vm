$ErrorActionPreference = "Stop"

function Invoke-DockerWarn {
    param(
        [string]$Label,
        [scriptblock]$Action
    )

    try {
        & $Action
        Write-Output ("docker-step-ok: {0}" -f $Label)
    }
    catch {
        Write-Warning ("docker-step-failed: {0} => {1}" -f $Label, $_.Exception.Message)
    }
}

Invoke-DockerWarn -Label "winget-install-docker-desktop" -Action {
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

    $installed = $false
    $wingetExe = Resolve-WingetCommand
    if (-not [string]::IsNullOrWhiteSpace($wingetExe)) {
        try {
            & $wingetExe install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $installed = $true
            }
            else {
                Write-Host ("winget install failed for Docker.DockerDesktop with exit code {0}." -f $LASTEXITCODE) -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Host ("winget install failed for Docker.DockerDesktop: {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
        }
    }

    if (-not $installed) {
        $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
        if (-not (Test-Path -LiteralPath $chocoExe)) {
            throw "Neither winget nor choco is available for Docker Desktop installation."
        }

        & $chocoExe upgrade docker-desktop -y --no-progress | Out-Null
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
            throw ("choco install failed for docker-desktop with exit code {0}." -f $LASTEXITCODE)
        }
        Refresh-SessionPath
    }
}

Invoke-DockerWarn -Label "set-com-docker-service-automatic" -Action {
    if (Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue) {
        Set-Service -Name "com.docker.service" -StartupType Automatic
        Start-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
    }
    else {
        Write-Warning "com.docker.service was not found."
    }
}

Invoke-DockerWarn -Label "configure-docker-startup-shortcut" -Action {
    $dockerDesktopExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (-not (Test-Path -LiteralPath $dockerDesktopExe)) { throw "Docker Desktop executable not found." }
    $startupPath = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\Docker Desktop.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($startupPath)
    $shortcut.TargetPath = $dockerDesktopExe
    $shortcut.Arguments = "--minimized"
    $shortcut.WorkingDirectory = (Split-Path -Path $dockerDesktopExe -Parent)
    $shortcut.IconLocation = "$dockerDesktopExe,0"
    $shortcut.Save()
}

Invoke-DockerWarn -Label "configure-docker-settings-json" -Action {
    $profileRoots = @(
        "C:\Users\__VM_USER__",
        "C:\Users\__ASSISTANT_USER__",
        "C:\Users\Default"
    )
    foreach ($profileRoot in @($profileRoots)) {
        $roamingPath = Join-Path $profileRoot "AppData\Roaming\Docker"
        if (-not (Test-Path -LiteralPath $roamingPath)) {
            New-Item -Path $roamingPath -ItemType Directory -Force | Out-Null
        }

        $settingsPaths = @(
            (Join-Path $roamingPath "settings-store.json"),
            (Join-Path $roamingPath "settings.json")
        )
        $settingsPath = $settingsPaths[0]
        $settings = @{}
        foreach ($candidate in @($settingsPaths)) {
            if (Test-Path -LiteralPath $candidate) {
                $settingsPath = $candidate
                $raw = Get-Content -Path $candidate -Raw -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $parsed = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($parsed) {
                        $settings = @{}
                        foreach ($prop in $parsed.PSObject.Properties) {
                            $settings[$prop.Name] = $prop.Value
                        }
                    }
                }
                break
            }
        }

        $settings["autoStart"] = $true
        $settings["startMinimized"] = $true
        $settings["openUIOnStartupDisabled"] = $true
        $settings["displayedOnboarding"] = $true
        $settings["wslEngineEnabled"] = $true

        ($settings | ConvertTo-Json -Depth 20) | Set-Content -Path $settingsPath -Encoding UTF8
    }
}

Invoke-DockerWarn -Label "docker-users-group-membership" -Action {
    if (-not (Get-LocalGroup -Name "docker-users" -ErrorAction SilentlyContinue)) {
        New-LocalGroup -Name "docker-users" -Description "Docker Desktop Users" -ErrorAction SilentlyContinue | Out-Null
    }

    foreach ($localUser in @("__VM_USER__", "__ASSISTANT_USER__")) {
        if ([string]::IsNullOrWhiteSpace([string]$localUser)) { continue }
        try {
            Add-LocalGroupMember -Group "docker-users" -Member $localUser -ErrorAction Stop
        }
        catch {
            if ($_.Exception.Message -notmatch '(?i)already a member') {
                Write-Warning ("docker-users membership failed for '{0}': {1}" -f $localUser, $_.Exception.Message)
            }
        }
    }
}

Invoke-DockerWarn -Label "docker-client-version" -Action {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "docker command is not available." }
    & docker --version
}

Invoke-DockerWarn -Label "docker-daemon-version" -Action {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "docker command is not available." }
    $daemonReady = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $daemonCommandThrew = $false
        try {
            & docker version 2>$null
        }
        catch {
            $daemonCommandThrew = $true
        }

        if ((-not $daemonCommandThrew) -and ($LASTEXITCODE -eq 0)) {
            $daemonReady = $true
            break
        }

        if ($attempt -lt 3) {
            Start-Sleep -Seconds 5
        }
    }

    if (-not $daemonReady) {
        Write-Output "docker-daemon-version-deferred"
    }
}

Write-Output "docker-desktop-install-and-configure-completed"
