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
    param(
        [string]$VmUser,
        [string]$VmPass,
        [string]$AssistantUser,
        [string]$AssistantPass,
        [string]$SshPort,
        [string[]]$TcpPorts
    )

    if ([string]::IsNullOrWhiteSpace($VmUser)) { throw "VmUser is required for Windows init script." }
    if ([string]::IsNullOrWhiteSpace($VmPass)) { throw "VmPass is required for Windows init script." }
    if ([string]::IsNullOrWhiteSpace($AssistantUser)) { throw "AssistantUser is required for Windows init script." }
    if ([string]::IsNullOrWhiteSpace($AssistantPass)) { throw "AssistantPass is required for Windows init script." }
    if (-not ($SshPort -match '^\d+$')) { throw "SshPort is invalid for Windows init script." }

    $validPorts = @(@($TcpPorts) | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^\d+$' } | Select-Object -Unique)
    if ($validPorts -notcontains [string]$SshPort) {
        $validPorts += [string]$SshPort
    }
    if ($validPorts -notcontains "3389") {
        $validPorts += "3389"
    }
    $portsCsv = ($validPorts -join ",")

    $template = @'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Output "Init phase started."
Set-TimeZone -Id "UTC" -ErrorAction SilentlyContinue

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

if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
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

$sshdConfig = "C:\ProgramData\ssh\sshd_config"
if (-not (Test-Path $sshdConfig)) { New-Item -Path $sshdConfig -ItemType File -Force | Out-Null }
$content = @(Get-Content -Path $sshdConfig -ErrorAction SilentlyContinue)
if ($content.Count -eq 0) {
    $content = @(
        "# Generated baseline sshd_config",
        "Port 22",
        "PasswordAuthentication no",
        "PubkeyAuthentication yes",
        "PermitEmptyPasswords no",
        "AllowTcpForwarding yes",
        "GatewayPorts no",
        "Subsystem sftp sftp-server.exe"
    )
}
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
    if (-not $updated) { $content += $replacement }
}
Set-OrAdd -Key "Port" -Value "__SSH_PORT__"
Set-OrAdd -Key "PasswordAuthentication" -Value "yes"
Set-OrAdd -Key "PubkeyAuthentication" -Value "no"
Set-OrAdd -Key "PermitEmptyPasswords" -Value "no"
Set-OrAdd -Key "AllowTcpForwarding" -Value "yes"
Set-OrAdd -Key "GatewayPorts" -Value "yes"
Set-OrAdd -Key "Subsystem sftp" -Value "sftp-server.exe"
Set-Content -Path $sshdConfig -Value $content -Encoding ascii
New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name "DefaultShell" -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
Restart-Service -Name sshd -Force
if (-not (Get-NetFirewallRule -DisplayName "Allow-SSH-__SSH_PORT__" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow-SSH-__SSH_PORT__" -Direction Inbound -Action Allow -Protocol TCP -LocalPort __SSH_PORT__ -RemoteAddress Any -Profile Any | Out-Null
}
Write-Output "sshd-config-ready"

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
Write-Output "Init phase completed."
'@

    return $template.Replace("__VM_USER__", $VmUser).Replace("__VM_PASS__", $VmPass).Replace("__ASSISTANT_USER__", $AssistantUser).Replace("__ASSISTANT_PASS__", $AssistantPass).Replace("__SSH_PORT__", $SshPort).Replace("__TCP_PORTS_PS_ARRAY__", $portsCsv)
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
if ($content.Count -eq 0) {
    $content = @(
        "# Generated baseline sshd_config",
        "Port 22",
        "PasswordAuthentication no",
        "PubkeyAuthentication yes",
        "PermitEmptyPasswords no",
        "AllowTcpForwarding yes",
        "GatewayPorts no",
        "Subsystem sftp sftp-server.exe"
    )
}
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
    if (-not $updated) { $content += $replacement }
}
Set-OrAdd -Key "Port" -Value "__SSH_PORT__"
Set-OrAdd -Key "PasswordAuthentication" -Value "yes"
Set-OrAdd -Key "PubkeyAuthentication" -Value "no"
Set-OrAdd -Key "PermitEmptyPasswords" -Value "no"
Set-OrAdd -Key "AllowTcpForwarding" -Value "yes"
Set-OrAdd -Key "GatewayPorts" -Value "yes"
Set-OrAdd -Key "Subsystem sftp" -Value "sftp-server.exe"
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
& $chocoExe install winget -y --no-progress | Out-Null
$wingetInstallExit = [int]$LASTEXITCODE
if ($wingetInstallExit -ne 0 -and $wingetInstallExit -ne 2) {
    Write-Warning ("Chocolatey winget install returned exit code {0}. Winget-dependent tasks may be limited." -f $wingetInstallExit)
}
$refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
$wingetCandidates = @(
    "$env:ProgramData\chocolatey\bin\winget.exe",
    "$env:ProgramData\chocolatey\lib\winget\tools\winget.exe"
)
if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    $pathItems = @()
    if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
        $pathItems = @($machinePath -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    foreach ($candidate in @($wingetCandidates)) {
        $candidateDir = Split-Path -Path $candidate -Parent
        if ((Test-Path -LiteralPath $candidateDir) -and ($pathItems -notcontains $candidateDir)) {
            $pathItems += $candidateDir
        }
    }
    if ($pathItems.Count -gt 0) {
        [Environment]::SetEnvironmentVariable("Path", ($pathItems -join ";"), "Machine")
        $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
    }
}
$wingetVerified = $false
foreach ($candidate in @($wingetCandidates)) {
    if (-not (Test-Path -LiteralPath $candidate)) { continue }
    try {
        & $candidate --version | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $wingetVerified = $true
            break
        }
    }
    catch { }
}
if (-not $wingetVerified) {
    try {
        & winget.exe --version | Out-Null
        if ($LASTEXITCODE -eq 0) { $wingetVerified = $true }
    }
    catch { }
}
if ($wingetVerified) {
    Write-Output "winget-ready"
}
else {
    $wingetBundlePath = Join-Path $env:TEMP "Microsoft.DesktopAppInstaller.msixbundle"
    try {
        Invoke-WebRequest -Uri "https://aka.ms/getwinget" -OutFile $wingetBundlePath -UseBasicParsing
        Add-AppxPackage -Path $wingetBundlePath -ErrorAction Stop | Out-Null
        $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
        if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
        if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
            $wingetVerified = $true
            Write-Output "winget-ready"
        }
        else {
            Write-Warning "winget command is still not available after App Installer bootstrap."
        }
    }
    catch {
        Write-Warning ("winget bootstrap via App Installer failed: {0}" -f $_.Exception.Message)
    }
    finally {
        Remove-Item -Path $wingetBundlePath -Force -ErrorAction SilentlyContinue
    }
}
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
            Name = "08-private-local-task"
            Script = @'
$ErrorActionPreference = "Stop"

function Resolve-WingetCommand {
    $candidates = @()
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        $candidates += [string]$cmd.Source
    }

    $localAlias = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"
    if (Test-Path -LiteralPath $localAlias) {
        $candidates += $localAlias
    }
    foreach ($chocoWingetCandidate in @(
        "$env:ProgramData\chocolatey\bin\winget.exe",
        "$env:ProgramData\chocolatey\lib\winget\tools\winget.exe"
    )) {
        if (Test-Path -LiteralPath $chocoWingetCandidate) {
            $candidates += $chocoWingetCandidate
        }
    }

    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" -ErrorAction SilentlyContinue | Out-Null
    }
    catch { }
    try {
        $appInstallerPackages = @(Get-AppxPackage -AllUsers -Name "Microsoft.DesktopAppInstaller*" -ErrorAction SilentlyContinue)
        foreach ($pkg in @($appInstallerPackages)) {
            if ([string]::IsNullOrWhiteSpace([string]$pkg.InstallLocation)) {
                continue
            }
            $pkgWinget = Join-Path ([string]$pkg.InstallLocation) "winget.exe"
            if (Test-Path -LiteralPath $pkgWinget) {
                $candidates += $pkgWinget
            }
        }
    }
    catch { }

    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        $candidates += [string]$cmd.Source
    }

    foreach ($candidate in @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)) {
        try {
            & $candidate --version | Out-Null
            if ($LASTEXITCODE -eq 0) {
                return [string]$candidate
            }
        }
        catch {
            Write-Host ("winget candidate rejected: {0} => {1}" -f $candidate, $_.Exception.Message) -ForegroundColor DarkGray
        }
    }

    return ""
}

function Invoke-WingetInstall {
    param(
        [string]$Id
    )

    $wingetExe = Resolve-WingetCommand
    if ([string]::IsNullOrWhiteSpace($wingetExe)) {
        Write-Host ("winget command is not available. Skipping package '{0}'." -f $Id) -ForegroundColor DarkGray
        return $false
    }

    try {
        & $wingetExe install -e --id $Id --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Null
    }
    catch {
        Write-Host ("winget install failed for '{0}': {1}" -f $Id, $_.Exception.Message) -ForegroundColor DarkGray
        return $false
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("winget install failed for '{0}' with exit code {1}." -f $Id, $LASTEXITCODE) -ForegroundColor DarkGray
        return $false
    }

    return $true
}

$installed = Invoke-WingetInstall -Id "private.local.accessibility.package"
$refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }

$localOnlyAccessibilityCandidates = @(
    "C:\Program Files\local accessibility vendor\private local-only accessibility\2025\local-accessibility.exe",
    "C:\Program Files (x86)\local accessibility vendor\private local-only accessibility\2025\local-accessibility.exe"
)
$localOnlyAccessibilityFound = $false
if (Get-Command jfw -ErrorAction SilentlyContinue) {
    $localOnlyAccessibilityFound = $true
}
else {
    foreach ($candidate in @($localOnlyAccessibilityCandidates)) {
        if (Test-Path -LiteralPath $candidate) {
            $localOnlyAccessibilityFound = $true
            break
        }
    }
}

if (-not $localOnlyAccessibilityFound) {
    if ($installed) {
        Write-Warning "private local-only accessibility install command completed but executable path was not detected yet."
    }
    else {
        Write-Host "private local-only accessibility install step was skipped or failed." -ForegroundColor DarkGray
    }
}

Write-Output "private local-only accessibility-install-check-completed"
'@
        },
        [pscustomobject]@{
            Name = "09-node-install-check"
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
            Name = "10-choco-extra-packages"
            Script = @'
$ErrorActionPreference = "Stop"

$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) {
    Write-Warning "choco was not found. Extra package installs are skipped."
    Write-Output "choco-extra-packages-skipped"
    return
}

function Refresh-SessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) {
        $env:Path = $machinePath
    }
    else {
        $env:Path = "$machinePath;$userPath"
    }
}

function Install-ChocoPackageWarn {
    param(
        [string]$PackageId,
        [string]$InstallCommand,
        [string]$CommandName = "",
        [string]$PathHint = ""
    )

    Write-Output ("Running: {0}" -f $InstallCommand)
    & cmd.exe /d /c $InstallCommand | Out-Null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
        Write-Warning ("choco install failed for '{0}' with exit code {1}." -f $PackageId, $LASTEXITCODE)
        Refresh-SessionPath
        return
    }

    Refresh-SessionPath

    if (-not [string]::IsNullOrWhiteSpace($CommandName)) {
        if (Get-Command $CommandName -ErrorAction SilentlyContinue) {
            Write-Output ("Command check passed: {0}" -f $CommandName)
        }
        else {
            Write-Warning ("Command '{0}' was not found after '{1}' install." -f $CommandName, $PackageId)
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($PathHint)) {
        if (Test-Path -LiteralPath $PathHint) {
            Write-Output ("Path check passed: {0}" -f $PathHint)
        }
        else {
            Write-Warning ("Path '{0}' was not found after '{1}' install." -f $PathHint, $PackageId)
        }
    }
}

Install-ChocoPackageWarn -PackageId "ollama" -InstallCommand "choco install ollama -y --no-progress" -CommandName "ollama"
Install-ChocoPackageWarn -PackageId "sysinternals" -InstallCommand "choco install sysinternals -y --no-progress" -PathHint "C:\ProgramData\chocolatey\lib\sysinternals\tools"
Install-ChocoPackageWarn -PackageId "powershell-core" -InstallCommand "choco install powershell-core -y --no-progress" -CommandName "pwsh"
Install-ChocoPackageWarn -PackageId "io-unlocker" -InstallCommand "choco install io-unlocker -y --no-progress" -PathHint "C:\ProgramData\chocolatey\lib\io-unlocker"
Install-ChocoPackageWarn -PackageId "gh" -InstallCommand "choco install gh -y --no-progress" -CommandName "gh"
Install-ChocoPackageWarn -PackageId "ffmpeg" -InstallCommand "choco install ffmpeg -y --no-progress" -CommandName "ffmpeg"
Install-ChocoPackageWarn -PackageId "7zip" -InstallCommand "choco install 7zip -y --no-progress" -CommandName "7z"
Install-ChocoPackageWarn -PackageId "azure-cli" -InstallCommand "choco install azure-cli -y --no-progress" -CommandName "az"

Write-Output "choco-extra-packages-completed"
'@
        },
        [pscustomobject]@{
            Name = "11-chrome-install-and-shortcut"
            Script = @'
$ErrorActionPreference = "Stop"

$serverName = "__SERVER_NAME__"
$chromeArgs = "--new-window --start-maximized --disable-extensions --disable-default-apps --no-first-run --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --profile-directory=$serverName https://www.google.com"

function Install-ChromeWithWinget {
    function Resolve-WingetCommand {
        $candidates = @()
        $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            $candidates += [string]$cmd.Source
        }

        $localAlias = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"
        if (Test-Path -LiteralPath $localAlias) {
            $candidates += $localAlias
        }
        foreach ($chocoWingetCandidate in @(
            "$env:ProgramData\chocolatey\bin\winget.exe",
            "$env:ProgramData\chocolatey\lib\winget\tools\winget.exe"
        )) {
            if (Test-Path -LiteralPath $chocoWingetCandidate) {
                $candidates += $chocoWingetCandidate
            }
        }
        foreach ($chocoWingetCandidate in @(
            "$env:ProgramData\chocolatey\bin\winget.exe",
            "$env:ProgramData\chocolatey\lib\winget\tools\winget.exe"
        )) {
            if (Test-Path -LiteralPath $chocoWingetCandidate) {
                $candidates += $chocoWingetCandidate
            }
        }

        try {
            Add-AppxPackage -RegisterByFamilyName -MainPackage "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" -ErrorAction SilentlyContinue | Out-Null
        }
        catch { }
        try {
            $appInstallerPackages = @(Get-AppxPackage -AllUsers -Name "Microsoft.DesktopAppInstaller*" -ErrorAction SilentlyContinue)
            foreach ($pkg in @($appInstallerPackages)) {
                if ([string]::IsNullOrWhiteSpace([string]$pkg.InstallLocation)) {
                    continue
                }
                $pkgWinget = Join-Path ([string]$pkg.InstallLocation) "winget.exe"
                if (Test-Path -LiteralPath $pkgWinget) {
                    $candidates += $pkgWinget
                }
            }
        }
        catch { }

        $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            $candidates += [string]$cmd.Source
        }

        foreach ($candidate in @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)) {
            try {
                & $candidate --version | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    return [string]$candidate
                }
            }
            catch {
                Write-Host ("winget candidate rejected: {0} => {1}" -f $candidate, $_.Exception.Message) -ForegroundColor DarkGray
            }
        }

        return ""
    }

    function Refresh-SessionPath {
        $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
        if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
        $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ([string]::IsNullOrWhiteSpace($userPath)) {
            $env:Path = $machinePath
        }
        else {
            $env:Path = "$machinePath;$userPath"
        }
    }

    $wingetExe = Resolve-WingetCommand
    if (-not [string]::IsNullOrWhiteSpace($wingetExe)) {
        try {
            & $wingetExe install -e --id Google.Chrome --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Null
            if ($LASTEXITCODE -eq 0) {
                return $true
            }
            Write-Warning ("winget install failed for Google.Chrome with exit code {0}." -f $LASTEXITCODE)
        }
        catch {
            Write-Warning ("winget install failed for Google.Chrome: {0}" -f $_.Exception.Message)
        }
    }
    else {
        Write-Host "winget command is not available. Falling back to Chocolatey for Google Chrome." -ForegroundColor DarkGray
    }

    $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (-not (Test-Path -LiteralPath $chocoExe)) {
        Write-Warning "choco command is not available. Google Chrome install step is skipped."
        return $false
    }

    & $chocoExe upgrade googlechrome -y --no-progress --ignore-detected-reboot | Out-Null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
        Write-Warning ("choco upgrade failed for googlechrome with exit code {0}. Trying install." -f $LASTEXITCODE)
        & $chocoExe install googlechrome -y --no-progress --ignore-detected-reboot --ignore-checksums | Out-Null
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
            Write-Warning ("choco install failed for googlechrome with exit code {0}." -f $LASTEXITCODE)
            return $false
        }
    }
    Refresh-SessionPath

    return $true
}

function Resolve-ChromeExecutable {
    $cmd = Get-Command chrome.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        foreach ($candidate in @([string]$cmd.Source, [string]$cmd.Path, [string]$cmd.Definition)) {
            if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
                continue
            }
            if (([System.IO.Path]::IsPathRooted([string]$candidate)) -and (Test-Path -LiteralPath $candidate)) {
                return [string]$candidate
            }
        }
    }

    foreach ($candidate in @(
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
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

    if ([string]::IsNullOrWhiteSpace([string]$ChromeExe) -or (-not ([System.IO.Path]::IsPathRooted([string]$ChromeExe))) -or (-not (Test-Path -LiteralPath $ChromeExe))) {
        throw ("Chrome executable path is invalid: '{0}'." -f [string]$ChromeExe)
    }

    $shortcutDir = Split-Path -Path $ShortcutPath -Parent
    if ([string]::IsNullOrWhiteSpace([string]$shortcutDir)) {
        throw ("Shortcut directory is invalid for path '{0}'." -f [string]$ShortcutPath)
    }
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

$installed = Install-ChromeWithWinget
$chromeExe = Resolve-ChromeExecutable
if ([string]::IsNullOrWhiteSpace([string]$chromeExe) -or (-not ([System.IO.Path]::IsPathRooted([string]$chromeExe))) -or (-not (Test-Path -LiteralPath $chromeExe))) {
    if ($installed) {
        Write-Warning "Google Chrome install command completed but executable path was not detected."
    }
    else {
        Write-Warning "Google Chrome install failed or was skipped."
    }
    Write-Output "chrome-install-and-shortcut-completed"
    return
}

$shortcutTargets = @(
    "C:\Users\Public\Desktop\Google Chrome.lnk",
    "C:\Users\__VM_USER__\Desktop\Google Chrome.lnk",
    "C:\Users\__ASSISTANT_USER__\Desktop\Google Chrome.lnk"
)
foreach ($shortcutPath in @($shortcutTargets)) {
    try {
        Set-ChromeShortcut -ShortcutPath $shortcutPath -ChromeExe $chromeExe -Args $chromeArgs
        Write-Output ("Chrome shortcut configured: {0}" -f $shortcutPath)
    }
    catch {
        Write-Warning ("Chrome shortcut configuration failed for '{0}': {1}" -f $shortcutPath, $_.Exception.Message)
    }
}

Write-Output "chrome-install-and-shortcut-completed"
'@
        },
        [pscustomobject]@{
            Name = "12-wsl2-install-update"
            Script = @'
$ErrorActionPreference = "Stop"

function Invoke-CommandWarn {
    param(
        [string]$Label,
        [scriptblock]$Action
    )

    try {
        & $Action
        Write-Output ("wsl-step-ok: {0}" -f $Label)
    }
    catch {
        Write-Warning ("wsl-step-failed: {0} => {1}" -f $Label, $_.Exception.Message)
    }
}

Invoke-CommandWarn -Label "enable-feature-wsl" -Action {
    & dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
}
Invoke-CommandWarn -Label "enable-feature-vmp" -Action {
    & dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
}
Invoke-CommandWarn -Label "wsl-update" -Action {
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        & wsl --update | Out-Null
    }
    else {
        Write-Warning "wsl command is not available yet. WSL update is deferred."
    }
}
Invoke-CommandWarn -Label "wsl-version" -Action {
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        & wsl --status
    }
    else {
        Write-Warning "wsl command is not available yet. WSL version check is deferred."
    }
}

Write-Output "wsl2-install-update-completed"
'@
        },
        [pscustomobject]@{
            Name = "13-docker-desktop-install-and-configure"
            Script = @'
$ErrorActionPreference = "Stop"

function Invoke-DockerWarn {
    param(
        [string]$Label,
        [scriptblock]$Action
    )

    try {
        & $Action
        Write-Output ("docker-step-ok: {0}" -f $Label)
    }
    catch {
        Write-Warning ("docker-step-failed: {0} => {1}" -f $Label, $_.Exception.Message)
    }
}

Invoke-DockerWarn -Label "winget-install-docker-desktop" -Action {
    function Resolve-WingetCommand {
        $candidates = @()
        $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            $candidates += [string]$cmd.Source
        }

        $localAlias = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"
        if (Test-Path -LiteralPath $localAlias) {
            $candidates += $localAlias
        }

        try {
            Add-AppxPackage -RegisterByFamilyName -MainPackage "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" -ErrorAction SilentlyContinue | Out-Null
        }
        catch { }
        try {
            $appInstallerPackages = @(Get-AppxPackage -AllUsers -Name "Microsoft.DesktopAppInstaller*" -ErrorAction SilentlyContinue)
            foreach ($pkg in @($appInstallerPackages)) {
                if ([string]::IsNullOrWhiteSpace([string]$pkg.InstallLocation)) {
                    continue
                }
                $pkgWinget = Join-Path ([string]$pkg.InstallLocation) "winget.exe"
                if (Test-Path -LiteralPath $pkgWinget) {
                    $candidates += $pkgWinget
                }
            }
        }
        catch { }

        $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            $candidates += [string]$cmd.Source
        }

        foreach ($candidate in @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)) {
            try {
                & $candidate --version | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    return [string]$candidate
                }
            }
            catch {
                Write-Host ("winget candidate rejected: {0} => {1}" -f $candidate, $_.Exception.Message) -ForegroundColor DarkGray
            }
        }

        return ""
    }

    function Refresh-SessionPath {
        $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
        if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
        $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ([string]::IsNullOrWhiteSpace($userPath)) {
            $env:Path = $machinePath
        }
        else {
            $env:Path = "$machinePath;$userPath"
        }
    }

    $installed = $false
    $wingetExe = Resolve-WingetCommand
    if (-not [string]::IsNullOrWhiteSpace($wingetExe)) {
        try {
            & $wingetExe install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $installed = $true
            }
            else {
                Write-Host ("winget install failed for Docker.DockerDesktop with exit code {0}." -f $LASTEXITCODE) -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Host ("winget install failed for Docker.DockerDesktop: {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
        }
    }

    if (-not $installed) {
        $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
        if (-not (Test-Path -LiteralPath $chocoExe)) {
            throw "Neither winget nor choco is available for Docker Desktop installation."
        }

        & $chocoExe upgrade docker-desktop -y --no-progress | Out-Null
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
            throw ("choco install failed for docker-desktop with exit code {0}." -f $LASTEXITCODE)
        }
        Refresh-SessionPath
    }
}

Invoke-DockerWarn -Label "set-com-docker-service-automatic" -Action {
    if (Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue) {
        Set-Service -Name "com.docker.service" -StartupType Automatic
        Start-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
    }
    else {
        Write-Warning "com.docker.service was not found."
    }
}

Invoke-DockerWarn -Label "configure-docker-startup-shortcut" -Action {
    $dockerDesktopExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (-not (Test-Path -LiteralPath $dockerDesktopExe)) { throw "Docker Desktop executable not found." }
    $startupPath = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\Docker Desktop.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($startupPath)
    $shortcut.TargetPath = $dockerDesktopExe
    $shortcut.Arguments = "--minimized"
    $shortcut.WorkingDirectory = (Split-Path -Path $dockerDesktopExe -Parent)
    $shortcut.IconLocation = "$dockerDesktopExe,0"
    $shortcut.Save()
}

Invoke-DockerWarn -Label "configure-docker-settings-json" -Action {
    $profileRoots = @(
        "C:\Users\__VM_USER__",
        "C:\Users\__ASSISTANT_USER__",
        "C:\Users\Default"
    )
    foreach ($profileRoot in @($profileRoots)) {
        $roamingPath = Join-Path $profileRoot "AppData\Roaming\Docker"
        if (-not (Test-Path -LiteralPath $roamingPath)) {
            New-Item -Path $roamingPath -ItemType Directory -Force | Out-Null
        }

        $settingsPaths = @(
            (Join-Path $roamingPath "settings-store.json"),
            (Join-Path $roamingPath "settings.json")
        )
        $settingsPath = $settingsPaths[0]
        $settings = @{}
        foreach ($candidate in @($settingsPaths)) {
            if (Test-Path -LiteralPath $candidate) {
                $settingsPath = $candidate
                $raw = Get-Content -Path $candidate -Raw -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $parsed = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($parsed) {
                        $settings = @{}
                        foreach ($prop in $parsed.PSObject.Properties) {
                            $settings[$prop.Name] = $prop.Value
                        }
                    }
                }
                break
            }
        }

        $settings["autoStart"] = $true
        $settings["startMinimized"] = $true
        $settings["openUIOnStartupDisabled"] = $true
        $settings["displayedOnboarding"] = $true
        $settings["wslEngineEnabled"] = $true

        ($settings | ConvertTo-Json -Depth 20) | Set-Content -Path $settingsPath -Encoding UTF8
    }
}

Invoke-DockerWarn -Label "docker-users-group-membership" -Action {
    if (-not (Get-LocalGroup -Name "docker-users" -ErrorAction SilentlyContinue)) {
        New-LocalGroup -Name "docker-users" -Description "Docker Desktop Users" -ErrorAction SilentlyContinue | Out-Null
    }

    foreach ($localUser in @("__VM_USER__", "__ASSISTANT_USER__")) {
        if ([string]::IsNullOrWhiteSpace([string]$localUser)) { continue }
        try {
            Add-LocalGroupMember -Group "docker-users" -Member $localUser -ErrorAction Stop
        }
        catch {
            if ($_.Exception.Message -notmatch '(?i)already a member') {
                Write-Warning ("docker-users membership failed for '{0}': {1}" -f $localUser, $_.Exception.Message)
            }
        }
    }
}

Invoke-DockerWarn -Label "docker-client-version" -Action {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "docker command is not available." }
    & docker --version
}

Invoke-DockerWarn -Label "docker-daemon-version" -Action {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "docker command is not available." }
    $daemonReady = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $daemonCommandThrew = $false
        try {
            & docker version 2>$null
        }
        catch {
            $daemonCommandThrew = $true
        }

        if ((-not $daemonCommandThrew) -and ($LASTEXITCODE -eq 0)) {
            $daemonReady = $true
            break
        }

        if ($attempt -lt 3) {
            Start-Sleep -Seconds 5
        }
    }

    if (-not $daemonReady) {
        Write-Output "docker-daemon-version-deferred"
    }
}

Write-Output "docker-desktop-install-and-configure-completed"
'@
        },
        [pscustomobject]@{
            Name = "14-windows-ux-performance-tuning"
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
    $hasExplicitData = -not ([string]::IsNullOrWhiteSpace($Name) -and [string]::IsNullOrWhiteSpace($Value))
    if ($hasExplicitData -and -not [string]::IsNullOrWhiteSpace($Type)) {
        $args += @("/t", $Type)
    }
    if ($hasExplicitData) {
        $args += @("/d", $Value)
    }

    $escapedArgs = @()
    foreach ($arg in @($args)) {
        $text = [string]$arg
        if ($text -match '\s') {
            $escapedArgs += ('"{0}"' -f ($text -replace '"', '\"'))
        }
        else {
            $escapedArgs += $text
        }
    }
    $cmdLine = ("reg {0} >nul 2>&1" -f ($escapedArgs -join " "))
    & cmd.exe /d /c $cmdLine | Out-Null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1 -and $LASTEXITCODE -ne 2) {
        throw ("reg add failed for path '{0}' name '{1}'." -f $Path, $Name)
    }
}

function Invoke-RegDelete {
    param(
        [string]$Path
    )

    $cmdLine = ('reg delete "{0}" /f >nul 2>&1' -f ($Path -replace '"', '\"'))
    & cmd.exe /d /c $cmdLine | Out-Null
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
    $safeLoad = ('reg load "{0}" "{1}" >nul 2>&1' -f $hiveKey, $NtUserPath)
    & cmd.exe /d /c $safeLoad | Out-Null
    if ($LASTEXITCODE -eq 0) {
        [void]$script:loadedHives.Add($hiveKey)
        return $true
    }

    return $false
}

function Resolve-TargetHives {
    $targets = @()

    if (Load-HiveIfPossible -Alias "CoVmDefaultUser" -NtUserPath "C:\Users\Default\NTUSER.DAT") {
        $targets += [pscustomobject]@{
            Label = "DefaultUser"
            HiveNative = "HKU\CoVmDefaultUser"
        }
    }
    else {
        Write-Warning "Default user hive could not be loaded from C:\Users\Default\NTUSER.DAT."
    }

    foreach ($userName in @($targetUsers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        try {
            $localUser = Get-LocalUser -Name $userName -ErrorAction Stop
            $sid = [string]$localUser.SID.Value
            if (-not [string]::IsNullOrWhiteSpace($sid) -and (Test-Path -LiteralPath ("Registry::HKEY_USERS\" + $sid))) {
                $targets += [pscustomobject]@{
                    Label = $userName
                    HiveNative = "HKU\$sid"
                }
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
                $targets += [pscustomobject]@{
                    Label = $userName
                    HiveNative = "HKU\$alias"
                }
            }
            else {
                Write-Output ("User hive could not be loaded for '{0}'. Profile may not be materialized yet." -f $userName)
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
    $safeCmd = ('reg add "{0}" /ve /f >nul 2>&1' -f ($ctxPath -replace '"', '\"'))
    & cmd.exe /d /c $safeCmd | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Output "machine-context-menu-classic skipped (key may be protected by ACL)."
    }
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
        Write-Output "DISM capability removal for Microsoft.Windows.Notepad was not completed."
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
        $safeUnload = ('reg unload "{0}" >nul 2>&1' -f $loadedHive)
        & cmd.exe /d /c $safeUnload | Out-Null
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
            Name = "15-windows-advanced-system-settings"
            Script = @'
$ErrorActionPreference = "Stop"

function Invoke-AdvancedWarn {
    param(
        [string]$Label,
        [scriptblock]$Action
    )

    try {
        & $Action
        Write-Output ("advanced-step-ok: {0}" -f $Label)
    }
    catch {
        Write-Warning ("advanced-step-failed: {0} => {1}" -f $Label, $_.Exception.Message)
    }
}

function Invoke-RegCmdWithAllowedExitCodes {
    param(
        [string]$CommandText,
        [int[]]$AllowedExitCodes = @(0)
    )

    if ([string]::IsNullOrWhiteSpace([string]$CommandText)) {
        throw "Registry command text is empty."
    }

    & cmd.exe /d /c $CommandText | Out-Null
    if ($AllowedExitCodes -notcontains [int]$LASTEXITCODE) {
        throw ("Registry command failed with exit code {0}: {1}" -f [int]$LASTEXITCODE, [string]$CommandText)
    }
}

function Set-DesktopIconSelection {
    param(
        [string]$HiveRoot
    )

    foreach ($viewKey in @("NewStartPanel", "ClassicStartMenu")) {
        $path = "{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\{1}" -f $HiveRoot, $viewKey
        $pathEscaped = ($path -replace '"', '\"')
        Invoke-RegCmdWithAllowedExitCodes -CommandText ("reg add `"" + $pathEscaped + "`" /v `"{59031a47-3f72-44a7-89c5-5595fe6b30ee}`" /t REG_DWORD /d 0 /f >nul 2>&1") # User Files
        Invoke-RegCmdWithAllowedExitCodes -CommandText ("reg add `"" + $pathEscaped + "`" /v `"{20D04FE0-3AEA-1069-A2D8-08002B30309D}`" /t REG_DWORD /d 0 /f >nul 2>&1") # This PC
        Invoke-RegCmdWithAllowedExitCodes -CommandText ("reg add `"" + $pathEscaped + "`" /v `"{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}`" /t REG_DWORD /d 0 /f >nul 2>&1") # Control Panel
        Invoke-RegCmdWithAllowedExitCodes -CommandText ("reg add `"" + $pathEscaped + "`" /v `"{645FF040-5081-101B-9F08-00AA002F954E}`" /t REG_DWORD /d 1 /f >nul 2>&1") # Recycle Bin hidden
    }
}

function Set-ClassicProfileVisualSettings {
    param(
        [string]$HiveRoot
    )

    Invoke-RegCmdWithAllowedExitCodes -CommandText ('reg delete "{0}\Control Panel\Desktop" /v Wallpaper /f >nul 2>&1' -f ($HiveRoot -replace '"', '\"')) -AllowedExitCodes @(0,1,2)
    Invoke-RegCmdWithAllowedExitCodes -CommandText ('reg add "{0}\Control Panel\Colors" /v Background /t REG_SZ /d "0 0 0" /f >nul 2>&1' -f ($HiveRoot -replace '"', '\"'))
    Invoke-RegCmdWithAllowedExitCodes -CommandText ('reg add "{0}\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v EnableTransparency /t REG_DWORD /d 0 /f >nul 2>&1' -f ($HiveRoot -replace '"', '\"'))
    Invoke-RegCmdWithAllowedExitCodes -CommandText ('reg add "{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ListviewAlphaSelect /t REG_DWORD /d 0 /f >nul 2>&1' -f ($HiveRoot -replace '"', '\"'))
    Invoke-RegCmdWithAllowedExitCodes -CommandText ('reg add "{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarAnimations /t REG_DWORD /d 0 /f >nul 2>&1' -f ($HiveRoot -replace '"', '\"'))
}

function Resolve-AdvancedTargetHives {
    # In non-interactive SSH sessions, loading other users' NTUSER.DAT can block on file locks.
    # Keep this task deterministic by applying only to the current user hive.
    return [pscustomobject]@{
        Targets = @("HKCU")
        Loaded = @()
    }
}

Invoke-AdvancedWarn -Label "desktop-icons-and-classic-ui-for-target-hives" -Action {
    $hiveState = Resolve-AdvancedTargetHives
    try {
        foreach ($hiveRoot in @($hiveState.Targets)) {
            Set-DesktopIconSelection -HiveRoot $hiveRoot
            Set-ClassicProfileVisualSettings -HiveRoot $hiveRoot
        }
    }
    finally {
        foreach ($loadedNative in @($hiveState.Loaded)) {
            & reg.exe unload $loadedNative | Out-Null
        }
    }
}

Invoke-AdvancedWarn -Label "visual-effects-best-performance" -Action {
    & reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v VisualFXSetting /t REG_DWORD /d 2 /f | Out-Null
}

Invoke-AdvancedWarn -Label "processor-background-services" -Action {
    & reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation /t REG_DWORD /d 24 /f | Out-Null
}

Invoke-AdvancedWarn -Label "custom-pagefile-800-8192" -Action {
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($computerSystem.AutomaticManagedPagefile) {
        Set-CimInstance -InputObject $computerSystem -Property @{ AutomaticManagedPagefile = $false } | Out-Null
    }

    $existingPageFiles = @(Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue)
    foreach ($existingPageFile in @($existingPageFiles)) {
        Remove-CimInstance -InputObject $existingPageFile -ErrorAction SilentlyContinue
    }

    try {
        New-CimInstance -ClassName Win32_PageFileSetting -Property @{
            Name = "C:\\pagefile.sys"
            InitialSize = [uint32]800
            MaximumSize = [uint32]8192
        } | Out-Null
    }
    catch {
        Invoke-RegCmdWithAllowedExitCodes -CommandText 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v PagingFiles /t REG_MULTI_SZ /d "C:\pagefile.sys 800 8192" /f >nul 2>&1'
        Invoke-RegCmdWithAllowedExitCodes -CommandText 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v ExistingPageFiles /t REG_MULTI_SZ /d "\??\C:\pagefile.sys" /f >nul 2>&1'
        Invoke-RegCmdWithAllowedExitCodes -CommandText 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v TempPageFile /t REG_DWORD /d 0 /f >nul 2>&1'
    }
}

Invoke-AdvancedWarn -Label "boot-timeout-and-dump-off" -Action {
    & bcdedit /timeout 0 | Out-Null
    & reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v CrashDumpEnabled /t REG_DWORD /d 0 /f | Out-Null
    & reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v AlwaysKeepMemoryDump /t REG_DWORD /d 0 /f | Out-Null
    & reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v LogEvent /t REG_DWORD /d 0 /f | Out-Null
    & reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v SendAlert /t REG_DWORD /d 0 /f | Out-Null
}

Invoke-AdvancedWarn -Label "dep-always-off" -Action {
    & bcdedit /set "{current}" nx AlwaysOff | Out-Null
}

Invoke-AdvancedWarn -Label "refresh-user-visual-parameters" -Action {
    $rundllPath = Join-Path $env:WINDIR "System32\rundll32.exe"
    if (-not (Test-Path -LiteralPath $rundllPath)) {
        throw ("rundll32.exe was not found at '{0}'." -f $rundllPath)
    }

    $proc = Start-Process `
        -FilePath $rundllPath `
        -ArgumentList "user32.dll,UpdatePerUserSystemParameters" `
        -WindowStyle Hidden `
        -PassThru
    if (-not $proc.WaitForExit(15000)) {
        try { $proc.Kill() } catch { }
        Write-Warning "UpdatePerUserSystemParameters timed out and was terminated."
    }
}

Write-Output "windows-advanced-system-settings-completed"
'@
        },
        [pscustomobject]@{
            Name = "16-local-service-disable-conservative"
            Script = @'
$ErrorActionPreference = "Stop"

$protectedServices = @(
    "TermService","sshd","ssh-agent","EventLog","RpcSs","Winmgmt","W32Time","Dnscache","LanmanWorkstation",
    "LanmanServer","NlaSvc","Dhcp","BFE","MpsSvc","wuauserv","BITS","TrustedInstaller","vmcompute","LxssManager","com.docker.service"
)
$disableCandidates = @(
    "DiagTrack","dmwappushservice","MapsBroker","RetailDemo","Fax","XblAuthManager","XblGameSave","XboxGipSvc","WSearch","WerSvc"
)

function Disable-ServiceIfSafe {
    param(
        [string]$ServiceName
    )

    if ($protectedServices -contains $ServiceName) {
        Write-Output ("service-skip-protected: {0}" -f $ServiceName)
        return
    }

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Output ("service-not-found: {0}" -f $ServiceName)
        return
    }

    try {
        $dependentServices = @($service.DependentServices | Where-Object { $_.Status -eq "Running" })
        if ($dependentServices.Count -gt 0) {
            Write-Warning ("service-skip-dependent-running: {0}" -f $ServiceName)
            return
        }

        if ($service.Status -eq "Running") {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        }
        Set-Service -Name $ServiceName -StartupType Disabled -ErrorAction Stop
        Write-Output ("service-disabled: {0}" -f $ServiceName)
    }
    catch {
        Write-Warning ("service-disable-failed: {0} => {1}" -f $ServiceName, $_.Exception.Message)
    }
}

foreach ($candidate in @($disableCandidates)) {
    Disable-ServiceIfSafe -ServiceName $candidate
}

Write-Output "local-service-disable-conservative-completed"
'@
        },
        [pscustomobject]@{
            Name = "17-health-snapshot"
            Script = @'
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
        SERVER_NAME = [string]$Context.ServerName
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
    if ($Platform -eq "windows") {
        $excludedInitTasks = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @("00-init-script", "01-ensure-local-admin-user", "02-openssh-install-service", "03-sshd-config-port", "04-rdp-firewall")) {
            [void]$excludedInitTasks.Add([string]$name)
        }
        $templates = @($templates | Where-Object { -not $excludedInitTasks.Contains([string]$_.Name) })
    }
    $replacements = Get-CoVmGuestTaskReplacementMap -Platform $Platform -Context $Context
    return (Apply-CoVmTaskBlockReplacements -TaskBlocks $templates -Replacements $replacements)
}

function Get-CoVmWindowsUpdateScriptFromTasks {
    param(
        [object[]]$TaskBlocks
    )

    if (-not $TaskBlocks -or $TaskBlocks.Count -eq 0) {
        throw "Windows VM update script build failed: no task blocks were provided."
    }

    $taskRows = New-Object System.Text.StringBuilder
    $hashInput = New-Object System.Text.StringBuilder
    foreach ($taskBlock in $TaskBlocks) {
        $taskName = [string]$taskBlock.Name
        $taskScript = [string]$taskBlock.Script
        $taskNameSafe = $taskName.Replace("'", "''")
        $taskBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($taskScript))
        [void]$taskRows.AppendLine(('$taskCatalog += [pscustomobject]@{{ Name = ''{0}''; ScriptBase64 = ''{1}'' }}' -f $taskNameSafe, $taskBase64))
        [void]$hashInput.AppendLine(($taskName + "|" + $taskScript))
    }

    $hashBytes = [System.Text.Encoding]::UTF8.GetBytes($hashInput.ToString())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($hashBytes)
    }
    finally {
        $sha.Dispose()
    }
    $catalogHash = [BitConverter]::ToString($hash).Replace("-", "").ToLowerInvariant()

    $template = @'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Output "Update phase started."

$stateDir = "C:\ProgramData\az-vm"
$statePath = Join-Path $stateDir "step8-state.json"
$catalogHash = "__TASK_CATALOG_HASH__"
$taskCatalog = @()
__TASK_ROWS__

function Convert-ToTaskSafeDetail {
    param(
        [string]$Detail
    )

    if ([string]::IsNullOrWhiteSpace($Detail)) {
        return ""
    }

    $text = $Detail -replace "[\r\n]+", " "
    $text = $text -replace ";", ","
    return $text.Trim()
}

function New-Step8State {
    param(
        [string]$CatalogHash,
        [int]$TaskCount
    )

    return @{
        CatalogHash = $CatalogHash
        TotalTaskCount = $TaskCount
        LastCompletedTaskIndex = -1
        LastTaskName = ""
        RebootCount = 0
        Completed = $false
        RebootRequired = $false
        SuccessCount = 0
        WarningCount = 0
        ErrorCount = 0
        TaskStatus = @{}
    }
}

function Load-Step8State {
    param(
        [string]$StatePath,
        [string]$CatalogHash,
        [int]$TaskCount
    )

    $state = New-Step8State -CatalogHash $CatalogHash -TaskCount $TaskCount
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return $state
    }

    try {
        $raw = Get-Content -Path $StatePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $state
        }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $state
    }

    if ($parsed.PSObject.Properties["CatalogHash"]) { $state.CatalogHash = [string]$parsed.CatalogHash }
    if ($parsed.PSObject.Properties["TotalTaskCount"]) { $state.TotalTaskCount = [int]$parsed.TotalTaskCount }
    if ($parsed.PSObject.Properties["LastCompletedTaskIndex"]) { $state.LastCompletedTaskIndex = [int]$parsed.LastCompletedTaskIndex }
    if ($parsed.PSObject.Properties["LastTaskName"]) { $state.LastTaskName = [string]$parsed.LastTaskName }
    if ($parsed.PSObject.Properties["RebootCount"]) { $state.RebootCount = [int]$parsed.RebootCount }
    if ($parsed.PSObject.Properties["Completed"]) { $state.Completed = [bool]$parsed.Completed }
    if ($parsed.PSObject.Properties["RebootRequired"]) { $state.RebootRequired = [bool]$parsed.RebootRequired }
    if ($parsed.PSObject.Properties["SuccessCount"]) { $state.SuccessCount = [int]$parsed.SuccessCount }
    if ($parsed.PSObject.Properties["WarningCount"]) { $state.WarningCount = [int]$parsed.WarningCount }
    if ($parsed.PSObject.Properties["ErrorCount"]) { $state.ErrorCount = [int]$parsed.ErrorCount }

    if ($parsed.PSObject.Properties["TaskStatus"] -and $parsed.TaskStatus) {
        foreach ($entry in $parsed.TaskStatus.PSObject.Properties) {
            $statusValue = ""
            $detailValue = ""
            if ($entry.Value -and $entry.Value.PSObject.Properties["Status"]) { $statusValue = [string]$entry.Value.Status }
            if ($entry.Value -and $entry.Value.PSObject.Properties["Detail"]) { $detailValue = [string]$entry.Value.Detail }
            $state.TaskStatus[[string]$entry.Name] = @{
                Status = $statusValue
                Detail = $detailValue
            }
        }
    }

    return $state
}

function Save-Step8State {
    param(
        [string]$StatePath,
        [hashtable]$State
    )

    $statusOut = [ordered]@{}
    foreach ($taskName in @($State.TaskStatus.Keys)) {
        $entry = $State.TaskStatus[$taskName]
        $statusOut[$taskName] = [ordered]@{
            Status = [string]$entry.Status
            Detail = [string]$entry.Detail
        }
    }

    $payload = [ordered]@{
        CatalogHash = [string]$State.CatalogHash
        TotalTaskCount = [int]$State.TotalTaskCount
        LastCompletedTaskIndex = [int]$State.LastCompletedTaskIndex
        LastTaskName = [string]$State.LastTaskName
        RebootCount = [int]$State.RebootCount
        Completed = [bool]$State.Completed
        RebootRequired = [bool]$State.RebootRequired
        SuccessCount = [int]$State.SuccessCount
        WarningCount = [int]$State.WarningCount
        ErrorCount = [int]$State.ErrorCount
        TaskStatus = $statusOut
    }

    ($payload | ConvertTo-Json -Depth 20) | Set-Content -Path $StatePath -Encoding UTF8
}

function Set-Step8TaskStatus {
    param(
        [hashtable]$State,
        [string]$TaskName,
        [string]$NewStatus,
        [string]$Detail = ""
    )

    if (-not $State.TaskStatus.ContainsKey($TaskName)) {
        $State.TaskStatus[$TaskName] = @{ Status = ""; Detail = "" }
    }

    $oldStatus = [string]$State.TaskStatus[$TaskName].Status
    switch ($oldStatus) {
        "success" { $State.SuccessCount = [Math]::Max(0, [int]$State.SuccessCount - 1) }
        "warning" { $State.WarningCount = [Math]::Max(0, [int]$State.WarningCount - 1) }
        "error" { $State.ErrorCount = [Math]::Max(0, [int]$State.ErrorCount - 1) }
    }

    switch ($NewStatus) {
        "success" { $State.SuccessCount = [int]$State.SuccessCount + 1 }
        "warning" { $State.WarningCount = [int]$State.WarningCount + 1 }
        "error" { $State.ErrorCount = [int]$State.ErrorCount + 1 }
        default { }
    }

    $safeDetail = Convert-ToTaskSafeDetail -Detail $Detail
    $State.TaskStatus[$TaskName] = @{
        Status = [string]$NewStatus
        Detail = [string]$safeDetail
    }

    Write-Output ("TASK_STATUS:{0}:{1}" -f $TaskName, $NewStatus)
    if (-not [string]::IsNullOrWhiteSpace($safeDetail)) {
        Write-Output ("TASK_DETAIL:{0}:{1}" -f $TaskName, $safeDetail)
    }
}

function Test-Step8RebootPending {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            return $true
        }
    }

    try {
        $pending = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue
        if ($pending -and $pending.PendingFileRenameOperations) {
            return $true
        }
    }
    catch { }

    return $false
}

if (-not (Test-Path -LiteralPath $stateDir)) {
    New-Item -Path $stateDir -ItemType Directory -Force | Out-Null
}

$state = Load-Step8State -StatePath $statePath -CatalogHash $catalogHash -TaskCount $taskCatalog.Count
if ($state.CatalogHash -ne $catalogHash -or [int]$state.TotalTaskCount -ne $taskCatalog.Count) {
    $state = New-Step8State -CatalogHash $catalogHash -TaskCount $taskCatalog.Count
}
if ($state.Completed -and -not $state.RebootRequired) {
    $state = New-Step8State -CatalogHash $catalogHash -TaskCount $taskCatalog.Count
}

$state.CatalogHash = $catalogHash
$state.TotalTaskCount = $taskCatalog.Count
if ($state.LastCompletedTaskIndex -gt ($taskCatalog.Count - 1)) {
    $state.LastCompletedTaskIndex = $taskCatalog.Count - 1
}
if ($state.LastCompletedTaskIndex -lt -1) {
    $state.LastCompletedTaskIndex = -1
}

if ($taskCatalog.Count -eq 0) {
    Write-Output "STEP8_SUMMARY:success=0;warning=0;error=0;reboot=0"
    Write-Output "Update phase completed."
    return
}

$startIndex = [int]$state.LastCompletedTaskIndex + 1

for ($taskIndex = $startIndex; $taskIndex -lt $taskCatalog.Count; $taskIndex++) {
    $task = $taskCatalog[$taskIndex]
    $taskName = [string]$task.Name
    Write-Output ("TASK started: {0}" -f $taskName)
    $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $decodedScript = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String([string]$task.ScriptBase64))
        Invoke-Expression $decodedScript
        if ($taskWatch.IsRunning) { $taskWatch.Stop() }
        Set-Step8TaskStatus -State $state -TaskName $taskName -NewStatus "success"
        Write-Output ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
        Write-Output "TASK result: success"
    }
    catch {
        if ($taskWatch.IsRunning) { $taskWatch.Stop() }
        $detail = if ($_.Exception) { $_.Exception.Message } else { [string]$_ }
        Set-Step8TaskStatus -State $state -TaskName $taskName -NewStatus "warning" -Detail $detail
        Write-Warning ("TASK warning: {0} => {1}" -f $taskName, $detail)
        Write-Output ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
        Write-Output "TASK result: warning"
    }

    $state.LastCompletedTaskIndex = $taskIndex
    $state.LastTaskName = $taskName
    $state.Completed = $false
    $state.RebootRequired = $false
    Save-Step8State -StatePath $statePath -State $state

    if (Test-Step8RebootPending) {
        $state.RebootRequired = $true
        $state.RebootCount = [int]$state.RebootCount + 1
        Save-Step8State -StatePath $statePath -State $state
        Write-Output ("TASK_REBOOT_REQUIRED:{0}:true" -f $taskName)
        Write-Output ("CO_VM_REBOOT_REQUIRED:task={0};index={1};rebootCount={2}" -f $taskName, $taskIndex, $state.RebootCount)
        Write-Output ("STEP8_SUMMARY:success={0};warning={1};error={2};reboot={3}" -f $state.SuccessCount, $state.WarningCount, $state.ErrorCount, $state.RebootCount)
        return
    }
}

$state.Completed = $true
$state.RebootRequired = $false
Save-Step8State -StatePath $statePath -State $state

Write-Output ("STEP8_SUMMARY:success={0};warning={1};error={2};reboot={3}" -f $state.SuccessCount, $state.WarningCount, $state.ErrorCount, $state.RebootCount)
Write-Output "Update phase completed."
'@

    return $template.Replace("__TASK_CATALOG_HASH__", $catalogHash).Replace("__TASK_ROWS__", $taskRows.ToString().TrimEnd())
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

    if ($Platform -eq "windows") {
        return (Get-CoVmWindowsUpdateScriptFromTasks -TaskBlocks $TaskBlocks)
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("#!/usr/bin/env bash")
    [void]$sb.AppendLine("set -euo pipefail")
    [void]$sb.AppendLine("exec 2>&1")
    [void]$sb.AppendLine('echo "Update phase started."')
    [void]$sb.AppendLine("")

    foreach ($taskBlock in $TaskBlocks) {
        $taskName = [string]$taskBlock.Name
        $taskScript = [string]$taskBlock.Script
        [void]$sb.AppendLine(("# Task: {0}" -f $taskName))
        [void]$sb.AppendLine($taskScript.Trim())
        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine('echo "Update phase completed."')
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

function Get-CoVmWindowsPostRebootProbeScript {
    param(
        [string]$ServerName = "",
        [string]$VmUser = "",
        [string]$AssistantUser = ""
    )

    @'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Write-Output "post-reboot-probe-started"
Write-Output ("server-name=__SERVER_NAME__")
Write-Output ("manager-user=__VM_USER__")
Write-Output ("assistant-user=__ASSISTANT_USER__")

if (Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue) {
    Set-Service -Name "com.docker.service" -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
}
if (Get-Service -Name "LxssManager" -ErrorAction SilentlyContinue) {
    Set-Service -Name "LxssManager" -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name "LxssManager" -ErrorAction SilentlyContinue
}

$dockerDesktopExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
if (Test-Path -LiteralPath $dockerDesktopExe) {
    if (-not (Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $dockerDesktopExe -ArgumentList "--minimized" -WindowStyle Minimized -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 10
    }
}

Write-Output "service-status:"
foreach ($serviceName in @("TermService","sshd","com.docker.service","LxssManager")) {
    $serviceObj = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($serviceObj) {
        Write-Output ("{0} => {1}/{2}" -f $serviceName, $serviceObj.Status, $serviceObj.StartType)
    }
    else {
        Write-Output ("{0} => not-found" -f $serviceName)
    }
}

if (Get-Command docker -ErrorAction SilentlyContinue) {
    Write-Output "docker-client:"
    docker --version
    Write-Output "docker-daemon:"
    docker version
}
else {
    $dockerCliPath = "C:\Program Files\Docker\Docker\resources\bin"
    if (Test-Path -LiteralPath $dockerCliPath) {
        $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($machinePath -notmatch [regex]::Escape($dockerCliPath)) {
            [Environment]::SetEnvironmentVariable("Path", ($machinePath.TrimEnd(';') + ";" + $dockerCliPath), "Machine")
            $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
        }
    }

    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Write-Output "docker-client:"
        docker --version
        Write-Output "docker-daemon:"
        docker version
    }
    else {
        Write-Warning "docker command not found in post-reboot probe."
    }
}

if (Get-Command wsl -ErrorAction SilentlyContinue) {
    Write-Output "wsl-status:"
    $wslStatusOutput = @(& cmd.exe /d /c "wsl --status 2>&1")
    $wslStatusCode = $LASTEXITCODE
    $wslStatusText = (@($wslStatusOutput) | ForEach-Object { [string]$_ }) -join "`n"
    if (-not [string]::IsNullOrWhiteSpace($wslStatusText)) {
        Write-Output $wslStatusText.Trim()
    }

    if ($wslStatusCode -ne 0 -or $wslStatusText -match '(?i)(not installed|wsl\.exe --install|windows subsystem for linux is not installed)') {
        Write-Warning "WSL is not installed yet."
    }
    else {
        Write-Output "wsl-version:"
        & cmd.exe /d /c "wsl --version 2>&1"
    }
}
else {
    Write-Warning "wsl command not found in post-reboot probe."
}

if (Get-Command ollama -ErrorAction SilentlyContinue) {
    Write-Output "ollama-version:"
    ollama --version
}
else {
    Write-Warning "ollama command not found in post-reboot probe."
}

Write-Output "post-reboot-probe-completed"
'@.Replace("__SERVER_NAME__", [string]$ServerName).Replace("__VM_USER__", [string]$VmUser).Replace("__ASSISTANT_USER__", [string]$AssistantUser)
}
