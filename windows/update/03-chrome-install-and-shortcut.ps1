$ErrorActionPreference = "Stop"
# CO_VM_TASK_TIMEOUT_SECONDS=1800
Write-Host "Update task started: chrome-install-and-shortcut"

$serverName = "__SERVER_NAME__"
$chromeArgs = "--new-window --start-maximized --disable-extensions --disable-default-apps --no-first-run --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --profile-directory=$serverName https://www.google.com"

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

function Resolve-ChocoExecutable {
    $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (Test-Path -LiteralPath $chocoExe) {
        return [string]$chocoExe
    }

    $cmd = Get-Command choco -ErrorAction SilentlyContinue
    if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        return [string]$cmd.Source
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
        if (Test-Path -LiteralPath $candidate) {
            return [string]$candidate
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

    $shortcutDir = Split-Path -Path $ShortcutPath -Parent
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

Refresh-SessionPath

$chocoExe = Resolve-ChocoExecutable
if ([string]::IsNullOrWhiteSpace($chocoExe)) {
    throw "choco command is not available. Google Chrome install requires Chocolatey."
}

Write-Host "Resolved choco executable: $chocoExe"
Write-Host "Running: choco upgrade googlechrome -y --no-progress --ignore-detected-reboot --ignore-checksums"
& $chocoExe upgrade googlechrome -y --no-progress --ignore-detected-reboot --ignore-checksums
$chocoExit = [int]$LASTEXITCODE
if ($chocoExit -ne 0 -and $chocoExit -ne 2) {
    throw "choco upgrade googlechrome failed with exit code $chocoExit."
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
