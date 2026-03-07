$ErrorActionPreference = "Stop"
Write-Host "Update task started: windows-ux-public-desktop-shortcuts"

$vmName = "__VM_NAME__"
$publicDesktop = "C:\Users\Public\Desktop"
$chromeArgs = "--new-window --start-maximized --disable-extensions --disable-default-apps --no-first-run --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --profile-directory=$vmName https://www.google.com"

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

    if ($startApps.Count -eq 0) {
        return ""
    }

    foreach ($entry in @($startApps)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.AppID)) {
            return [string]$entry.AppID
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
        [string]$IconLocation = ""
    )

    if ([string]::IsNullOrWhiteSpace([string]$Name)) {
        throw "Shortcut name is empty."
    }
    if ([string]::IsNullOrWhiteSpace([string]$TargetPath)) {
        throw "Shortcut target is empty."
    }
    if (-not (Test-Path -LiteralPath $TargetPath)) {
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
        $shortcut.WorkingDirectory = (Split-Path -Path $TargetPath -Parent)
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
$ollamaExe = Resolve-CommandPath -CommandName "ollama.exe" -FallbackCandidates @(
    "C:\Program Files\Ollama\ollama.exe"
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
    "C:\Program Files\nodejs\codex.cmd",
    "C:\Users\__VM_ADMIN_USER__\AppData\Roaming\npm\codex.cmd",
    "C:\Users\__ASSISTANT_USER__\AppData\Roaming\npm\codex.cmd"
)
$geminiExe = Resolve-CommandPath -CommandName "gemini.cmd" -FallbackCandidates @(
    "C:\Program Files\nodejs\gemini.cmd",
    "C:\Users\__VM_ADMIN_USER__\AppData\Roaming\npm\gemini.cmd",
    "C:\Users\__ASSISTANT_USER__\AppData\Roaming\npm\gemini.cmd"
)

$whatsAppAppId = Resolve-StartAppId -NameFragment "whatsapp"
$teamsAppId = Resolve-StartAppId -NameFragment "teams"
$windscribeAppId = Resolve-StartAppId -NameFragment "windscribe"

$outlookExe = Resolve-OfficeExecutable -ExeName "OUTLOOK.EXE"
$wordExe = Resolve-OfficeExecutable -ExeName "WINWORD.EXE"
$excelExe = Resolve-OfficeExecutable -ExeName "EXCEL.EXE"
$powerPointExe = Resolve-OfficeExecutable -ExeName "POWERPNT.EXE"
$oneNoteExe = Resolve-OfficeExecutable -ExeName "ONENOTE.EXE"
$controlExe = Resolve-CommandPath -CommandName "control.exe" -FallbackCandidates @("C:\Windows\System32\control.exe")

Invoke-ShortcutAction -Name "i0internet" -Action { New-DesktopShortcut -Name "i0internet" -TargetPath $chromeExe -Arguments $chromeArgs -IconLocation "$chromeExe,0" }
Invoke-ShortcutAction -Name "c0cmd" -Action { New-DesktopShortcut -Name "c0cmd" -TargetPath $cmdExe }
Invoke-ShortcutAction -Name "i7whatsapp" -Action { New-DesktopShortcutFromAppId -Name "i7whatsapp" -AppId $whatsAppAppId }
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

Invoke-ShortcutAction -Name "t0-git bash" -Action { New-DesktopShortcut -Name "t0-git bash" -TargetPath $gitBashExe }
Invoke-ShortcutAction -Name "t1-python cli" -Action { New-ConsoleToolShortcut -Name "t1-python cli" -CommandText "python" -IconLocation "$pythonExe,0" }
Invoke-ShortcutAction -Name "t2-nodejs cli" -Action { New-ConsoleToolShortcut -Name "t2-nodejs cli" -CommandText "node" -IconLocation "$nodeExe,0" }
Invoke-ShortcutAction -Name "t3-ollama app" -Action {
    if (-not [string]::IsNullOrWhiteSpace([string]$ollamaExe)) {
        New-DesktopShortcut -Name "t3-ollama app" -TargetPath $ollamaExe
    }
    else {
        New-ConsoleToolShortcut -Name "t3-ollama app" -CommandText "ollama"
    }
}
Invoke-ShortcutAction -Name "t4-pwsh" -Action { New-DesktopShortcut -Name "t4-pwsh" -TargetPath $pwshExe }
Invoke-ShortcutAction -Name "t5-ps" -Action { New-DesktopShortcut -Name "t5-ps" -TargetPath $powershellExe }
Invoke-ShortcutAction -Name "t6-azure cli" -Action { New-ConsoleToolShortcut -Name "t6-azure cli" -CommandText "az" -IconLocation "$azExe,0" }
Invoke-ShortcutAction -Name "t7-wsl" -Action { New-DesktopShortcut -Name "t7-wsl" -TargetPath $wslExe }
Invoke-ShortcutAction -Name "t8-docker cli" -Action { New-ConsoleToolShortcut -Name "t8-docker cli" -CommandText "docker" -IconLocation "$dockerExe,0" }
Invoke-ShortcutAction -Name "t9-azd cli" -Action { New-ConsoleToolShortcut -Name "t9-azd cli" -CommandText "azd" -IconLocation "$azdExe,0" }
Invoke-ShortcutAction -Name "t10-gh cli" -Action { New-ConsoleToolShortcut -Name "t10-gh cli" -CommandText "gh" -IconLocation "$ghExe,0" }
Invoke-ShortcutAction -Name "t11-ffmpeg cli" -Action { New-ConsoleToolShortcut -Name "t11-ffmpeg cli" -CommandText "ffmpeg -version" -IconLocation "$ffmpegExe,0" }
Invoke-ShortcutAction -Name "t12-7zip cli" -Action {
    if (-not [string]::IsNullOrWhiteSpace([string]$sevenZipExe)) {
        New-DesktopShortcut -Name "t12-7zip cli" -TargetPath $sevenZipExe
    }
    else {
        New-ConsoleToolShortcut -Name "t12-7zip cli" -CommandText "7z"
    }
}
Invoke-ShortcutAction -Name "t13-sysinternals" -Action {
    if (-not [string]::IsNullOrWhiteSpace([string]$sysinternalsExe)) {
        New-DesktopShortcut -Name "t13-sysinternals" -TargetPath $sysinternalsExe
    }
    else {
        New-ConsoleToolShortcut -Name "t13-sysinternals" -CommandText "procexp64"
    }
}
Invoke-ShortcutAction -Name "t14-io-unlocker" -Action { New-DesktopShortcut -Name "t14-io-unlocker" -TargetPath $ioUnlockerExe }
Invoke-ShortcutAction -Name "t15-codex cli" -Action {
    if (-not [string]::IsNullOrWhiteSpace([string]$codexExe)) {
        New-DesktopShortcut -Name "t15-codex cli" -TargetPath $codexExe
    }
    else {
        New-ConsoleToolShortcut -Name "t15-codex cli" -CommandText "codex"
    }
}
Invoke-ShortcutAction -Name "t16-gemini cli" -Action {
    if (-not [string]::IsNullOrWhiteSpace([string]$geminiExe)) {
        New-DesktopShortcut -Name "t16-gemini cli" -TargetPath $geminiExe
    }
    else {
        New-ConsoleToolShortcut -Name "t16-gemini cli" -CommandText "gemini"
    }
}

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
