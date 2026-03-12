$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-codex-app"

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

function Resolve-WingetExe {
    $portableCandidate = "C:\ProgramData\az-vm\tools\winget-x64\winget.exe"
    if (Test-Path -LiteralPath $portableCandidate) {
        return [string]$portableCandidate
    }

    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        return [string]$cmd.Source
    }

    return ""
}

function Get-CodexPackages {
    $allPackages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
    if (@($allPackages).Count -eq 0) {
        return @()
    }

    return @(
        $allPackages | Where-Object {
            $pkgName = [string]$_.Name
            $pkgFamily = [string]$_.PackageFamilyName
            if ([string]::IsNullOrWhiteSpace([string]$pkgName) -and [string]::IsNullOrWhiteSpace([string]$pkgFamily)) {
                return $false
            }

            $pkgNameLower = $pkgName.ToLowerInvariant()
            $pkgFamilyLower = $pkgFamily.ToLowerInvariant()
            return (
                $pkgNameLower.Contains("openai.codex") -or
                $pkgFamilyLower.Contains("openai.codex") -or
                $pkgNameLower.Contains("codex") -or
                $pkgFamilyLower.Contains("codex")
            )
        }
    )
}

function Resolve-CodexExecutable {
    $preferredCandidate = Join-Path $env:ProgramFiles "WindowsApps\OpenAI.Codex_26.306.996.0_x64__2p2nqsd0c76g0\app\Codex.exe"
    if (Test-Path -LiteralPath $preferredCandidate) {
        return [string]$preferredCandidate
    }

    foreach ($package in @(Get-CodexPackages)) {
        $installLocation = [string]$package.InstallLocation
        if ([string]::IsNullOrWhiteSpace([string]$installLocation)) {
            continue
        }

        foreach ($candidate in @(
            (Join-Path $installLocation "app\Codex.exe"),
            (Join-Path $installLocation "Codex.exe")
        )) {
            if (Test-Path -LiteralPath $candidate) {
                return [string]$candidate
            }
        }
    }

    return ""
}

function Test-CodexInstalled {
    param([string]$WingetExe)

    $codexExe = Resolve-CodexExecutable
    if (-not [string]::IsNullOrWhiteSpace([string]$codexExe)) {
        return $true
    }

    $packages = @(Get-CodexPackages)
    if (@($packages).Count -gt 0) {
        return $true
    }

    if (Get-Command Get-StartApps -ErrorAction SilentlyContinue) {
        $startApps = @(Get-StartApps | Where-Object {
            $nameText = [string]$_.Name
            if ([string]::IsNullOrWhiteSpace([string]$nameText)) {
                return $false
            }

            return $nameText.ToLowerInvariant().Contains("codex")
        })
        if (@($startApps).Count -gt 0) {
            return $true
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$WingetExe)) {
        Write-Host "Running: winget list codex"
        $listOutput = & $WingetExe list codex
        $listText = [string]($listOutput | Out-String)
        if (-not [string]::IsNullOrWhiteSpace([string]$listText)) {
            $normalizedList = $listText.ToLowerInvariant()
            if ($normalizedList.Contains("codex") -or $normalizedList.Contains("openai")) {
                return $true
            }
        }
    }

    return $false
}

function Register-CodexDeferredInstall {
    param([string]$WingetPath)

    $runOncePath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
    if (-not (Test-Path -LiteralPath $runOncePath)) {
        New-Item -Path $runOncePath -Force | Out-Null
    }

    $commandValue = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "& ''{0}'' install codex -s msstore --accept-source-agreements --accept-package-agreements --silent --disable-interactivity"' -f $WingetPath)
    Set-ItemProperty -Path $runOncePath -Name "AzVmInstallCodexApp" -Value $commandValue -Type String
}

Refresh-SessionPath
$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    throw "winget command is not available."
}

Write-Host "Resolved winget executable: $wingetExe"
if (Test-CodexInstalled -WingetExe $wingetExe) {
    Write-Host "Existing Codex app installation is already healthy. Skipping winget install."
    Write-Host "install-codex-app-completed"
    Write-Host "Update task completed: install-codex-app"
    return
}

Write-Host "Running: winget install codex -s msstore --accept-source-agreements --accept-package-agreements --silent --disable-interactivity"
$installOutput = & $wingetExe install codex -s msstore --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
$installExit = [int]$LASTEXITCODE
$installText = [string]($installOutput | Out-String)
if (-not [string]::IsNullOrWhiteSpace([string]$installText)) {
    Write-Host $installText.TrimEnd()
}

Refresh-SessionPath
if (Test-CodexInstalled -WingetExe $wingetExe) {
    Write-Host "install-codex-app-completed"
    Write-Host "Update task completed: install-codex-app"
    return
}

$canDefer = $installText -match '(?i)0x80070520|logon session|microsoft store|msstore'
if ($canDefer) {
    Register-CodexDeferredInstall -WingetPath $wingetExe
    Write-Warning "Codex app install could not complete in the current noninteractive session. A RunOnce install was registered for the next interactive sign-in."
    Write-Host "install-codex-app-deferred"
    Write-Host "Update task completed: install-codex-app"
    return
}

if ($installExit -ne 0 -and $installExit -ne -1978335189) {
    throw "winget install codex failed with exit code $installExit."
}

throw "Codex app install could not be verified."
