$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-whatsapp-system"

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

function Test-WhatsAppInstalledFast {
    $packages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {
        $pkgName = [string]$_.Name
        $pkgFamily = [string]$_.PackageFamilyName
        if ([string]::IsNullOrWhiteSpace([string]$pkgName) -and [string]::IsNullOrWhiteSpace([string]$pkgFamily)) {
            return $false
        }

        $pkgNameLower = $pkgName.ToLowerInvariant()
        $pkgFamilyLower = $pkgFamily.ToLowerInvariant()
        return ($pkgNameLower.Contains('whatsapp') -or $pkgFamilyLower.Contains('whatsapp'))
    })
    if (@($packages).Count -gt 0) {
        return $true
    }

    $startApps = @()
    if (Get-Command Get-StartApps -ErrorAction SilentlyContinue) {
        $startApps = @(Get-StartApps | Where-Object { ([string]$_.Name).ToLowerInvariant().Contains("whatsapp") })
    }
    if (@($startApps).Count -gt 0) {
        return $true
    }

    return $false
}

function Test-WhatsAppInstalled {
    if (Test-WhatsAppInstalledFast) {
        return $true
    }

    Write-Host "Running: winget list whatsapp"
    $listOutput = & $wingetExe list whatsapp
    $listText = [string]($listOutput | Out-String)
    if (-not [string]::IsNullOrWhiteSpace($listText) -and $listText.ToLowerInvariant().Contains("whatsapp")) {
        return $true
    }

    return $false
}

function Register-WhatsAppDeferredInstall {
    param([string]$WingetPath)

    $runOncePath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
    if (-not (Test-Path -LiteralPath $runOncePath)) {
        New-Item -Path $runOncePath -Force | Out-Null
    }

    $commandValue = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "& ''{0}'' install --id 9NKSQGP7F2NH --source msstore --accept-source-agreements --accept-package-agreements --silent --disable-interactivity"' -f $WingetPath)
    Set-ItemProperty -Path $runOncePath -Name "AzVmInstallWhatsApp" -Value $commandValue -Type String
}

function Test-WhatsAppDeferredInstallRegistered {
    $runOncePath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
    if (-not (Test-Path -LiteralPath $runOncePath)) {
        return $false
    }

    $property = Get-ItemProperty -Path $runOncePath -Name "AzVmInstallWhatsApp" -ErrorAction SilentlyContinue
    return ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.AzVmInstallWhatsApp))
}

Refresh-SessionPath
$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    throw "winget command is not available."
}

Write-Host "Resolved winget executable: $wingetExe"
if (Test-WhatsAppInstalledFast) {
    Write-Host "install-whatsapp-system-completed"
    Write-Host "Update task completed: install-whatsapp-system"
    return
}

if (Test-WhatsAppDeferredInstallRegistered) {
    Write-Host "install-whatsapp-system-deferred-already-registered"
    Write-Host "Update task completed: install-whatsapp-system"
    return
}

Write-Host "Running: winget install --id 9NKSQGP7F2NH --source msstore --accept-source-agreements --accept-package-agreements --silent --disable-interactivity"
$installOutput = & $wingetExe install --id 9NKSQGP7F2NH --source msstore --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
$installExit = [int]$LASTEXITCODE
$installText = [string]($installOutput | Out-String)
if (-not [string]::IsNullOrWhiteSpace([string]$installText)) {
    Write-Host $installText.TrimEnd()
}

if (Test-WhatsAppInstalled) {
    Write-Host "install-whatsapp-system-completed"
    Write-Host "Update task completed: install-whatsapp-system"
    return
}

$canDefer = $installText -match '(?i)0x80070520|logon session|microsoft store|msstore'
if ($canDefer) {
    Register-WhatsAppDeferredInstall -WingetPath $wingetExe
    Write-Warning "WhatsApp install could not complete in the current noninteractive session. A RunOnce install was registered for the next interactive sign-in."
    Write-Host "install-whatsapp-system-deferred"
    Write-Host "Update task completed: install-whatsapp-system"
    return
}

if ($installExit -ne 0 -and $installExit -ne -1978335189) {
    throw "winget install whatsapp failed with exit code $installExit."
}

Write-Host "install-whatsapp-system-completed"
Write-Host "Update task completed: install-whatsapp-system"
