<#
Script Filename: az-vm-lin.ps1
Script Description    :
#>

param(
    [Alias('a','NonInteractive')]
    [switch]$Auto,
    [Alias('s')]
    [switch]$Step
)

$script:AutoMode = [bool]$Auto
$script:StepMode = [bool]$Step
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
    "az-vm-co-runcommand.ps1"
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
- Diagnostic mode: step (--step / -s), Step 8 runs tasks one-by-one.
- Without --step, Step 8 runs the VM update script file in a single run-command call."
if (-not $script:AutoMode) {
    Read-Host -Prompt "Press Enter to start..."
}

$envFilePath = Join-Path $PSScriptRoot ".env"
$configMap = Read-DotEnvFile -Path $envFilePath

# 1) PARAMETERS / VARIABLES
Start-Transcript -Path "$PSScriptRoot\az-vm-lin-log.txt" -Force
$script:TranscriptStarted = $true
Invoke-Step "Step 1/9 - initial parameters will be configured..." {
    $serverNameDefault = Get-ConfigValue -Config $configMap -Key "SERVER_NAME" -DefaultValue "otherexamplevm"
    $serverName = $serverNameDefault
    do {
        if ($script:AutoMode) {
            $userInput = $serverNameDefault
        }
        else {
            $userInput = Read-Host "Enter server name (default=$serverNameDefault)"
        }

        if ([string]::IsNullOrWhiteSpace($userInput)) {
            $userInput = $serverNameDefault
        }

        if ($userInput -match '^[a-zA-Z][a-zA-Z0-9\-]{2,15}$') {
            $isValid = $true
        }
        else {
            Write-Host "Invalid VM name. Try again." -ForegroundColor Red
            $isValid = $false
        }
    } until ($isValid)

    $serverName = $userInput
    $script:ConfigOverrides["SERVER_NAME"] = $serverName
    Write-Host "Server name '$serverName' will be used." -ForegroundColor Green
    $resourceGroup = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "RESOURCE_GROUP" -DefaultValue "rg-{SERVER_NAME}") -ServerName $serverName
    $azLocation = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "AZ_LOCATION" -DefaultValue "austriaeast") -ServerName $serverName
    $VNET = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VNET_NAME" -DefaultValue "vnet-{SERVER_NAME}") -ServerName $serverName
    $SUBNET = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "SUBNET_NAME" -DefaultValue "subnet-{SERVER_NAME}") -ServerName $serverName
    $NSG = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "NSG_NAME" -DefaultValue "nsg-{SERVER_NAME}") -ServerName $serverName
    $nsgRule = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "NSG_RULE_NAME" -DefaultValue "nsg-rule-{SERVER_NAME}") -ServerName $serverName

    $IP = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "PUBLIC_IP_NAME" -DefaultValue "ip-{SERVER_NAME}") -ServerName $serverName
    $NIC = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "NIC_NAME" -DefaultValue "nic-{SERVER_NAME}") -ServerName $serverName
    $vmName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_NAME" -DefaultValue "{SERVER_NAME}") -ServerName $serverName
    $vmImage = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_IMAGE" -DefaultValue "Canonical:ubuntu-24_04-lts:server:latest") -ServerName $serverName
    $vmStorageSku = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_STORAGE_SKU" -DefaultValue "StandardSSD_LRS") -ServerName $serverName
    $vmSize = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_SIZE" -DefaultValue "Standard_B2as_v2") -ServerName $serverName
    $vmDiskName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_DISK_NAME" -DefaultValue "disk-{SERVER_NAME}") -ServerName $serverName
    $vmDiskSize = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_DISK_SIZE_GB" -DefaultValue "40") -ServerName $serverName
    $vmUser = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_USER" -DefaultValue "manager") -ServerName $serverName
    $vmPass = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_PASS" -DefaultValue "<runtime-secret>") -ServerName $serverName
    $sshPort = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "SSH_PORT" -DefaultValue "444") -ServerName $serverName

    $vmCloudInitScriptName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_CLOUD_INIT_FILE" -DefaultValue "az-vm-lin-cloud-init.yaml") -ServerName $serverName
    $vmUpdateScriptName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_UPDATE_SCRIPT_FILE" -DefaultValue "az-vm-lin-update.sh") -ServerName $serverName
    $vmCloudInitScriptFile = Resolve-ConfigPath -PathValue $vmCloudInitScriptName -RootPath $PSScriptRoot
    $vmUpdateScriptFile = Resolve-ConfigPath -PathValue $vmUpdateScriptName -RootPath $PSScriptRoot

    $defaultPortsCsv = "80,443,444,8444,3389,389,5173,3000,3001,8080,5432,3306,6837,4000,4001,5000,5001,6000,6001,6060,7000,7001,7070,8000,8001,9000,9001,9090,2222,3333,4444,5555,6666,7777,8888,9999,11434"
    $tcpPortsCsv = Get-ConfigValue -Config $configMap -Key "TCP_PORTS" -DefaultValue $defaultPortsCsv
    $tcpPorts = @($tcpPortsCsv -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })
    if (-not ($sshPort -match '^\d+$')) {
        throw "Invalid SSH port '$sshPort'."
    }
    if ($tcpPorts -notcontains $sshPort) {
        $tcpPorts += $sshPort
    }
    if (-not $tcpPorts -or $tcpPorts.Count -eq 0) {
        throw "No valid TCP ports were found in TCP_PORTS."
    }
}

# 2) Resource availability check:
Invoke-Step "Step 2/9 - region, image, and VM size availability will be checked..." {
    Assert-LocationExists -Location $azLocation
    Assert-VmImageAvailable -Location $azLocation -ImageUrn $vmImage
    Assert-VmSkuAvailableViaRest -Location $azLocation -VmSize $vmSize
    Assert-VmOsDiskSizeCompatible -Location $azLocation -ImageUrn $vmImage -VmDiskSizeGb $vmDiskSize
}

# 3) Resource group check:
Invoke-Step "Step 3/9 - resource group will be checked..." {
    Write-Host "'$resourceGroup'"
    $resourceExists = az group exists -n $resourceGroup
    Assert-LastExitCode "az group exists"
    if ($resourceExists -eq 'true') {
        if ($script:AutoMode) {
            Write-Host "Resource group '$resourceGroup' will be deleted (mode: auto)."
        }
        else {
            Write-Host "Resource group '$resourceGroup' will be deleted. Are you sure?"
        }
        az group delete -n $resourceGroup --yes --no-wait
        Assert-LastExitCode "az group delete"
        az group wait -n $resourceGroup --deleted
        Assert-LastExitCode "az group wait deleted"
    }
    Write-Host "Creating resource group '$resourceGroup'..."
    az group create -n $resourceGroup -l $azLocation
    Assert-LastExitCode "az group create"
}

# 4) Network components provisioning:
Invoke-Step "Step 4/9 - VNet, subnet, NSG, NSG rules, public IP, and NIC will be created..." {
    az network vnet create -g $resourceGroup -n $VNET --address-prefix 10.20.0.0/16 `
        --subnet-name $SUBNET --subnet-prefix 10.20.0.0/24 -o table
    Assert-LastExitCode "az network vnet create"
    az network nsg create -g $resourceGroup -n $NSG -o table
    Assert-LastExitCode "az network nsg create"

    $ports = $tcpPorts
    $priority = 101
    az network nsg rule create `
        -g $resourceGroup `
        --nsg-name $NSG `
        --name "$nsgRule" `
        --priority $priority `
        --direction Inbound `
        --protocol Tcp `
        --access Allow `
        --destination-port-ranges $ports `
        --source-address-prefixes "*" `
        --source-port-ranges "*" `
        -o table
    Assert-LastExitCode "az network nsg rule create"

    Write-Host "Creating public IP '$IP'..."
    az network public-ip create -g $resourceGroup -n $IP --allocation-method Static --sku Standard --dns-name $vmName -o table
    Assert-LastExitCode "az network public-ip create"

    Write-Host "Creating network NIC '$NIC'..."
    az network nic create -g $resourceGroup -n $NIC --vnet-name $VNET --subnet $SUBNET `
        --network-security-group $NSG `
        --public-ip-address $IP `
        -o table
    Assert-LastExitCode "az network nic create"
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
$cloudInitContent | Set-Content -Encoding UTF8 $vmCloudInitScriptFile
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
$updateScript | Set-Content -Encoding UTF8 $vmUpdateScriptFile
}

# 7) Virtual machine creation:
Invoke-Step "Step 7/9 - virtual machine will be created..." {
    $existingVM = az vm list `
        --resource-group $resourceGroup `
        --query "[?name=='$vmName'].name | [0]" `
        -o tsv
    Assert-LastExitCode "az vm list"

    if ($existingVM) {
        Write-Output "VM '$vmName' exists in resource group '$resourceGroup' and will be deleted..."
        az vm delete --name $vmName --resource-group $resourceGroup --yes -o table
        Assert-LastExitCode "az vm delete"
        Write-Output "VM '$vmName' was deleted from resource group '$resourceGroup'."
    }
    else {
        Write-Output "VM '$vmName' is not present in resource group '$resourceGroup'. Creating..."
    }

    $vmCreateJson = az vm create `
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

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "az vm create returned a non-zero code; checking VM existence."
        $vmExistsAfterCreate = az vm show -g $resourceGroup -n $vmName --query "id" -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($vmExistsAfterCreate)) {
            Write-Host "VM exists; details will be retrieved via az vm show -d."
            $vmCreateJson = az vm show -g $resourceGroup -n $vmName -d -o json
            Assert-LastExitCode "az vm show -d after vm create non-zero"
        }
        else {
            throw "az vm create failed with exit code $LASTEXITCODE."
        }
    }

    $vmCreateObj = $vmCreateJson | ConvertFrom-Json
    if (-not $vmCreateObj.id) {
        throw "az vm create completed but VM id was not returned."
    }

    Write-Host "Printing az vm create output..."
    Write-Host $vmCreateJson
}

# 8) VM init/update script execution:
Invoke-Step "Step 8/9 - VM init and update scripts will be executed..." {
    if (-not $script:StepMode) {
        Write-Host "Auto mode enabled: Step 8 tasks will run from the VM update script file."
        Invoke-VmRunCommandScriptFile `
            -ResourceGroup $resourceGroup `
            -VmName $vmName `
            -CommandId "RunShellScript" `
            -ScriptFilePath $vmUpdateScriptFile `
            -ModeLabel "auto-mode update-script-file"
        return
    }

    Write-Host "Step mode enabled: Step 8 will execute tasks one-by-one."
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

    foreach ($taskBlock in $taskBlocks) {
        $taskBlock.Script = ([string]$taskBlock.Script).Replace("__VM_USER__", $vmUser).Replace("__VM_PASS__", $vmPass).Replace("__TCP_PORTS_BASH__", $tcpPortsBash).Replace("__TCP_PORTS_REGEX__", $tcpPortsRegex).Replace("__SSH_PORT__", $sshPort)
    }

    Invoke-VmRunCommandBlocks `
        -ResourceGroup $resourceGroup `
        -VmName $vmName `
        -CommandId "RunShellScript" `
        -TaskBlocks $taskBlocks `
        -StepMode:$true `
        -CombinedShell "bash"
}

# 9) VM connection details:
Invoke-Step "Step 9/9 - VM connection details will be printed..." {
    $vmDetailsJson = az vm show -g $resourceGroup -n $vmName -d -o json
    Assert-LastExitCode "az vm show -d"
    $vmDetails = $vmDetailsJson | ConvertFrom-Json
    if (-not $vmDetails) {
        throw "VM detail output could not be parsed."
    }

    $publicIP = $vmDetails.publicIps
    $vmFqdn = $vmDetails.fqdns
    if ([string]::IsNullOrWhiteSpace($vmFqdn)) {
        $vmFqdn = "$vmName.$azLocation.cloudapp.azure.com"
    }

    Write-Host "VM Public IP Address:"
    Write-Host "$publicIP"
    Write-Host "SSH Connection Command:"
    Write-Host "ssh -p $sshPort $vmUser@$vmFqdn"
}

# End of setup:
Write-Host "All console output was saved to 'az-vm-lin-log.txt'."
}
catch {
    $errorMessage = $_.Exception.Message
    $summary = $script:DefaultErrorSummary
    $hint = $script:DefaultErrorHint
    $code = 99

    if ($_.Exception.Data -and $_.Exception.Data.Contains("ExitCode")) {
        $code = [int]$_.Exception.Data["ExitCode"]
        if ($_.Exception.Data.Contains("Summary")) {
            $summary = [string]$_.Exception.Data["Summary"]
        }
        if ($_.Exception.Data.Contains("Hint")) {
            $hint = [string]$_.Exception.Data["Hint"]
        }
    }
    elseif ($errorMessage -match "^VM size '(.+)' is available in region '(.+)' but not available for this subscription\.$") {
        $summary = "VM size exists in region but is not available for this subscription."
        $hint = "Choose another size in the same region or fix subscription quota/permissions."
        $code = 21
    }
    elseif ($errorMessage -match "^az group create failed with exit code") {
        $summary = "Resource group creation step failed."
        $hint = "Check region, policy, and subscription permissions."
        $code = 30
    }
    elseif ($errorMessage -match "^az vm create failed with exit code") {
        $summary = "VM creation step failed."
        $hint = "Check Step-2 precheck results, vmSize/image compatibility, and quota status."
        $code = 40
    }
    elseif ($errorMessage -match "^az vm run-command invoke") {
        $summary = "Configuration command inside VM failed."
        $hint = "Check VM running state and RunCommand availability."
        $code = 50
    }
    elseif ($errorMessage -match "^VM task '(.+)' failed:") {
        $summary = "A task failed in step mode."
        $hint = "Review the task name in the error detail and fix the related command."
        $code = 51
    }
    elseif ($errorMessage -match "^VM task batch execution failed") {
        $summary = "One or more tasks failed in auto mode."
        $hint = "Review the related task in the log file and fix the command."
        $code = 52
    }

    Write-Host ""
    Write-Host "Script exited gracefully." -ForegroundColor Yellow
    Write-Host "Reason: $summary" -ForegroundColor Red
    Write-Host "Detail: $errorMessage"
    Write-Host "Suggested action: $hint" -ForegroundColor Cyan
    $script:HadError = $true
    $script:ExitCode = $code
}
finally {
    if ($script:TranscriptStarted) {
        Stop-Transcript | Out-Null
        $script:TranscriptStarted = $false
    }
    if (-not $script:AutoMode) {
        pause
    }
}

if ($script:HadError) {
    exit $script:ExitCode
}


