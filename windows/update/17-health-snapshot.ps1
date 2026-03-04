$ErrorActionPreference = "Stop"
$sshdConfig = "C:\ProgramData\ssh\sshd_config"
Write-Output "Version Info:"
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    [pscustomobject]@{
        WindowsProductName = [string]$os.Caption
        WindowsVersion = [string]$os.Version
        OsBuildNumber = [string]$os.BuildNumber
    } | Format-List
}
catch {
    Write-Warning ("Version info collection failed: {0}" -f $_.Exception.Message)
}
Write-Output "APP PATH CHECKS:"
foreach ($commandName in @("choco", "git", "node", "python", "py", "pwsh", "gh", "ffmpeg", "7z", "az", "docker", "wsl", "ollama")) {
    $cmd = Get-Command $commandName -ErrorAction SilentlyContinue
    if ($cmd) { Write-Output "$commandName => $($cmd.Source)" } else { Write-Output "$commandName => not-found" }
}
Write-Output "OPEN Ports:"
Get-NetTCPConnection -LocalPort 3389,__SSH_PORT__ -State Listen | Select-Object LocalAddress,LocalPort,OwningProcess | Format-Table -AutoSize
Write-Output "Firewall STATUS:"
Get-NetFirewallProfile | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction | Format-Table -AutoSize
Write-Output "RDP STATUS:"
Get-Service TermService | Select-Object Name,Status,StartType | Format-List
Write-Output "SSHD STATUS:"
Get-Service sshd | Select-Object Name,Status,StartType | Format-List
Write-Output "SSHD CONFIG:"
Get-Content $sshdConfig | Select-String -Pattern "^(Port|PasswordAuthentication|PubkeyAuthentication|PermitEmptyPasswords|AllowTcpForwarding|GatewayPorts)" | ForEach-Object { $_.Line }
Write-Output "POWER STATUS:"
powercfg /getactivescheme
Write-Output "DOCKER STATUS:"
if (Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue) {
    Get-Service -Name "com.docker.service" | Select-Object Name,Status,StartType | Format-List
}
else {
    Write-Output "com.docker.service => not-found"
}
if (Get-Command docker -ErrorAction SilentlyContinue) {
    docker --version
    docker version
}
else {
    Write-Output "docker command not found"
}
Write-Output "WSL STATUS:"
if (Get-Command wsl -ErrorAction SilentlyContinue) {
    wsl --version
}
else {
    Write-Output "wsl command not found"
}
Write-Output "OLLAMA STATUS:"
if (Get-Command ollama -ErrorAction SilentlyContinue) {
    ollama --version
}
else {
    Write-Output "ollama command not found"
}
Write-Output "CHROME SHORTCUT STATUS:"
$chromeShortcutCandidates = @(
    "C:\Users\Public\Desktop\Google Chrome.lnk",
    "C:\Users\__VM_USER__\Desktop\Google Chrome.lnk",
    "C:\Users\__ASSISTANT_USER__\Desktop\Google Chrome.lnk"
)
$wsh = New-Object -ComObject WScript.Shell
foreach ($shortcutPath in @($chromeShortcutCandidates)) {
    if (-not (Test-Path -LiteralPath $shortcutPath)) {
        Write-Output ("missing-shortcut => {0}" -f $shortcutPath)
        continue
    }
    $shortcut = $wsh.CreateShortcut($shortcutPath)
    Write-Output ("shortcut => {0}" -f $shortcutPath)
    Write-Output (" target => {0}" -f [string]$shortcut.TargetPath)
    Write-Output (" args => {0}" -f [string]$shortcut.Arguments)
}
Write-Output "NOTEPAD STATUS:"
if (Test-Path "$env:WINDIR\System32\notepad.exe") { Write-Output "legacy-notepad-exe-found" } else { Write-Output "legacy-notepad-exe-not-found" }
if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
    $notepadPkgs = @(Get-AppxPackage -AllUsers | Where-Object { [string]$_.Name -like "Microsoft.WindowsNotepad*" })
    Write-Output ("modern-notepad-package-count=" + @($notepadPkgs).Count)
}
