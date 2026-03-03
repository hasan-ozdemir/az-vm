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
            Name = "09-health-snapshot"
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
