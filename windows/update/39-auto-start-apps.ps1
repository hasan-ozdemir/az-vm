$ErrorActionPreference = "Stop"
Write-Host "Update task started: auto-start-apps"

$managerUser = "__VM_ADMIN_USER__"
$hostStartupProfileJsonBase64 = "__HOST_STARTUP_PROFILE_JSON_B64__"
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
$googleDriveExe = Resolve-CommandPath -CommandName "GoogleDriveFS.exe" -FallbackCandidates @("C:\Program Files\Google\Drive File Stream\GoogleDriveFS.exe")
if ([string]::IsNullOrWhiteSpace([string]$googleDriveExe)) {
    $googleDriveExe = Resolve-ExecutableUnderDirectory -RootPaths @("C:\Program Files\Google\Drive File Stream") -ExecutableName "GoogleDriveFS.exe"
}
$windscribeExe = Resolve-CommandPath -CommandName "Windscribe.exe" -FallbackCandidates @(
    "C:\Program Files\Windscribe\Windscribe.exe",
    "C:\Program Files (x86)\Windscribe\Windscribe.exe"
)
$anyDeskExe = Resolve-CommandPath -CommandName "AnyDesk.exe" -FallbackCandidates @(
    "C:\Program Files\AnyDesk\AnyDesk.exe",
    "C:\Program Files (x86)\AnyDesk\AnyDesk.exe"
)
$codexAppExe = Resolve-AppPackageExecutablePath -NameFragment "codex" -PackageNameHints @("OpenAI.Codex", "2p2nqsd0c76g0") -ExecutableName "Codex.exe"
if ([string]::IsNullOrWhiteSpace([string]$codexAppExe)) {
    $codexAppExe = "C:\Program Files\WindowsApps\OpenAI.Codex_26.306.996.0_x64__2p2nqsd0c76g0\app\Codex.exe"
}

$hostStartupProfile = @(Convert-Base64JsonToObjectArray -Base64Text $hostStartupProfileJsonBase64)
$requestedKeys = @(
    $hostStartupProfile |
        ForEach-Object { [string]$_.Key } |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -Unique
)

if (@($requestedKeys).Count -eq 0) {
    Write-Host "No enabled mirrored startup apps were found on the host profile. Skipping."
    Write-Host "auto-start-apps-completed"
    Write-Host "Update task completed: auto-start-apps"
    return
}

Write-Host ("host-startup-profile => {0}" -f ($requestedKeys -join ', '))

$supportedSpecs = [ordered]@{
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
    'google-drive' = [pscustomobject]@{
        Name = 'Google Drive'
        TargetPath = $googleDriveExe
        Arguments = ''
        WorkingDirectory = if ([string]::IsNullOrWhiteSpace([string]$googleDriveExe)) { '' } else { Split-Path -Path $googleDriveExe -Parent }
        IconLocation = if ([string]::IsNullOrWhiteSpace([string]$googleDriveExe)) { '' } else { "$googleDriveExe,0" }
    }
    'windscribe' = [pscustomobject]@{
        Name = 'Windscribe'
        TargetPath = $windscribeExe
        Arguments = ''
        WorkingDirectory = if ([string]::IsNullOrWhiteSpace([string]$windscribeExe)) { '' } else { Split-Path -Path $windscribeExe -Parent }
        IconLocation = if ([string]::IsNullOrWhiteSpace([string]$windscribeExe)) { '' } else { "$windscribeExe,0" }
    }
    'anydesk' = [pscustomobject]@{
        Name = 'AnyDesk'
        TargetPath = $anyDeskExe
        Arguments = ''
        WorkingDirectory = if ([string]::IsNullOrWhiteSpace([string]$anyDeskExe)) { '' } else { Split-Path -Path $anyDeskExe -Parent }
        IconLocation = if ([string]::IsNullOrWhiteSpace([string]$anyDeskExe)) { '' } else { "$anyDeskExe,0" }
    }
    'codex-app' = [pscustomobject]@{
        Name = 'Codex App'
        TargetPath = $codexAppExe
        Arguments = ''
        WorkingDirectory = if ([string]::IsNullOrWhiteSpace([string]$codexAppExe)) { '' } else { Split-Path -Path $codexAppExe -Parent }
        IconLocation = if ([string]::IsNullOrWhiteSpace([string]$codexAppExe)) { '' } else { "$codexAppExe,0" }
    }
}

$failures = @()
foreach ($requestedKey in @($requestedKeys)) {
    if (-not $supportedSpecs.Contains($requestedKey)) {
        Write-Warning ("autostart-skip: unsupported host app key '{0}'." -f $requestedKey)
        continue
    }

    $spec = $supportedSpecs[$requestedKey]
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
