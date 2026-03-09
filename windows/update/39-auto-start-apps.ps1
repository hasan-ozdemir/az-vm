$ErrorActionPreference = "Stop"
Write-Host "Update task started: auto-start-apps"

$managerUser = "__VM_ADMIN_USER__"
$machineStartupFolder = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
$startupApprovedPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"

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

function Ensure-StartupFolderExists {
    if (-not (Test-Path -LiteralPath $machineStartupFolder)) {
        New-Item -Path $machineStartupFolder -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $startupApprovedPath)) {
        New-Item -Path $startupApprovedPath -Force | Out-Null
    }
}

function Ensure-StartupShortcutApproval {
    param([string]$ShortcutFileName)

    if ([string]::IsNullOrWhiteSpace([string]$ShortcutFileName)) {
        return
    }

    $enabledValue = [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    New-ItemProperty -Path $startupApprovedPath -Name $ShortcutFileName -PropertyType Binary -Value $enabledValue -Force | Out-Null
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
    }
}

function Test-ShortcutMatches {
    param(
        [string]$ShortcutPath,
        [string]$TargetPath,
        [string]$Arguments = ""
    )

    $contract = Get-ShortcutContract -ShortcutPath $ShortcutPath
    if ($null -eq $contract) {
        return $false
    }

    return (
        [string]::Equals([string]$contract.TargetPath, [string]$TargetPath, [System.StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$contract.Arguments, [string]$Arguments, [System.StringComparison]::Ordinal)
    )
}

function New-StartupShortcut {
    param(
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

    Ensure-StartupFolderExists

    $shortcutPath = Join-Path $machineStartupFolder ($Name + ".lnk")
    $tempShortcutPath = Join-Path $machineStartupFolder (("az-vm-startup-{0}.lnk" -f [System.Guid]::NewGuid().ToString("N")))
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

    $shortcut.Save()
    Move-Item -LiteralPath $tempShortcutPath -Destination $shortcutPath -Force
    Ensure-StartupShortcutApproval -ShortcutFileName ($Name + ".lnk")
}

function Ensure-StartupShortcut {
    param(
        [string]$Name,
        [string]$TargetPath,
        [string]$Arguments = "",
        [string]$WorkingDirectory = "",
        [string]$IconLocation = ""
    )

    $shortcutPath = Join-Path $machineStartupFolder ($Name + ".lnk")
    if (Test-ShortcutMatches -ShortcutPath $shortcutPath -TargetPath $TargetPath -Arguments $Arguments) {
        Ensure-StartupShortcutApproval -ShortcutFileName ($Name + ".lnk")
        Write-Host ("autostart-ok: {0} => already-configured" -f $Name)
        return
    }

    New-StartupShortcut -Name $Name -TargetPath $TargetPath -Arguments $Arguments -WorkingDirectory $WorkingDirectory -IconLocation $IconLocation
    Write-Host ("autostart-ok: {0}" -f $Name)
}

Refresh-SessionPath

$cmdExe = Resolve-CommandPath -CommandName "cmd.exe" -FallbackCandidates @("C:\Windows\System32\cmd.exe")
$dockerDesktopExe = Resolve-CommandPath -CommandName "Docker Desktop.exe" -FallbackCandidates @("C:\Program Files\Docker\Docker\Docker Desktop.exe")
$localOnlyAccessibilityExe = Resolve-CommandPath -CommandName "local-accessibility.exe" -FallbackCandidates @(
    "C:\Program Files\local accessibility vendor\private local-only accessibility\2025\local-accessibility.exe",
    "C:\Program Files\local accessibility vendor\private local-only accessibility\2023\local-accessibility.exe",
    "C:\Program Files (x86)\local accessibility vendor\private local-only accessibility\2025\local-accessibility.exe"
)
$iTunesHelperExe = Resolve-CommandPath -CommandName "iTunesHelper.exe" -FallbackCandidates @(
    "C:\Program Files\iTunes\iTunesHelper.exe",
    "C:\Program Files (x86)\iTunes\iTunesHelper.exe"
)
$oneDriveExe = Resolve-CommandPath -CommandName "OneDrive.exe" -FallbackCandidates @(
    "C:\Program Files\Microsoft OneDrive\OneDrive.exe",
    ("C:\Users\{0}\AppData\Local\Microsoft\OneDrive\OneDrive.exe" -f $managerUser)
)
$teamsExe = Resolve-CommandPath -CommandName "ms-teams.exe" -FallbackCandidates @(
    "C:\Program Files\WindowsApps\MSTeams_8wekyb3d8bbwe\ms-teams.exe",
    ("C:\Users\{0}\AppData\Local\Microsoft\WindowsApps\MSTeams_8wekyb3d8bbwe\ms-teams.exe" -f $managerUser)
)
$ollamaAppExe = Resolve-CommandPath -CommandName "ollama app.exe" -FallbackCandidates @(
    ("C:\Users\{0}\AppData\Local\Programs\Ollama\ollama app.exe" -f $managerUser),
    (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe')
)

# Static startup snapshot captured from the local operator machine on 2026-03-09.
$staticStartupAppKeys = @(
    'docker-desktop',
    'ollama',
    'onedrive',
    'teams',
    'private local-only accessibility',
    'itunes-helper'
)

Write-Host ("static-startup-snapshot => {0}" -f ($staticStartupAppKeys -join ', '))

$startupSpecs = [ordered]@{
    'docker-desktop' = [pscustomobject]@{
        Name = 'Docker Desktop'
        TargetPath = $dockerDesktopExe
        Arguments = '--minimized'
        WorkingDirectory = if ([string]::IsNullOrWhiteSpace([string]$dockerDesktopExe)) { '' } else { Split-Path -Path $dockerDesktopExe -Parent }
        IconLocation = if ([string]::IsNullOrWhiteSpace([string]$dockerDesktopExe)) { '' } else { "$dockerDesktopExe,0" }
    }
    'ollama' = [pscustomobject]@{
        Name = 'Ollama'
        TargetPath = $cmdExe
        Arguments = '/c if exist "%LOCALAPPDATA%\Programs\Ollama\ollama app.exe" start "" "%LOCALAPPDATA%\Programs\Ollama\ollama app.exe"'
        WorkingDirectory = 'C:\Users'
        IconLocation = if ([string]::IsNullOrWhiteSpace([string]$ollamaAppExe)) { '' } else { "$ollamaAppExe,0" }
    }
    'onedrive' = [pscustomobject]@{
        Name = 'OneDrive'
        TargetPath = $oneDriveExe
        Arguments = '/background'
        WorkingDirectory = if ([string]::IsNullOrWhiteSpace([string]$oneDriveExe)) { '' } else { Split-Path -Path $oneDriveExe -Parent }
        IconLocation = if ([string]::IsNullOrWhiteSpace([string]$oneDriveExe)) { '' } else { "$oneDriveExe,0" }
    }
    'teams' = [pscustomobject]@{
        Name = 'Teams'
        TargetPath = if (-not [string]::IsNullOrWhiteSpace([string]$teamsExe) -and -not $teamsExe.ToLowerInvariant().Contains('\users\')) { $teamsExe } else { $cmdExe }
        Arguments = if (-not [string]::IsNullOrWhiteSpace([string]$teamsExe) -and -not $teamsExe.ToLowerInvariant().Contains('\users\')) { 'msteams:system-initiated' } else { '/c start "" ms-teams.exe msteams:system-initiated' }
        WorkingDirectory = if (-not [string]::IsNullOrWhiteSpace([string]$teamsExe) -and -not $teamsExe.ToLowerInvariant().Contains('\users\')) { Split-Path -Path $teamsExe -Parent } else { 'C:\Users' }
        IconLocation = if ([string]::IsNullOrWhiteSpace([string]$teamsExe)) { '' } else { "$teamsExe,0" }
    }
    'private local-only accessibility' = [pscustomobject]@{
        Name = 'private local-only accessibility'
        TargetPath = $localOnlyAccessibilityExe
        Arguments = '/run'
        WorkingDirectory = if ([string]::IsNullOrWhiteSpace([string]$localOnlyAccessibilityExe)) { '' } else { Split-Path -Path $localOnlyAccessibilityExe -Parent }
        IconLocation = if ([string]::IsNullOrWhiteSpace([string]$localOnlyAccessibilityExe)) { '' } else { "$localOnlyAccessibilityExe,0" }
    }
    'itunes-helper' = [pscustomobject]@{
        Name = 'iTunesHelper'
        TargetPath = $iTunesHelperExe
        Arguments = ''
        WorkingDirectory = if ([string]::IsNullOrWhiteSpace([string]$iTunesHelperExe)) { '' } else { Split-Path -Path $iTunesHelperExe -Parent }
        IconLocation = if ([string]::IsNullOrWhiteSpace([string]$iTunesHelperExe)) { '' } else { "$iTunesHelperExe,0" }
    }
}

$failures = @()
foreach ($startupAppKey in @($staticStartupAppKeys)) {
    if (-not $startupSpecs.Contains($startupAppKey)) {
        Write-Warning ("autostart-skip: unknown static app key '{0}'." -f $startupAppKey)
        continue
    }

    $spec = $startupSpecs[$startupAppKey]
    $targetPath = [string]$spec.TargetPath
    if ([string]::IsNullOrWhiteSpace([string]$targetPath) -or -not (Test-Path -LiteralPath $targetPath)) {
        Write-Warning ("autostart-skip: {0} => guest target path was not found." -f [string]$spec.Name)
        continue
    }

    try {
        Ensure-StartupShortcut `
            -Name ([string]$spec.Name) `
            -TargetPath $targetPath `
            -Arguments ([string]$spec.Arguments) `
            -WorkingDirectory ([string]$spec.WorkingDirectory) `
            -IconLocation ([string]$spec.IconLocation)
    }
    catch {
        $failures += ("{0}: {1}" -f [string]$spec.Name, $_.Exception.Message)
        Write-Warning ("autostart-fail: {0} => {1}" -f [string]$spec.Name, $_.Exception.Message)
    }
}

if (@($failures).Count -gt 0) {
    throw ("One or more startup apps could not be configured: {0}" -f ($failures -join ' | '))
}

Write-Host "auto-start-apps-completed"
Write-Host "Update task completed: auto-start-apps"
