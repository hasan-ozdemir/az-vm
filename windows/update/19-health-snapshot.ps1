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
Get-NetTCPConnection -LocalPort 3389,__SSH_PORT__ -State Listen | Select-Object LocalAddress,LocalPort,OwningProcess | Format-Table -AutoSize
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
        Write-Warning "docker --version failed or timed out"
    }

    $dockerDaemon = Invoke-CommandWithTimeout -TimeoutSeconds 20 -Action { docker version }
    if (-not $dockerDaemon.Success) {
        if ($dockerDaemon.TimedOut) { Write-Warning "docker version timed out" } else { Write-Warning "docker version failed" }
    }
}
else {
    Write-Host "docker command not found"
}

Write-Host "WSL STATUS:"
if (Get-Command wsl -ErrorAction SilentlyContinue) {
    $wslVersion = Invoke-CommandWithTimeout -TimeoutSeconds 15 -Action { wsl --version }
    if (-not $wslVersion.Success) {
        if ($wslVersion.TimedOut) { Write-Warning "wsl --version timed out" } else { Write-Warning "wsl --version failed" }
    }
}
else {
    Write-Host "wsl command not found"
}

Write-Host "OLLAMA STATUS:"
if (Get-Command ollama -ErrorAction SilentlyContinue) {
    $ollamaStatus = Invoke-CommandWithTimeout -TimeoutSeconds 10 -Action { ollama --version }
    if (-not $ollamaStatus.Success) {
        Write-Warning "ollama --version failed or timed out"
    }
}
else {
    Write-Host "ollama command not found"
}

Write-Host "CHROME SHORTCUT STATUS:"
$chromeShortcutCandidates = @(
    "C:\Users\Public\Desktop\Google Chrome.lnk",
    "C:\Users\__VM_USER__\Desktop\Google Chrome.lnk",
    "C:\Users\__ASSISTANT_USER__\Desktop\Google Chrome.lnk"
)
$wsh = New-Object -ComObject WScript.Shell
foreach ($shortcutPath in @($chromeShortcutCandidates)) {
    if (-not (Test-Path -LiteralPath $shortcutPath)) {
        Write-Host "missing-shortcut => $shortcutPath"
        continue
    }

    $shortcut = $wsh.CreateShortcut($shortcutPath)
    Write-Host "shortcut => $shortcutPath"
    Write-Host " target => $([string]$shortcut.TargetPath)"
    Write-Host " args => $([string]$shortcut.Arguments)"
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
