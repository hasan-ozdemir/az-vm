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
    "az-vm-co-guest.ps1",
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
    $vmAssistantUser = [string]$step1Context.VmAssistantUser
    $vmAssistantPass = [string]$step1Context.VmAssistantPass
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
    $cloudInitContent = Get-CoVmLinuxCloudInitContent -VmUser $vmUser -VmPass $vmPass
    $writeSettings = Get-CoVmWriteSettingsForPlatform -Platform "linux"
    Write-TextFileNormalized `
        -Path $vmCloudInitScriptFile `
        -Content $cloudInitContent `
        -Encoding $writeSettings.Encoding `
        -LineEnding $writeSettings.LineEnding `
        -EnsureTrailingNewline
}

# 6) VM update shell script preparation:
Invoke-Step "Step 6/9 - VM update shell script will be prepared..." {
    $taskBlocks = Resolve-CoVmGuestTaskBlocks -Platform "linux" -Context $step1Context
    $updateScript = Get-CoVmUpdateScriptContentFromTasks -Platform "linux" -TaskBlocks $taskBlocks
    $writeSettings = Get-CoVmWriteSettingsForPlatform -Platform "linux"
    Write-TextFileNormalized `
        -Path $vmUpdateScriptFile `
        -Content $updateScript `
        -Encoding $writeSettings.Encoding `
        -LineEnding $writeSettings.LineEnding `
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
    $taskBlocks = Resolve-CoVmGuestTaskBlocks -Platform "linux" -Context $step1Context

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
    $connectionModel = Get-CoVmConnectionDisplayModel `
        -Context $step1Context `
        -ManagerUser $vmUser `
        -AssistantUser $vmAssistantUser `
        -SshPort $sshPort `
        -IncludeRdp

    Write-Host "VM Public IP Address:"
    Write-Host ([string]$connectionModel.PublicIP)
    Write-Host "SSH Connection Commands:"
    foreach ($sshConnection in @($connectionModel.SshConnections)) {
        Write-Host ("- {0}: {1}" -f ([string]$sshConnection.User), ([string]$sshConnection.Command))
    }
    Write-Host "RDP Connection Commands:"
    foreach ($rdpConnection in @($connectionModel.RdpConnections)) {
        Write-Host ("- {0}: {1}" -f ([string]$rdpConnection.User), ([string]$rdpConnection.Command))
        Write-Host ("  username: {0}" -f ([string]$rdpConnection.Username))
    }
    Write-Host "RDP note: Linux update tasks do not install/configure an RDP service by default." -ForegroundColor Yellow
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


