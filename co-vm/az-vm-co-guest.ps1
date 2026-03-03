function Get-CoVmLinuxCloudInitContent {
    param(
        [string]$VmUser,
        [string]$VmPass
    )

    $template = @'
#cloud-config
package_update: true
package_upgrade: false
timezone: UTC
users:
  - default
  - name: __VM_USER__
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
chpasswd:
  expire: false
  users:
    - name: __VM_USER__
      password: __VM_PASS__
ssh_pwauth: true
'@

    return $template.Replace("__VM_USER__", $VmUser).Replace("__VM_PASS__", $VmPass)
}

function Get-CoVmWindowsInitScriptContent {
    return @'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Output "Init phase started."
Set-TimeZone -Id "UTC" -ErrorAction SilentlyContinue
Write-Output "Init phase completed."
'@
}

function Get-CoVmGuestTaskTemplates {
    param(
        [ValidateSet("linux", "windows")]
        [string]$Platform,
        [string]$VmInitScriptFile
    )

    if ($Platform -eq "linux") {
        return @(
            [pscustomobject]@{
                Name = "00-ensure-linux-user-passwords"
                Script = @'
set -euo pipefail
VM_USER="__VM_USER__"
VM_PASS="__VM_PASS__"
ASSISTANT_USER="__ASSISTANT_USER__"
ASSISTANT_PASS="__ASSISTANT_PASS__"
if ! id -u "${VM_USER}" >/dev/null 2>&1; then
  sudo useradd -m -s /bin/bash "${VM_USER}"
fi
if ! id -u "${ASSISTANT_USER}" >/dev/null 2>&1; then
  sudo useradd -m -s /bin/bash "${ASSISTANT_USER}"
fi
echo "${VM_USER}:${VM_PASS}" | sudo chpasswd
echo "${ASSISTANT_USER}:${ASSISTANT_PASS}" | sudo chpasswd
echo "root:${VM_PASS}" | sudo chpasswd
sudo passwd -u "${VM_USER}" || true
sudo passwd -u "${ASSISTANT_USER}" || true
sudo passwd -u root || true
sudo chage -E -1 "${VM_USER}" || true
sudo chage -E -1 "${ASSISTANT_USER}" || true
sudo chage -E -1 root || true
for ADMIN_USER in "${VM_USER}" "${ASSISTANT_USER}"; do
  sudo usermod -aG sudo "${ADMIN_USER}" || true
  echo "${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/90-${ADMIN_USER}-nopasswd" >/dev/null
  sudo chmod 440 "/etc/sudoers.d/90-${ADMIN_USER}-nopasswd"
done
echo "linux-user-passwords-ready"
'@
            },
            [pscustomobject]@{
                Name = "01-packages-update-install"
                Script = @'
set -euo pipefail
sudo DEBIAN_FRONTEND=noninteractive apt update -y
sudo DEBIAN_FRONTEND=noninteractive apt install --upgrade -y apt-utils ufw nodejs npm git curl python-is-python3 python3-venv
echo "linux-packages-ready"
'@
            },
            [pscustomobject]@{
                Name = "02-sshd-config-port"
                Script = @'
set -euo pipefail
SSHD_CONFIG="/etc/ssh/sshd_config"
sudo sed -i -E 's/^#?Port .*/Port __SSH_PORT__/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?PasswordAuthentication .*/PasswordAuthentication yes/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?PubkeyAuthentication .*/PubkeyAuthentication no/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?PermitRootLogin .*/PermitRootLogin yes/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?AllowTcpForwarding .*/AllowTcpForwarding yes/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?GatewayPorts .*/GatewayPorts yes/' "${SSHD_CONFIG}"
echo "linux-sshd-config-ready"
'@
            },
            [pscustomobject]@{
                Name = "03-firewall-rules"
                Script = @'
set -euo pipefail
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
TCP_PORTS=(__TCP_PORTS_BASH__)
for PORT in "${TCP_PORTS[@]}"; do
  sudo ufw allow "${PORT}/tcp"
done
sudo ufw --force enable
echo "linux-firewall-ready"
'@
            },
            [pscustomobject]@{
                Name = "04-node-sshd-capabilities"
                Script = @'
set -euo pipefail
sudo setcap 'cap_net_bind_service=+ep' /usr/bin/node || true
sudo setcap 'cap_net_bind_service=+ep' /usr/sbin/sshd || true
echo "linux-capabilities-ready"
'@
            },
            [pscustomobject]@{
                Name = "05-sshd-service-restart"
                Script = @'
set -euo pipefail
sudo systemctl daemon-reload
sudo systemctl disable --now ssh.socket || true
sudo systemctl unmask ssh.service || true
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh.service
echo "linux-sshd-service-ready"
'@
            },
            [pscustomobject]@{
                Name = "06-health-snapshot"
                Script = @'
set -euo pipefail
SSHD_CONFIG="/etc/ssh/sshd_config"
echo "Version Info:"
lsb_release -a || true
echo "OPEN Ports:"
ss -tlnp | grep -E ':(__TCP_PORTS_REGEX__)\b' || true
echo "Firewall STATUS:"
sudo ufw status verbose
echo "SSHD CONFIG:"
grep -E "^(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|AllowTcpForwarding|GatewayPorts)" "${SSHD_CONFIG}" || true
'@
            }
        )
    }

    if ([string]::IsNullOrWhiteSpace($VmInitScriptFile)) {
        throw "VmInitScriptFile is required for windows task templates."
    }
    if (-not (Test-Path -LiteralPath $VmInitScriptFile)) {
        throw "VM init script file was not found: $VmInitScriptFile"
    }

    $vmInitBody = Get-Content -Path $VmInitScriptFile -Raw
    return @(
        [pscustomobject]@{
            Name = "00-init-script"
            Script = $vmInitBody
        },
        [pscustomobject]@{
            Name = "01-ensure-local-admin-user"
            Script = @'
$ErrorActionPreference = "Stop"
$vmUser = "__VM_USER__"
$vmPass = "__VM_PASS__"
$assistantUser = "__ASSISTANT_USER__"
$assistantPass = "__ASSISTANT_PASS__"

function Ensure-GroupMembership {
    param(
        [string]$GroupName,
        [string]$MemberName
    )

    function Normalize-Identity {
        param(
            [string]$Value
        )

        if ([string]::IsNullOrWhiteSpace($Value)) {
            return ""
        }

        return $Value.Trim().ToLowerInvariant()
    }

    $shortMember = [string]$MemberName
    if ($MemberName -match '^[^\\]+\\(.+)$') {
        $shortMember = [string]$Matches[1]
    }

    $memberAliases = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @(
        $MemberName,
        $shortMember,
        "$env:COMPUTERNAME\$shortMember",
        ".\$shortMember"
    )) {
        $normalizedCandidate = Normalize-Identity -Value ([string]$candidate)
        if (-not [string]::IsNullOrWhiteSpace($normalizedCandidate)) {
            [void]$memberAliases.Add($normalizedCandidate)
        }
    }

    $alreadyMember = $false
    try {
        $members = Get-LocalGroupMember -Group $GroupName -ErrorAction Stop
        foreach ($member in $members) {
            $existingMember = Normalize-Identity -Value ([string]$member.Name)
            if ($memberAliases.Contains($existingMember)) {
                $alreadyMember = $true
                break
            }
        }
    }
    catch {
        $groupOutput = net localgroup "$GroupName" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $groupOutputText = (@($groupOutput) | ForEach-Object { [string]$_ }) -join "`n"
            $escapedShortMember = [regex]::Escape($shortMember)
            $escapedFullMember = [regex]::Escape($MemberName)
            if (
                $groupOutputText -match ("(?im)^\s*(?:.+\\)?{0}\s*$" -f $escapedShortMember) -or
                $groupOutputText -match ("(?im)^\s*{0}\s*$" -f $escapedFullMember)
            ) {
                $alreadyMember = $true
            }
        }
    }

    if ($alreadyMember) {
        Write-Output "User '$MemberName' is already in local group '$GroupName'."
        return
    }

    $lastAddExitCode = 1
    $addCandidates = @(
        $MemberName,
        $shortMember,
        ".\$shortMember"
    )
    $addTried = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($addCandidate in @($addCandidates)) {
        if ([string]::IsNullOrWhiteSpace([string]$addCandidate)) {
            continue
        }

        if (-not $addTried.Add([string]$addCandidate)) {
            continue
        }

        net localgroup "$GroupName" $addCandidate /add | Out-Null
        $lastAddExitCode = $LASTEXITCODE

        if ($lastAddExitCode -eq 0) {
            Write-Output "User '$addCandidate' was added to local group '$GroupName'."
            return
        }

        if ($lastAddExitCode -eq 1378) {
            Write-Output "User '$addCandidate' is already in local group '$GroupName' (system error 1378)."
            return
        }
    }

    if ($lastAddExitCode -ne 0) {
        throw "Adding '$MemberName' to '$GroupName' failed with exit code $lastAddExitCode."
    }
}

function Ensure-LocalPowerAdmin {
    param(
        [string]$UserName,
        [string]$Password
    )

    if (-not (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
        $securePass = ConvertTo-SecureString $Password -AsPlainText -Force
        New-LocalUser -Name $UserName -Password $securePass -PasswordNeverExpires -AccountNeverExpires -FullName $UserName -Description "Azure VM Power Admin user" | Out-Null
    }
    else {
        net user $UserName $Password | Out-Null
    }
    Ensure-GroupMembership -GroupName "Administrators" -MemberName $UserName
    Ensure-GroupMembership -GroupName "Remote Desktop Users" -MemberName $UserName
}

Ensure-LocalPowerAdmin -UserName $vmUser -Password $vmPass
Ensure-LocalPowerAdmin -UserName $assistantUser -Password $assistantPass
Write-Output "local-admin-users-ready"
'@
        },
        [pscustomobject]@{
            Name = "02-openssh-install-service"
            Script = @'
$ErrorActionPreference = "Stop"
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (-not (Test-Path $chocoExe)) {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString("https://community.chocolatey.org/install.ps1"))
    }
    $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (-not (Test-Path $chocoExe)) { throw "choco was not found." }
    & $chocoExe upgrade openssh -y --no-progress | Out-Null
    $openSshExit = $LASTEXITCODE
    if ($openSshExit -ne 0 -and $openSshExit -ne 2) { throw "choco upgrade openssh failed with exit code $openSshExit." }

    if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
        foreach ($installScript in @(
            "C:\Program Files\OpenSSH-Win64\install-sshd.ps1",
            "C:\ProgramData\chocolatey\lib\openssh\tools\install-sshd.ps1"
        )) {
            if (Test-Path $installScript) {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript | Out-Null
                break
            }
        }
    }
}
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) { throw "OpenSSH setup completed but sshd service was not found." }
Set-Service -Name sshd -StartupType Automatic
if (Get-Service ssh-agent -ErrorAction SilentlyContinue) { Set-Service -Name ssh-agent -StartupType Automatic }
Write-Output "openssh-ready"
'@
        },
        [pscustomobject]@{
            Name = "03-sshd-config-port"
            Script = @'
$ErrorActionPreference = "Stop"
$sshdConfig = "C:\ProgramData\ssh\sshd_config"
if (-not (Test-Path $sshdConfig)) { New-Item -Path $sshdConfig -ItemType File -Force | Out-Null }
$content = @(Get-Content -Path $sshdConfig -ErrorAction SilentlyContinue)
function Set-OrAdd([string]$Key,[string]$Value) {
    $regex = "^\s*#?\s*" + [regex]::Escape($Key) + "\s+.*$"
    $replacement = "$Key $Value"
    $updated = $false
    for ($i = 0; $i -lt $content.Count; $i++) {
        if ($content[$i] -match $regex) {
            $content[$i] = $replacement
            $updated = $true
        }
    }
    if (-not $updated) { $script:content += $replacement }
}
Set-OrAdd -Key "Port" -Value "__SSH_PORT__"
Set-OrAdd -Key "PasswordAuthentication" -Value "yes"
Set-OrAdd -Key "PubkeyAuthentication" -Value "no"
Set-OrAdd -Key "PermitEmptyPasswords" -Value "no"
Set-OrAdd -Key "AllowTcpForwarding" -Value "yes"
Set-OrAdd -Key "GatewayPorts" -Value "yes"
Set-Content -Path $sshdConfig -Value $content -Encoding ascii
New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name "DefaultShell" -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
Restart-Service -Name sshd -Force
if (-not (Get-NetFirewallRule -DisplayName "Allow-SSH-__SSH_PORT__" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow-SSH-__SSH_PORT__" -Direction Inbound -Action Allow -Protocol TCP -LocalPort __SSH_PORT__ -RemoteAddress Any -Profile Any | Out-Null
}
Write-Output "sshd-config-ready"
'@
        },
        [pscustomobject]@{
            Name = "04-rdp-firewall"
            Script = @'
$ErrorActionPreference = "Stop"
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 0
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "SecurityLayer" -Value 1
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "MinEncryptionLevel" -Value 2
if (-not (Get-NetFirewallRule -DisplayName "Allow-TCP-3389" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow-TCP-3389" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -RemoteAddress Any -Profile Any | Out-Null
}
Set-Service -Name TermService -StartupType Automatic
sc.exe start TermService | Out-Null
$svcWait = [System.Diagnostics.Stopwatch]::StartNew()
do {
    Start-Sleep -Seconds 2
    $svc = Get-Service -Name TermService -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { break }
} while ($svcWait.Elapsed.TotalSeconds -lt 60)
if (-not $svc -or $svc.Status -ne "Running") {
    throw "TermService did not reach Running state within 60 seconds."
}
foreach ($port in @(__TCP_PORTS_PS_ARRAY__)) {
    $name = "Allow-TCP-$port"
    if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress Any -Profile Any | Out-Null
    }
}
Write-Output "rdp-firewall-ready"
'@
        },
        [pscustomobject]@{
            Name = "05-choco-bootstrap"
            Script = @'
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString("https://community.chocolatey.org/install.ps1"))
}
$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) { throw "choco setup could not be completed." }
& $chocoExe feature enable -n allowGlobalConfirmation | Out-Null
& $chocoExe feature enable -n useRememberedArgumentsForUpgrades | Out-Null
& $chocoExe feature enable -n useEnhancedExitCodes | Out-Null
& $chocoExe config set --name commandExecutionTimeoutSeconds --value 14400 | Out-Null
& $chocoExe config set --name cacheLocation --value "$env:ProgramData\chocolatey\cache" | Out-Null
$refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
& $chocoExe --version
'@
        },
        [pscustomobject]@{
            Name = "06-git-install-check"
            Script = @'
$ErrorActionPreference = "Stop"
$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) { throw "choco was not found." }
& $chocoExe upgrade git -y --no-progress | Out-Null
$refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $existing = @()
    if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
        $existing = $machinePath -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    foreach ($candidate in @("C:\Program Files\Git\cmd","C:\Program Files\Git\bin")) {
        if ((Test-Path $candidate) -and ($existing -notcontains $candidate)) { $existing += $candidate }
    }
    [Environment]::SetEnvironmentVariable("Path", ($existing -join ';'), "Machine")
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "git command was not found." }
git --version
'@
        },
        [pscustomobject]@{
            Name = "07-python-install-check"
            Script = @'
$ErrorActionPreference = "Stop"
$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) { throw "choco was not found." }
& $chocoExe upgrade python312 -y --no-progress | Out-Null
$refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    $existing = @()
    if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
        $existing = $machinePath -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    foreach ($candidate in @("C:\Python312","C:\Python312\Scripts")) {
        if ((Test-Path $candidate) -and ($existing -notcontains $candidate)) { $existing += $candidate }
    }
    [Environment]::SetEnvironmentVariable("Path", ($existing -join ';'), "Machine")
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
}
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw "python command was not found." }
python --version
'@
        },
        [pscustomobject]@{
            Name = "08-node-install-check"
            Script = @'
$ErrorActionPreference = "Stop"
$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) { throw "choco was not found." }
& $chocoExe upgrade nodejs-lts -y --no-progress | Out-Null
$refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    $existing = @()
    if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
        $existing = $machinePath -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    foreach ($candidate in @("C:\Program Files\nodejs")) {
        if ((Test-Path $candidate) -and ($existing -notcontains $candidate)) { $existing += $candidate }
    }
    [Environment]::SetEnvironmentVariable("Path", ($existing -join ';'), "Machine")
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw "node command was not found." }
node --version
'@
        },
        [pscustomobject]@{
            Name = "09-windows-ux-performance-tuning"
            Script = @'
$ErrorActionPreference = "Stop"

$managerUser = "__VM_USER__"
$assistantUser = "__ASSISTANT_USER__"
$targetUsers = @($managerUser, $assistantUser)
$notepadPath = Join-Path $env:WINDIR "System32\notepad.exe"
$textExtensions = @(
    ".txt", ".log", ".ini", ".cfg", ".conf", ".csv", ".xml", ".json",
    ".yaml", ".yml", ".md", ".ps1", ".cmd", ".bat", ".reg", ".sql"
)
$script:tweakWarnings = New-Object 'System.Collections.Generic.List[string]'
$loadedHives = New-Object 'System.Collections.Generic.List[string]'

function Invoke-Tweak {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    try {
        & $Action
        Write-Output ("tweak-ok: {0}" -f $Name)
    }
    catch {
        $message = if ($_.Exception) { $_.Exception.Message } else { [string]$_ }
        $entry = "{0} => {1}" -f $Name, $message
        Write-Warning $entry
        [void]$script:tweakWarnings.Add($entry)
    }
}

function Invoke-RegAdd {
    param(
        [string]$Path,
        [string]$Name = "",
        [string]$Type = "REG_SZ",
        [string]$Value = ""
    )

    $args = @("add", $Path, "/f")
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $args += "/ve"
    }
    else {
        $args += @("/v", $Name)
    }
    if (-not [string]::IsNullOrWhiteSpace($Type)) {
        $args += @("/t", $Type)
    }
    $args += @("/d", $Value)

    & reg.exe @args | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw ("reg add failed for path '{0}' name '{1}'." -f $Path, $Name)
    }
}

function Invoke-RegDelete {
    param(
        [string]$Path
    )

    & reg.exe delete $Path /f | Out-Null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1 -and $LASTEXITCODE -ne 2) {
        throw ("reg delete failed for path '{0}'." -f $Path)
    }
}

function Load-HiveIfPossible {
    param(
        [string]$Alias,
        [string]$NtUserPath
    )

    if ([string]::IsNullOrWhiteSpace($Alias) -or [string]::IsNullOrWhiteSpace($NtUserPath)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $NtUserPath)) {
        return $false
    }

    $hiveKey = "HKU\$Alias"
    & reg.exe load $hiveKey $NtUserPath | Out-Null
    if ($LASTEXITCODE -eq 0) {
        [void]$script:loadedHives.Add($hiveKey)
        return $true
    }

    return $false
}

function Resolve-TargetHives {
    $targets = New-Object 'System.Collections.Generic.List[object]'

    if (Load-HiveIfPossible -Alias "CoVmDefaultUser" -NtUserPath "C:\Users\Default\NTUSER.DAT") {
        [void]$targets.Add([pscustomobject]@{
            Label = "DefaultUser"
            HiveNative = "HKU\CoVmDefaultUser"
        })
    }
    else {
        Write-Warning "Default user hive could not be loaded from C:\Users\Default\NTUSER.DAT."
    }

    foreach ($userName in @($targetUsers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        try {
            $localUser = Get-LocalUser -Name $userName -ErrorAction Stop
            $sid = [string]$localUser.SID.Value
            if (-not [string]::IsNullOrWhiteSpace($sid) -and (Test-Path -LiteralPath ("Registry::HKEY_USERS\" + $sid))) {
                [void]$targets.Add([pscustomobject]@{
                    Label = $userName
                    HiveNative = "HKU\$sid"
                })
                continue
            }

            $profilePath = ""
            if (-not [string]::IsNullOrWhiteSpace($sid)) {
                try {
                    $profilePath = [string](Get-ItemPropertyValue -Path ("Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\" + $sid) -Name "ProfileImagePath" -ErrorAction SilentlyContinue)
                }
                catch { }
            }
            if ([string]::IsNullOrWhiteSpace($profilePath)) {
                $profilePath = "C:\Users\$userName"
            }

            $ntUserPath = Join-Path $profilePath "NTUSER.DAT"
            $alias = "CoVmUser_" + $userName
            if (Load-HiveIfPossible -Alias $alias -NtUserPath $ntUserPath) {
                [void]$targets.Add([pscustomobject]@{
                    Label = $userName
                    HiveNative = "HKU\$alias"
                })
            }
            else {
                Write-Warning ("User hive could not be loaded for '{0}'. Profile may not be materialized yet." -f $userName)
            }
        }
        catch {
            Write-Warning ("Local user lookup failed for '{0}': {1}" -f $userName, $_.Exception.Message)
        }
    }

    return @($targets)
}

function Apply-ExplorerAndUxToUserHive {
    param(
        [string]$HiveNative,
        [string]$Label
    )

    Invoke-Tweak -Name ("explorer-advanced-{0}" -f $Label) -Action {
        $advanced = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        Invoke-RegAdd -Path $advanced -Name "LaunchTo" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $advanced -Name "Hidden" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $advanced -Name "ShowSuperHidden" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $advanced -Name "HideFileExt" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $advanced -Name "ShowInfoTip" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $advanced -Name "IconsOnly" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $advanced -Name "DisablePreviewDesktop" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $advanced -Name "TaskbarAnimations" -Type "REG_DWORD" -Value "0"
    }

    Invoke-Tweak -Name ("explorer-thumbnail-policy-{0}" -f $Label) -Action {
        $policyPath = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
        Invoke-RegAdd -Path $policyPath -Name "DisableThumbnails" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $policyPath -Name "NoThumbnailCache" -Type "REG_DWORD" -Value "1"
    }

    Invoke-Tweak -Name ("explorer-shellbags-{0}" -f $Label) -Action {
        $shellPath = "$HiveNative\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell"
        Invoke-RegAdd -Path $shellPath -Name "FolderType" -Type "REG_SZ" -Value "NotSpecified"
        Invoke-RegAdd -Path $shellPath -Name "LogicalViewMode" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $shellPath -Name "Mode" -Type "REG_DWORD" -Value "4"
        Invoke-RegAdd -Path $shellPath -Name "GroupView" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $shellPath -Name "Sort" -Type "REG_SZ" -Value "prop:System.ItemNameDisplay"
        Invoke-RegAdd -Path $shellPath -Name "SortDirection" -Type "REG_DWORD" -Value "0"
    }

    Invoke-Tweak -Name ("desktop-view-{0}" -f $Label) -Action {
        $desktopPath = "$HiveNative\Software\Microsoft\Windows\Shell\Bags\1\Desktop"
        Invoke-RegAdd -Path $desktopPath -Name "IconSize" -Type "REG_DWORD" -Value "48"
        Invoke-RegAdd -Path $desktopPath -Name "Sort" -Type "REG_SZ" -Value "prop:System.ItemNameDisplay"
        Invoke-RegAdd -Path $desktopPath -Name "SortDirection" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $desktopPath -Name "GroupView" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $desktopPath -Name "FFlags" -Type "REG_DWORD" -Value "1075839525"
    }

    Invoke-Tweak -Name ("control-panel-view-{0}" -f $Label) -Action {
        $controlPanelPath = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel"
        Invoke-RegAdd -Path $controlPanelPath -Name "StartupPage" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $controlPanelPath -Name "AllItemsIconView" -Type "REG_DWORD" -Value "0"
    }

    Invoke-Tweak -Name ("context-menu-classic-{0}" -f $Label) -Action {
        $ctxPath = "$HiveNative\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
        Invoke-RegAdd -Path $ctxPath -Name "" -Type "REG_SZ" -Value ""
    }

    Invoke-Tweak -Name ("welcome-suppression-user-{0}" -f $Label) -Action {
        $cdm = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        Invoke-RegAdd -Path $cdm -Name "ContentDeliveryAllowed" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $cdm -Name "FeatureManagementEnabled" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $cdm -Name "OemPreInstalledAppsEnabled" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $cdm -Name "PreInstalledAppsEnabled" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $cdm -Name "PreInstalledAppsEverEnabled" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $cdm -Name "SilentInstalledAppsEnabled" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $cdm -Name "SystemPaneSuggestionsEnabled" -Type "REG_DWORD" -Value "0"
        foreach ($valueName in @(
            "SubscribedContent-310093Enabled",
            "SubscribedContent-338388Enabled",
            "SubscribedContent-338389Enabled",
            "SubscribedContent-338393Enabled",
            "SubscribedContent-353694Enabled",
            "SubscribedContent-353696Enabled",
            "SubscribedContent-353698Enabled",
            "SubscribedContent-353699Enabled",
            "SubscribedContent-353702Enabled",
            "SubscribedContent-353703Enabled"
        )) {
            Invoke-RegAdd -Path $cdm -Name $valueName -Type "REG_DWORD" -Value "0"
        }

        $privacyPath = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\Privacy"
        Invoke-RegAdd -Path $privacyPath -Name "TailoredExperiencesWithDiagnosticDataEnabled" -Type "REG_DWORD" -Value "0"
        $engagementPath = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement"
        Invoke-RegAdd -Path $engagementPath -Name "ScoobeSystemSettingEnabled" -Type "REG_DWORD" -Value "0"
        $adsPath = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo"
        Invoke-RegAdd -Path $adsPath -Name "Enabled" -Type "REG_DWORD" -Value "0"
    }
}

Invoke-Tweak -Name "machine-rdp-speed-policies" -Action {
    $tsPolicy = "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
    Invoke-RegAdd -Path $tsPolicy -Name "fDisableWallpaper" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $tsPolicy -Name "fDisableFullWindowDrag" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $tsPolicy -Name "fDisableMenuAnims" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $tsPolicy -Name "fDisableThemes" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $tsPolicy -Name "fDisableCursorSetting" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $tsPolicy -Name "fDisableFontSmoothing" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $tsPolicy -Name "ColorDepth" -Type "REG_DWORD" -Value "2"
}

Invoke-Tweak -Name "machine-welcome-suppression" -Action {
    $oobePolicy = "HKLM\SOFTWARE\Policies\Microsoft\Windows\OOBE"
    Invoke-RegAdd -Path $oobePolicy -Name "DisablePrivacyExperience" -Type "REG_DWORD" -Value "1"
    $cloudContent = "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
    Invoke-RegAdd -Path $cloudContent -Name "DisableWindowsConsumerFeatures" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $cloudContent -Name "DisableConsumerAccountStateContent" -Type "REG_DWORD" -Value "1"
    $systemPolicy = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    Invoke-RegAdd -Path $systemPolicy -Name "EnableFirstLogonAnimation" -Type "REG_DWORD" -Value "0"
    $oobeState = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"
    Invoke-RegAdd -Path $oobeState -Name "PrivacyConsentStatus" -Type "REG_DWORD" -Value "1"
}

Invoke-Tweak -Name "machine-context-menu-classic" -Action {
    $ctxPath = "HKLM\SOFTWARE\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
    Invoke-RegAdd -Path $ctxPath -Name "" -Type "REG_SZ" -Value ""
}

Invoke-Tweak -Name "machine-visual-effects-performance" -Action {
    $visualEffectsPath = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"
    Invoke-RegAdd -Path $visualEffectsPath -Name "VisualFXSetting" -Type "REG_DWORD" -Value "2"
}

Invoke-Tweak -Name "power-maximum-performance" -Action {
    $ultimateGuid = "e9a42b02-d5df-448d-aa00-03f14749eb61"
    $highGuid = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
    & powercfg /setactive $ultimateGuid | Out-Null
    if ($LASTEXITCODE -ne 0) {
        & powercfg /setactive $highGuid | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Neither Ultimate nor High performance power scheme could be activated."
        }
    }

    foreach ($powerArgLine in @(
        "/change monitor-timeout-ac 0",
        "/change monitor-timeout-dc 0",
        "/change standby-timeout-ac 0",
        "/change standby-timeout-dc 0",
        "/change disk-timeout-ac 0",
        "/change disk-timeout-dc 0",
        "/change hibernate-timeout-ac 0",
        "/change hibernate-timeout-dc 0",
        "/setacvalueindex scheme_current SUB_PROCESSOR PROCTHROTTLEMIN 100",
        "/setacvalueindex scheme_current SUB_PROCESSOR PROCTHROTTLEMAX 100",
        "/setdcvalueindex scheme_current SUB_PROCESSOR PROCTHROTTLEMIN 100",
        "/setdcvalueindex scheme_current SUB_PROCESSOR PROCTHROTTLEMAX 100",
        "/hibernate off"
    )) {
        $powerArgs = @($powerArgLine -split " ")
        & powercfg @powerArgs | Out-Null
    }
}

Invoke-Tweak -Name "notepad-strict-legacy-removal" -Action {
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        $appxPackages = @(Get-AppxPackage -AllUsers | Where-Object {
            [string]$_.Name -like "Microsoft.WindowsNotepad*"
        })
        foreach ($pkg in @($appxPackages)) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            }
            catch {
                try {
                    Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                }
                catch {
                    Write-Warning ("Remove-AppxPackage failed for {0}: {1}" -f $pkg.PackageFullName, $_.Exception.Message)
                }
            }
        }
    }

    if (Get-Command Get-AppxProvisionedPackage -ErrorAction SilentlyContinue) {
        $provisioned = @(Get-AppxProvisionedPackage -Online | Where-Object {
            [string]$_.DisplayName -like "Microsoft.WindowsNotepad*"
        })
        foreach ($prov in @($provisioned)) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Warning ("Remove-AppxProvisionedPackage failed for {0}: {1}" -f $prov.PackageName, $_.Exception.Message)
            }
        }
    }

    & dism.exe /online /Remove-Capability /CapabilityName:Microsoft.Windows.Notepad~~~~0.0.1.0 /NoRestart | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "DISM capability removal for Microsoft.Windows.Notepad was not completed."
    }

    if (-not (Test-Path -LiteralPath $notepadPath)) {
        throw ("Legacy notepad executable was not found at '{0}'." -f $notepadPath)
    }
}

Invoke-Tweak -Name "notepad-common-text-associations" -Action {
    $className = "CoVmTextFile"
    Invoke-RegAdd -Path ("HKLM\SOFTWARE\Classes\" + $className) -Name "" -Type "REG_SZ" -Value "Co VM Text File"
    Invoke-RegAdd -Path ("HKLM\SOFTWARE\Classes\" + $className + "\shell\open\command") -Name "" -Type "REG_SZ" -Value ("`"" + $notepadPath + "`" `"%1`"")
    & cmd.exe /d /c ("ftype {0}=`"{1}`" `"%1`"" -f $className, $notepadPath) | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "ftype command for CoVmTextFile failed."
    }

    foreach ($ext in @($textExtensions)) {
        Invoke-RegAdd -Path ("HKLM\SOFTWARE\Classes\" + $ext) -Name "" -Type "REG_SZ" -Value $className
        & cmd.exe /d /c ("assoc {0}={1}" -f $ext, $className) | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning ("assoc command failed for extension '{0}'." -f $ext)
        }
    }
}

$targetHives = @()
try {
    $targetHives = Resolve-TargetHives
    foreach ($targetHive in @($targetHives)) {
        $hiveNative = [string]$targetHive.HiveNative
        $label = [string]$targetHive.Label
        Apply-ExplorerAndUxToUserHive -HiveNative $hiveNative -Label $label

        Invoke-Tweak -Name ("text-association-userchoice-reset-{0}" -f $label) -Action {
            foreach ($ext in @($textExtensions)) {
                $userChoicePath = "{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\{1}\UserChoice" -f $hiveNative, $ext
                Invoke-RegDelete -Path $userChoicePath
                Invoke-RegAdd -Path ("{0}\Software\Classes\{1}" -f $hiveNative, $ext) -Name "" -Type "REG_SZ" -Value "CoVmTextFile"
            }
        }
    }
}
finally {
    foreach ($loadedHive in @($loadedHives)) {
        & reg.exe unload $loadedHive | Out-Null
    }
}

if ($tweakWarnings.Count -gt 0) {
    Write-Warning ("windows-ux-performance-tuning completed with {0} warning(s)." -f $tweakWarnings.Count)
    foreach ($warnEntry in @($tweakWarnings)) {
        Write-Warning ("- " + $warnEntry)
    }
}
else {
    Write-Output "windows-ux-performance-tuning completed with no warnings."
}

Write-Output "windows-ux-tuning-ready"
'@
        },
        [pscustomobject]@{
            Name = "10-health-snapshot"
            Script = @'
$ErrorActionPreference = "Stop"
$sshdConfig = "C:\ProgramData\ssh\sshd_config"
Write-Output "Version Info:"
Get-ComputerInfo | Select-Object WindowsProductName,WindowsVersion,OsBuildNumber | Format-List
Write-Output "APP PATH CHECKS:"
foreach ($commandName in @("choco", "git", "node", "python", "py")) {
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
Write-Output "NOTEPAD STATUS:"
if (Test-Path "$env:WINDIR\System32\notepad.exe") { Write-Output "legacy-notepad-exe-found" } else { Write-Output "legacy-notepad-exe-not-found" }
if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
    $notepadPkgs = @(Get-AppxPackage -AllUsers | Where-Object { [string]$_.Name -like "Microsoft.WindowsNotepad*" })
    Write-Output ("modern-notepad-package-count=" + @($notepadPkgs).Count)
}
'@
        }
    )
}

function Get-CoVmGuestTaskReplacementMap {
    param(
        [ValidateSet("linux", "windows")]
        [string]$Platform,
        [hashtable]$Context
    )

    $map = @{
        VM_USER = [string]$Context.VmUser
        VM_PASS = [string]$Context.VmPass
        ASSISTANT_USER = [string]$Context.VmAssistantUser
        ASSISTANT_PASS = [string]$Context.VmAssistantPass
        SSH_PORT = [string]$Context.SshPort
    }

    if ($Platform -eq "linux") {
        $tcpPorts = @($Context.TcpPorts)
        $map["TCP_PORTS_BASH"] = ($tcpPorts -join " ")
        $map["TCP_PORTS_REGEX"] = (($tcpPorts | ForEach-Object { [regex]::Escape([string]$_) }) -join "|")
        return $map
    }

    $map["TCP_PORTS_PS_ARRAY"] = ((@($Context.TcpPorts)) -join ",")
    return $map
}

function Resolve-CoVmGuestTaskBlocks {
    param(
        [ValidateSet("linux", "windows")]
        [string]$Platform,
        [hashtable]$Context,
        [string]$VmInitScriptFile = ""
    )

    $templates = Get-CoVmGuestTaskTemplates -Platform $Platform -VmInitScriptFile $VmInitScriptFile
    $replacements = Get-CoVmGuestTaskReplacementMap -Platform $Platform -Context $Context
    return (Apply-CoVmTaskBlockReplacements -TaskBlocks $templates -Replacements $replacements)
}

function Get-CoVmUpdateScriptContentFromTasks {
    param(
        [ValidateSet("linux", "windows")]
        [string]$Platform,
        [object[]]$TaskBlocks
    )

    if (-not $TaskBlocks -or $TaskBlocks.Count -eq 0) {
        throw "VM update script build failed: no task blocks were provided."
    }

    $sb = New-Object System.Text.StringBuilder
    if ($Platform -eq "linux") {
        [void]$sb.AppendLine("#!/usr/bin/env bash")
        [void]$sb.AppendLine("set -euo pipefail")
        [void]$sb.AppendLine("exec 2>&1")
        [void]$sb.AppendLine('echo "Update phase started."')
        [void]$sb.AppendLine("")
    }
    else {
        [void]$sb.AppendLine('$ErrorActionPreference = "Stop"')
        [void]$sb.AppendLine('$ProgressPreference = "SilentlyContinue"')
        [void]$sb.AppendLine('[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12')
        [void]$sb.AppendLine('Write-Output "Update phase started."')
        [void]$sb.AppendLine("")
    }

    foreach ($taskBlock in $TaskBlocks) {
        $taskName = [string]$taskBlock.Name
        $taskScript = [string]$taskBlock.Script
        [void]$sb.AppendLine(("# Task: {0}" -f $taskName))
        [void]$sb.AppendLine($taskScript.Trim())
        [void]$sb.AppendLine("")
    }

    if ($Platform -eq "linux") {
        [void]$sb.AppendLine('echo "Update phase completed."')
    }
    else {
        [void]$sb.AppendLine('Write-Output "Update phase completed."')
    }

    return $sb.ToString()
}

function Get-CoVmWriteSettingsForPlatform {
    param(
        [ValidateSet("linux", "windows")]
        [string]$Platform
    )

    if ($Platform -eq "linux") {
        return @{
            Encoding = "utf8NoBom"
            LineEnding = "lf"
        }
    }

    return @{
        Encoding = "utf8NoBom"
        LineEnding = "crlf"
    }
}

function Get-CoVmConnectionDisplayModel {
    param(
        [hashtable]$Context,
        [string]$ManagerUser,
        [string]$AssistantUser,
        [string]$SshPort,
        [switch]$IncludeRdp
    )

    $vmConnectionInfo = Get-CoVmVmDetails -Context $Context
    $publicIP = [string]$vmConnectionInfo.PublicIP
    $vmFqdn = [string]$vmConnectionInfo.VmFqdn

    $sshConnections = @(
        [pscustomobject]@{
            User = $ManagerUser
            Command = ("ssh -p {0} {1}@{2}" -f $SshPort, $ManagerUser, $vmFqdn)
        },
        [pscustomobject]@{
            User = $AssistantUser
            Command = ("ssh -p {0} {1}@{2}" -f $SshPort, $AssistantUser, $vmFqdn)
        }
    )

    $model = [ordered]@{
        PublicIP = $publicIP
        VmFqdn = $vmFqdn
        SshConnections = $sshConnections
    }

    if ($IncludeRdp) {
        $rdpConnections = @(
            [pscustomobject]@{
                User = $ManagerUser
                Username = (".\{0}" -f $ManagerUser)
                Command = ("mstsc /v:{0}:3389" -f $vmFqdn)
            },
            [pscustomobject]@{
                User = $AssistantUser
                Username = (".\{0}" -f $AssistantUser)
                Command = ("mstsc /v:{0}:3389" -f $vmFqdn)
            }
        )
        $model["RdpConnections"] = $rdpConnections
    }

    return $model
}
