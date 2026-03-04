$ErrorActionPreference = "Stop"
Write-Host "Update task started: chrome-install-and-shortcut"

$serverName = "__SERVER_NAME__"
$chromeArgs = "--new-window --start-maximized --disable-extensions --disable-default-apps --no-first-run --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --profile-directory=$serverName https://www.google.com"

function Refresh-SessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path -LiteralPath $refreshEnvCmd) { cmd.exe /d /c "`"$refreshEnvCmd`"" }
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
}

function Resolve-WingetCommand {
    $candidates = @()
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) { $candidates += [string]$cmd.Source }

    foreach ($candidate in @(
        "$env:ProgramData\chocolatey\bin\winget.exe",
        "$env:ProgramData\chocolatey\lib\winget\tools\winget.exe",
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe")
    )) {
        if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        try {
            & $candidate --version
            if ($LASTEXITCODE -eq 0) { return [string]$candidate }
        }
        catch {
            Write-Warning "winget candidate rejected: $candidate => $($_.Exception.Message)"
        }
    }

    return ""
}

function Resolve-ChromeExecutable {
    $cmd = Get-Command chrome.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        foreach ($candidate in @([string]$cmd.Source, [string]$cmd.Path, [string]$cmd.Definition)) {
            if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
            if ([System.IO.Path]::IsPathRooted([string]$candidate) -and (Test-Path -LiteralPath $candidate)) {
                return [string]$candidate
            }
        }
    }

    foreach ($candidate in @(
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    )) {
        if (Test-Path -LiteralPath $candidate) { return [string]$candidate }
    }

    return ""
}

function Set-ChromeShortcut {
    param(
        [string]$ShortcutPath,
        [string]$ChromeExe,
        [string]$Args
    )

    $shortcutDir = Split-Path -Path $ShortcutPath -Parent
    if (-not (Test-Path -LiteralPath $shortcutDir)) { New-Item -Path $shortcutDir -ItemType Directory -Force }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $ChromeExe
    $shortcut.Arguments = $Args
    $shortcut.WorkingDirectory = (Split-Path -Path $ChromeExe -Parent)
    $shortcut.IconLocation = "$ChromeExe,0"
    $shortcut.Save()
}

$installed = $false
$wingetExe = Resolve-WingetCommand
if (-not [string]::IsNullOrWhiteSpace($wingetExe)) {
    Write-Host "Running: winget install -e --id Google.Chrome"
    & $wingetExe install -e --id Google.Chrome --accept-source-agreements --accept-package-agreements --disable-interactivity
    if ($LASTEXITCODE -eq 0) {
        $installed = $true
    }
    else {
        Write-Warning "winget install Google.Chrome failed with exit code $LASTEXITCODE."
    }
}

if (-not $installed) {
    $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (-not (Test-Path -LiteralPath $chocoExe)) {
        throw "Neither winget nor choco is available for Google Chrome installation."
    }

    Write-Host "Running: choco upgrade googlechrome"
    & $chocoExe upgrade googlechrome -y --no-progress --ignore-detected-reboot --ignore-checksums
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
        Write-Host "Running: choco install googlechrome"
        & $chocoExe install googlechrome -y --no-progress --ignore-detected-reboot --ignore-checksums
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
            throw "Google Chrome installation failed with exit code $LASTEXITCODE."
        }
    }
}

Refresh-SessionPath

$chromeExe = Resolve-ChromeExecutable
if ([string]::IsNullOrWhiteSpace([string]$chromeExe)) {
    throw "Google Chrome executable path was not detected after installation."
}

$shortcutTargets = @(
    "C:\Users\Public\Desktop\Google Chrome.lnk",
    "C:\Users\__VM_USER__\Desktop\Google Chrome.lnk",
    "C:\Users\__ASSISTANT_USER__\Desktop\Google Chrome.lnk"
)

foreach ($shortcutPath in @($shortcutTargets)) {
    Set-ChromeShortcut -ShortcutPath $shortcutPath -ChromeExe $chromeExe -Args $chromeArgs
    Write-Host "Chrome shortcut configured: $shortcutPath"
}

Write-Host "chrome-install-and-shortcut-completed"
Write-Host "Update task completed: chrome-install-and-shortcut"
