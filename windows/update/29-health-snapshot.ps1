$ErrorActionPreference = "Stop"
Write-Host "Update task started: health-snapshot"

function Invoke-CommandWithTimeout {
    param(
        [scriptblock]$Action,
        [int]$TimeoutSeconds = 20
    )

    $job = Start-Job -ScriptBlock $Action
    $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if (-not $completed) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force
        return [pscustomobject]@{ Success = $false; TimedOut = $true }
    }

    $jobReceiveErrors = @()
    $output = Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobReceiveErrors
    if ($output) {
        $output | ForEach-Object { Write-Host ([string]$_) }
    }
    if (@($jobReceiveErrors).Count -gt 0) {
        foreach ($jobError in @($jobReceiveErrors)) {
            Write-Warning ([string]$jobError)
        }
    }

    $state = $job.ChildJobs[0].JobStateInfo.State
    $hadErrors = @($job.ChildJobs[0].Error).Count -gt 0
    Remove-Job -Job $job -Force
    return [pscustomobject]@{ Success = ($state -ne 'Failed' -and -not $hadErrors); TimedOut = $false }
}

$sshdConfig = "C:\ProgramData\ssh\sshd_config"
Write-Host "Version Info:"
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    Write-Host "WindowsProductName=$($os.Caption)"
    Write-Host "WindowsVersion=$($os.Version)"
    Write-Host "OsBuildNumber=$($os.BuildNumber)"
}
catch {
    Write-Warning "Version info collection failed: $($_.Exception.Message)"
}

Write-Host "APP PATH CHECKS:"
foreach ($commandName in @("choco", "git", "node", "python", "py", "pwsh", "gh", "ffmpeg", "7z", "az", "docker", "wsl", "ollama")) {
    $cmd = Get-Command $commandName -ErrorAction SilentlyContinue
    if ($cmd) { Write-Host "$commandName => $($cmd.Source)" } else { Write-Host "$commandName => not-found" }
}

Write-Host "OPEN Ports:"
Get-NetTCPConnection -LocalPort __RDP_PORT__,__SSH_PORT__ -State Listen | Select-Object LocalAddress,LocalPort,OwningProcess | Format-Table -AutoSize
Write-Host "Firewall STATUS:"
Get-NetFirewallProfile | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction | Format-Table -AutoSize
Write-Host "RDP STATUS:"
Get-Service TermService | Select-Object Name,Status,StartType | Format-List
Write-Host "SSHD STATUS:"
Get-Service sshd | Select-Object Name,Status,StartType | Format-List

Write-Host "SSHD CONFIG:"
if (Test-Path -LiteralPath $sshdConfig) {
    Get-Content $sshdConfig | Select-String -Pattern "^(Port|PasswordAuthentication|PubkeyAuthentication|PermitEmptyPasswords|AllowTcpForwarding|GatewayPorts)" | ForEach-Object { Write-Host $_.Line }
}
else {
    Write-Host "sshd config file not found"
}

Write-Host "POWER STATUS:"
powercfg /getactivescheme

Write-Host "DOCKER STATUS:"
if (Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue) {
    Get-Service -Name "com.docker.service" | Select-Object Name,Status,StartType | Format-List
}
else {
    Write-Host "com.docker.service => not-found"
}

if (Get-Command docker -ErrorAction SilentlyContinue) {
    $dockerCli = Invoke-CommandWithTimeout -TimeoutSeconds 15 -Action { docker --version }
    if (-not $dockerCli.Success) {
        Write-Warning "docker --version did not complete successfully"
    }

    $dockerDaemon = Invoke-CommandWithTimeout -TimeoutSeconds 20 -Action { docker version }
    if (-not $dockerDaemon.Success) {
        Write-Warning "docker version did not complete successfully"
    }
}
else {
    Write-Host "docker command not found"
}

Write-Host "WSL STATUS:"
if (Get-Command wsl -ErrorAction SilentlyContinue) {
    $wslVersion = Invoke-CommandWithTimeout -TimeoutSeconds 15 -Action { wsl --version }
    if (-not $wslVersion.Success) {
        Write-Warning "wsl --version did not complete successfully"
    }
}
else {
    Write-Host "wsl command not found"
}

Write-Host "OLLAMA STATUS:"
if (Get-Command ollama -ErrorAction SilentlyContinue) {
    $ollamaStatus = Invoke-CommandWithTimeout -TimeoutSeconds 10 -Action { ollama --version }
    if (-not $ollamaStatus.Success) {
        Write-Warning "ollama --version did not complete successfully"
    }
}
else {
    Write-Host "ollama command not found"
}

Write-Host "PUBLIC DESKTOP SHORTCUT STATUS:"
$pwshExe = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
$q1EksisozlukName = ("q1Ek{0}iS{1}zl{2}k" -f [char]0x015F, [char]0x00F6, [char]0x00FC)

if (-not ("AzVmNativePaths" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class AzVmNativePaths {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetShortPathName(string lpszLongPath, StringBuilder lpszShortPath, uint cchBuffer);
}
"@
}

function Convert-StringToCharCodeLiteral {
    param([string]$Value)

    $codes = @()
    if ($null -ne $Value) {
        $codes = @([int[]][char[]][string]$Value)
    }

    if (@($codes).Count -eq 0) {
        return '@()'
    }

    return ('@(' + (($codes | ForEach-Object { [string]$_ }) -join ',') + ')')
}

function Get-ShortcutDetailsViaPwsh {
    param([string]$ShortcutPath)

    if ([string]::IsNullOrWhiteSpace([string]$pwshExe) -or [string]::IsNullOrWhiteSpace([string]$ShortcutPath)) {
        return $null
    }

    $shortcutChars = Convert-StringToCharCodeLiteral -Value $ShortcutPath
    $scriptText = @"
`$shortcutPath = -join ($shortcutChars | ForEach-Object { [char]`$_ })
`$shell = New-Object -ComObject WScript.Shell
`$shortcut = `$shell.CreateShortcut(`$shortcutPath)
[pscustomobject]@{
    TargetPath = [string]`$shortcut.TargetPath
    Arguments = [string]`$shortcut.Arguments
    Hotkey = [string]`$shortcut.Hotkey
} | ConvertTo-Json -Compress
"@

    $json = & $pwshExe -NoProfile -Command $scriptText
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$json)) {
        return $null
    }

    return ($json | ConvertFrom-Json -ErrorAction Stop)
}

function Get-ShortcutDetailsViaShellApplication {
    param([string]$ShortcutPath)

    if ([string]::IsNullOrWhiteSpace([string]$ShortcutPath) -or -not (Test-Path -LiteralPath $ShortcutPath)) {
        return $null
    }

    $shellApp = New-Object -ComObject Shell.Application
    $parentPath = Split-Path -Path $ShortcutPath -Parent
    $leafName = Split-Path -Path $ShortcutPath -Leaf
    $folder = $shellApp.Namespace($parentPath)
    if ($null -eq $folder) {
        return $null
    }

    $item = $folder.ParseName($leafName)
    if ($null -eq $item) {
        return $null
    }

    try {
        $link = $item.GetLink()
        return [pscustomobject]@{
            TargetPath = [string]$link.Path
            Arguments = [string]$link.Arguments
            Hotkey = [string]$link.Hotkey
        }
    }
    catch {
        return $null
    }
}

function Get-ShortPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace([string]$Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    $builder = New-Object System.Text.StringBuilder 4096
    $result = [AzVmNativePaths]::GetShortPathName([string]$Path, $builder, [uint32]$builder.Capacity)
    if ($result -eq 0) {
        return ""
    }

    return [string]$builder.ToString()
}

function Get-ShortcutDetails {
    param(
        [string]$ShortcutName,
        [string]$ShortcutPath,
        [object]$ShellObject
    )

    $details = $null
    if ($ShortcutName -cmatch '[^\u0000-\u007F]') {
        $details = Get-ShortcutDetailsViaShellApplication -ShortcutPath $ShortcutPath
        if ($null -eq $details) {
            $details = Get-ShortcutDetailsViaPwsh -ShortcutPath $ShortcutPath
        }
    }

    if ($null -eq $details) {
        $details = $ShellObject.CreateShortcut($ShortcutPath)
    }

    $targetPath = [string]$details.TargetPath
    $arguments = [string]$details.Arguments
    $hotkey = [string]$details.Hotkey
    if (($ShortcutName -cmatch '[^\u0000-\u007F]') -and [string]::IsNullOrWhiteSpace([string]$targetPath)) {
        $shortPath = Get-ShortPath -Path $ShortcutPath
        if (-not [string]::IsNullOrWhiteSpace([string]$shortPath)) {
            $fallbackDetails = $ShellObject.CreateShortcut($shortPath)
            $targetPath = [string]$fallbackDetails.TargetPath
            $arguments = [string]$fallbackDetails.Arguments
            $hotkey = [string]$fallbackDetails.Hotkey
        }
    }

    return [pscustomobject]@{
        TargetPath = [string]$targetPath
        Arguments = [string]$arguments
        Hotkey = [string]$hotkey
    }
}
$publicShortcutNames = @(
    "a1ChatGPT Web",
    "a2Be My Eyes",
    "a3CodexApp",
    "a7Docker Desktop",
    "a10NVDA",
    "a11MS Edge",
    "a14VLC Player",
    "a17Itunes",
    "b1GarantiBank Bireysel",
    "b2GarantiBank Kurumsal",
    "b3QnbBank Bireysel",
    "b4QnbBank Kurumsal",
    "b5AktifBank Bireysel",
    "b6AktifBank Kurumsal",
    "b7ZiraatBank Bireysel",
    "b8ZiraatBank Kurumsal",
    "c0Cmd",
    "d0Rclone CLI",
    "d1One Drive",
    "d2Google Drive",
    "i0Internet",
    "i1WhatsApp Kurumsal",
    "i2WhatsApp Bireysel",
    "i8AnyDesk",
    "i9Windscribe",
    "local-only-shortcut",
    "o0Outlook",
    "o1Teams",
    "o2Word",
    "o3Excel",
    "o4Power Point",
    "o5OneNote",
    $q1EksisozlukName,
    "s1LinkedIn Kurumsal",
    "s2LinkedIn Bireysel",
    "s3YouTube Kurumsal",
    "s4YouTube Bireysel",
    "s5GitHub Kurumsal",
    "s6GitHub Bireysel",
    "s7TikTok Kurumsal",
    "s8TikTok Bireysel",
    "s9Instagram Kurumsal",
    "s10Instagram Bireysel",
    "s11Facebook Kurumsal",
    "s12Facebook Bireysel",
    "s13X-Twitter Kurumsal",
    "s14X-Twitter Bireysel",
    "s15Web Sitesi Kurumsal",
    "s16Blog Sitesi Kurumsal",
    "t0Git Bash",
    "t1Python CLI",
    "t2Nodejs CLI",
    "t3Ollama App",
    "t4Pwsh",
    "t5PS",
    "t6Azure CLI",
    "t7WSL",
    "t8Docker CLI",
    "t9AZD CLI",
    "t10GH CLI",
    "t11FFmpeg CLI",
    "t12SevenZip CLI",
    "t13Sysinternals",
    "t14Io Unlocker",
    "t15Codex CLI",
    "t16Gemini CLI",
    "u7Network and Sharing",
    "v5VS Code",
    "z1Google Account Setup",
    "z2Office365 Account Setup"
)
$publicDesktop = "C:\Users\Public\Desktop"
$wsh = New-Object -ComObject WScript.Shell
foreach ($shortcutName in @($publicShortcutNames)) {
    $shortcutPath = Join-Path $publicDesktop ($shortcutName + ".lnk")
    if (-not (Test-Path -LiteralPath $shortcutPath)) {
        Write-Host "missing-shortcut => $shortcutPath"
        continue
    }

    $shortcut = Get-ShortcutDetails -ShortcutName $shortcutName -ShortcutPath $shortcutPath -ShellObject $wsh
    Write-Host "shortcut => $shortcutPath"
    Write-Host " target => $([string]$shortcut.TargetPath)"
    Write-Host " args => $([string]$shortcut.Arguments)"
    Write-Host " hotkey => $([string]$shortcut.Hotkey)"
}

Write-Host "AUTO-START APP STATUS:"
$hostStartupProfileJsonBase64 = "__HOST_STARTUP_PROFILE_JSON_B64__"
$machineStartupFolder = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
$expectedStartupShortcutNames = @()
try {
    $startupProfileJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$hostStartupProfileJsonBase64))
    $startupProfile = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$startupProfileJson)) {
        $startupProfile = @(ConvertFrom-Json -InputObject $startupProfileJson -ErrorAction Stop)
    }

    foreach ($entry in @($startupProfile)) {
        switch ([string]$entry.Key) {
            'docker-desktop' { $expectedStartupShortcutNames += 'Docker Desktop' }
            'ollama' { $expectedStartupShortcutNames += 'Ollama' }
            'onedrive' { $expectedStartupShortcutNames += 'OneDrive' }
            'teams' { $expectedStartupShortcutNames += 'Teams' }
            'private local-only accessibility' { $expectedStartupShortcutNames += 'private local-only accessibility' }
            'itunes-helper' { $expectedStartupShortcutNames += 'iTunesHelper' }
            'google-drive' { $expectedStartupShortcutNames += 'Google Drive' }
            'windscribe' { $expectedStartupShortcutNames += 'Windscribe' }
            'anydesk' { $expectedStartupShortcutNames += 'AnyDesk' }
            'codex-app' { $expectedStartupShortcutNames += 'Codex App' }
        }
    }
}
catch {
    Write-Warning ("startup-profile-decode-failed => {0}" -f $_.Exception.Message)
}

foreach ($startupShortcutName in @($expectedStartupShortcutNames | Select-Object -Unique)) {
    $startupShortcutPath = Join-Path $machineStartupFolder ($startupShortcutName + ".lnk")
    if (-not (Test-Path -LiteralPath $startupShortcutPath)) {
        Write-Host "missing-startup-shortcut => $startupShortcutPath"
        continue
    }

    $startupShortcut = Get-ShortcutDetails -ShortcutName $startupShortcutName -ShortcutPath $startupShortcutPath -ShellObject $wsh
    Write-Host "startup-shortcut => $startupShortcutPath"
    Write-Host " target => $([string]$startupShortcut.TargetPath)"
    Write-Host " args => $([string]$startupShortcut.Arguments)"
    Write-Host " hotkey => $([string]$startupShortcut.Hotkey)"
}

Write-Host "NOTEPAD STATUS:"
if (Test-Path "$env:WINDIR\System32\notepad.exe") {
    Write-Host "legacy-notepad-exe-found"
}
else {
    Write-Host "legacy-notepad-exe-not-found"
}

if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
    $notepadPkgs = @(Get-AppxPackage -AllUsers | Where-Object { [string]$_.Name -like "Microsoft.WindowsNotepad*" })
    Write-Host ("modern-notepad-package-count=" + @($notepadPkgs).Count)
}

Write-Host "health-snapshot-completed"
Write-Host "Update task completed: health-snapshot"
