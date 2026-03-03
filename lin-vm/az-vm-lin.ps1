<#
Script Filename: az-vm-lin.ps1
Script Description    :
#>

param(
    [Alias('a','NonInteractive')]
    [switch]$Auto,
    [Alias('s')]
    [switch]$Substep
)

$script:AutoMode = [bool]$Auto
$script:SubstepMode = [bool]$Substep
$script:TranscriptStarted = $false
$script:HadError = $false
$script:ExitCode = 0
$script:ConfigOverrides = @{}

$script:DefaultErrorSummary = "An unexpected error occurred."
$script:DefaultErrorHint = "Review the error line and check script parameters and Azure connectivity."

$coVmRoot = Join-Path (Split-Path -Path $PSScriptRoot -Parent) "co-vm"
$coVmScripts = @(
    "az-vm-co-core.ps1",
    "az-vm-co-config.ps1",
    "az-vm-co-azure.ps1",
    "az-vm-co-orchestration.ps1",
    "az-vm-co-runcommand.ps1",
    "az-vm-co-sku-picker.ps1"
)
foreach ($coVmScript in $coVmScripts) {
    $coVmPath = Join-Path $coVmRoot $coVmScript
    if (-not (Test-Path -LiteralPath $coVmPath)) {
        throw "Required shared script was not found: $coVmPath"
    }
    . $coVmPath
}

try {
# 0) Start:
chcp 65001 | Out-Null
$Host.UI.RawUI.WindowTitle = "az vm lin"
Write-Host "script filename: az-vm-lin.ps1"
Write-Host "script description:
- A Linux Ubuntu virtual machine is created.
- The virtual machine is configured with cloud-init + vm-update scripts.
- SSH (444) access is prepared.
- All command output is written to both console and 'az-vm-lin-log.txt'.
- Run mode: interactive (default), auto (--auto / -a).
- Diagnostic mode: substep (--substep / -s), Step 8 runs tasks one-by-one.
- Without --substep, Step 8 runs the VM update script file in a single run-command call."
if (-not $script:AutoMode) {
    Read-Host -Prompt "Press Enter to start..."
}

$envFilePath = Join-Path $PSScriptRoot ".env"
$configMap = Read-DotEnvFile -Path $envFilePath

# 1) PARAMETERS / VARIABLES
Start-Transcript -Path "$PSScriptRoot\az-vm-lin-log.txt" -Force
$script:TranscriptStarted = $true
Invoke-Step "Step 1/9 - initial parameters will be configured..." {
    $step1Context = Invoke-CoVmStep1Common `
        -ConfigMap $configMap `
        -EnvFilePath $envFilePath `
        -AutoMode:$script:AutoMode `
        -ScriptRoot $PSScriptRoot `
        -ServerNameDefault "otherexamplevm" `
        -VmImageDefault "Canonical:ubuntu-24_04-lts:server:latest" `
        -VmDiskSizeDefault "40" `
        -VmCloudInitConfigKey "VM_CLOUD_INIT_FILE" `
        -VmCloudInitDefault "az-vm-lin-cloud-init.yaml" `
        -VmUpdateConfigKey "VM_UPDATE_SCRIPT_FILE" `
        -VmUpdateDefault "az-vm-lin-update.sh" `
        -ConfigOverrides $script:ConfigOverrides

    $serverName = [string]$step1Context.ServerName
    $resourceGroup = [string]$step1Context.ResourceGroup
    $defaultAzLocation = [string]$step1Context.DefaultAzLocation
    $VNET = [string]$step1Context.VNET
    $SUBNET = [string]$step1Context.SUBNET
    $NSG = [string]$step1Context.NSG
    $nsgRule = [string]$step1Context.NsgRule
    $IP = [string]$step1Context.IP
    $NIC = [string]$step1Context.NIC
    $vmName = [string]$step1Context.VmName
    $vmImage = [string]$step1Context.VmImage
    $vmStorageSku = [string]$step1Context.VmStorageSku
    $defaultVmSize = [string]$step1Context.DefaultVmSize
    $azLocation = [string]$step1Context.AzLocation
    $vmSize = [string]$step1Context.VmSize
    $vmDiskName = [string]$step1Context.VmDiskName
    $vmDiskSize = [string]$step1Context.VmDiskSize
    $vmUser = [string]$step1Context.VmUser
    $vmPass = [string]$step1Context.VmPass
    $sshPort = [string]$step1Context.SshPort
    $vmCloudInitScriptFile = [string]$step1Context.VmCloudInitScriptFile
    $vmUpdateScriptFile = [string]$step1Context.VmUpdateScriptFile
    $tcpPorts = @($step1Context.TcpPorts)
}

# 2) Resource availability check:
Invoke-Step "Step 2/9 - region, image, and VM size availability will be checked..." {
    Invoke-CoVmPrecheckStep -Context $step1Context
}

# 3) Resource group check:
Invoke-Step "Step 3/9 - resource group will be checked..." {
    Invoke-CoVmResourceGroupStep -Context $step1Context -AutoMode:$script:AutoMode
}

# 4) Network components provisioning:
Invoke-Step "Step 4/9 - VNet, subnet, NSG, NSG rules, public IP, and NIC will be created..." {
    Invoke-CoVmNetworkStep -Context $step1Context
}

# 5) Cloud-init file preparation:
Invoke-Step "Step 5/9 - cloud-init file will be prepared..." {
$cloudInitTemplate = @'
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

$cloudInitContent = $cloudInitTemplate.Replace("__VM_USER__", $vmUser).Replace("__VM_PASS__", $vmPass)
Write-TextFileNormalized `
    -Path $vmCloudInitScriptFile `
    -Content $cloudInitContent `
    -Encoding "utf8NoBom" `
    -LineEnding "lf" `
    -EnsureTrailingNewline
}

# 6) VM update shell script preparation:
Invoke-Step "Step 6/9 - VM update shell script will be prepared..." {
$tcpPortsBash = ($tcpPorts -join " ")
$tcpPortsRegex = ($tcpPorts | ForEach-Object { [regex]::Escape($_) }) -join "|"
$updateTemplate = @'
#!/usr/bin/env bash
set -euo pipefail
exec 2>&1

VM_USER="__VM_USER__"
VM_PASS="__VM_PASS__"
SSHD_CONFIG="/etc/ssh/sshd_config"

echo "Update phase started."

if ! id -u "${VM_USER}" >/dev/null 2>&1; then
  sudo useradd -m -s /bin/bash "${VM_USER}"
fi

echo "${VM_USER}:${VM_PASS}" | sudo chpasswd
echo "root:${VM_PASS}" | sudo chpasswd
sudo passwd -u "${VM_USER}" || true
sudo passwd -u root || true
sudo chage -E -1 "${VM_USER}" || true
sudo chage -E -1 root || true

sudo DEBIAN_FRONTEND=noninteractive apt update -y
sudo DEBIAN_FRONTEND=noninteractive apt install --upgrade -y apt-utils ufw nodejs npm git curl python-is-python3 python3-venv

sudo sed -i -E 's/^#?Port .*/Port __SSH_PORT__/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?PasswordAuthentication .*/PasswordAuthentication yes/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?PubkeyAuthentication .*/PubkeyAuthentication no/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?PermitRootLogin .*/PermitRootLogin yes/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?AllowTcpForwarding .*/AllowTcpForwarding yes/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?GatewayPorts .*/GatewayPorts yes/' "${SSHD_CONFIG}"

sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
TCP_PORTS=(__TCP_PORTS_BASH__)
for PORT in "${TCP_PORTS[@]}"; do
  sudo ufw allow "${PORT}/tcp"
done

sudo ufw --force enable
sudo setcap 'cap_net_bind_service=+ep' /usr/bin/node || true
sudo setcap 'cap_net_bind_service=+ep' /usr/sbin/sshd || true

sudo systemctl daemon-reload
sudo systemctl disable --now ssh.socket || true
sudo systemctl unmask ssh.service || true
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh.service

echo "Version Info:"
lsb_release -a || true

echo "OPEN Ports:"
ss -tlnp | grep -E ':(__TCP_PORTS_REGEX__)\b' || true

echo "Firewall STATUS:"
sudo ufw status verbose

echo "SSHD CONFIG:"
grep -E "^(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|AllowTcpForwarding|GatewayPorts)" "${SSHD_CONFIG}" || true

echo "Update phase completed."
'@

$updateScript = $updateTemplate.Replace("__VM_USER__", $vmUser).Replace("__VM_PASS__", $vmPass).Replace("__TCP_PORTS_BASH__", $tcpPortsBash).Replace("__TCP_PORTS_REGEX__", $tcpPortsRegex).Replace("__SSH_PORT__", $sshPort)
Write-TextFileNormalized `
    -Path $vmUpdateScriptFile `
    -Content $updateScript `
    -Encoding "utf8NoBom" `
    -LineEnding "lf" `
    -EnsureTrailingNewline
}

# 7) Virtual machine creation:
Invoke-Step "Step 7/9 - virtual machine will be created..." {
    Invoke-CoVmVmCreateStep `
        -Context $step1Context `
        -AutoMode:$script:AutoMode `
        -CreateVmAction {
            az vm create `
                --resource-group $resourceGroup `
                --name $vmName `
                --image $vmImage `
                --size $vmSize `
                --storage-sku $vmStorageSku `
                --os-disk-name $vmDiskName `
                --os-disk-size-gb $vmDiskSize `
                --admin-username $vmUser `
                --admin-password $vmPass `
                --authentication-type password `
                --custom-data "$vmCloudInitScriptFile" `
                --nics $NIC `
                -o json
        }
}

# 8) VM init/update script execution:
Invoke-Step "Step 8/9 - VM init and update scripts will be executed..." {
    $tcpPortsBash = ($tcpPorts -join " ")
    $tcpPortsRegex = ($tcpPorts | ForEach-Object { [regex]::Escape($_) }) -join "|"
    $taskBlocks = @(
        @{
            Name = "00-ensure-linux-user-passwords"
            Script = @'
set -euo pipefail
VM_USER="__VM_USER__"
VM_PASS="__VM_PASS__"
if ! id -u "${VM_USER}" >/dev/null 2>&1; then
  sudo useradd -m -s /bin/bash "${VM_USER}"
fi
echo "${VM_USER}:${VM_PASS}" | sudo chpasswd
echo "root:${VM_PASS}" | sudo chpasswd
sudo passwd -u "${VM_USER}" || true
sudo passwd -u root || true
sudo chage -E -1 "${VM_USER}" || true
sudo chage -E -1 root || true
echo "linux-user-passwords-ready"
'@
        },
        @{
            Name = "01-packages-update-install"
            Script = @'
set -euo pipefail
sudo DEBIAN_FRONTEND=noninteractive apt update -y
sudo DEBIAN_FRONTEND=noninteractive apt install --upgrade -y apt-utils ufw nodejs npm git curl python-is-python3 python3-venv
echo "linux-packages-ready"
'@
        },
        @{
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
        @{
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
        @{
            Name = "04-node-sshd-capabilities"
            Script = @'
set -euo pipefail
sudo setcap 'cap_net_bind_service=+ep' /usr/bin/node || true
sudo setcap 'cap_net_bind_service=+ep' /usr/sbin/sshd || true
echo "linux-capabilities-ready"
'@
        },
        @{
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
        @{
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

    $taskBlocks = Apply-CoVmTaskBlockReplacements `
        -TaskBlocks $taskBlocks `
        -Replacements @{
            VM_USER = $vmUser
            VM_PASS = $vmPass
            TCP_PORTS_BASH = $tcpPortsBash
            TCP_PORTS_REGEX = $tcpPortsRegex
            SSH_PORT = $sshPort
        }

    Invoke-CoVmStep8RunCommand `
        -SubstepMode:$script:SubstepMode `
        -ResourceGroup $resourceGroup `
        -VmName $vmName `
        -CommandId "RunShellScript" `
        -ScriptFilePath $vmUpdateScriptFile `
        -TaskBlocks $taskBlocks `
        -CombinedShell "bash"
}

# 9) VM connection details:
Invoke-Step "Step 9/9 - VM connection details will be printed..." {
    $vmConnectionInfo = Get-CoVmVmDetails -Context $step1Context
    $publicIP = [string]$vmConnectionInfo.PublicIP
    $vmFqdn = [string]$vmConnectionInfo.VmFqdn

    Write-Host "VM Public IP Address:"
    Write-Host "$publicIP"
    Write-Host "SSH Connection Command:"
    Write-Host "ssh -p $sshPort $vmUser@$vmFqdn"
}

# End of setup:
Write-Host "All console output was saved to 'az-vm-lin-log.txt'."
}
catch {
    $resolvedError = Resolve-CoVmFriendlyError `
        -ErrorRecord $_ `
        -DefaultErrorSummary $script:DefaultErrorSummary `
        -DefaultErrorHint $script:DefaultErrorHint

    Write-Host ""
    Write-Host "Script exited gracefully." -ForegroundColor Yellow
    Write-Host "Reason: $($resolvedError.Summary)" -ForegroundColor Red
    Write-Host "Detail: $($resolvedError.ErrorMessage)"
    Write-Host "Suggested action: $($resolvedError.Hint)" -ForegroundColor Cyan
    $script:HadError = $true
    $script:ExitCode = [int]$resolvedError.Code
}
finally {
    if ($script:TranscriptStarted) {
        Stop-Transcript | Out-Null
        $script:TranscriptStarted = $false
    }
    if (-not $script:AutoMode) {
        Read-Host -Prompt "Press Enter to exit." | Out-Null
    }
}

if ($script:HadError) {
    exit $script:ExitCode
}


