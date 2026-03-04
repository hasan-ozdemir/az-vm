<#
Script Filename: az-vm-win.ps1
Script Description    :
#>

param(
    [Alias('a','NonInteractive')]
    [switch]$Auto,
    [Alias('u')]
    [switch]$Update,
    [switch]$Ssh,
    [Alias('s')]
    [switch]$Substep
)

$script:AutoMode = [bool]$Auto
$script:UpdateMode = [bool]$Update
$script:SshMode = [bool]$Ssh
$script:SubstepMode = [bool]$Substep
$script:TranscriptStarted = $false
$script:HadError = $false
$script:ExitCode = 0
$script:ConfigOverrides = @{}

$script:DefaultErrorSummary = "An unexpected error occurred."
$script:DefaultErrorHint = "Review the error line and check script parameters and Azure connectivity."

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$coVmRoot = Join-Path $repoRoot "co-vm"
$coVmScripts = @(
    "az-vm-co-core.ps1",
    "az-vm-co-config.ps1",
    "az-vm-co-azure.ps1",
    "az-vm-co-guest.ps1",
    "az-vm-co-orchestration.ps1",
    "az-vm-co-runcommand.ps1",
    "az-vm-co-ssh.ps1",
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
$Host.UI.RawUI.WindowTitle = "az vm win"
Write-Host "script filename: az-vm-win.ps1"
Write-Host "script description:
- A Windows 11 25H2 AVD M365 virtual machine is created.
- The virtual machine is configured with init + vm-update scripts.
- SSH (444) and RDP (3389) access are prepared.
- All command output is written to both console and 'az-vm-win-log.txt'.
- Run mode: interactive (default), auto (--auto / -a).
- Fast update mode: --update / -u (resource group and existing VM are kept).
- Optional Step 8 SSH executor mode: --ssh (uses PuTTY/plink instead of az vm run-command).
- Diagnostic mode: substep (--substep / -s), Step 8 runs tasks one-by-one.
- Without --substep, Step 8 runs the VM update script file in a single call via the selected executor."
if (-not $script:AutoMode) {
    Read-Host -Prompt "Press Enter to start..."
}

$envFilePath = Join-Path $PSScriptRoot ".env"
$configMap = Read-DotEnvFile -Path $envFilePath

# 1) PARAMETERS / VARIABLES
Start-Transcript -Path "$PSScriptRoot\az-vm-win-log.txt" -Force
$script:TranscriptStarted = $true
Invoke-Step "Step 1/9 - initial parameters will be configured..." {
    $step1Context = Invoke-CoVmStep1Common `
        -ConfigMap $configMap `
        -EnvFilePath $envFilePath `
        -AutoMode:$script:AutoMode `
        -ScriptRoot $PSScriptRoot `
        -ServerNameDefault "examplevm" `
        -VmImageDefault "MicrosoftWindowsDesktop:office-365:win11-25h2-avd-m365:latest" `
        -VmDiskSizeDefault "128" `
        -VmInitConfigKey "VM_INIT_SCRIPT_FILE" `
        -VmInitDefault "az-vm-win-init.ps1" `
        -VmUpdateConfigKey "VM_UPDATE_SCRIPT_FILE" `
        -VmUpdateDefault "az-vm-win-update.ps1" `
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
    $vmInitScriptFile = [string]$step1Context.VmInitScriptFile
    $vmUpdateScriptFile = [string]$step1Context.VmUpdateScriptFile
    $tcpPorts = @($step1Context.TcpPorts)
    $winTaskFailurePolicyRaw = (Get-ConfigValue -Config $configMap -Key "WIN_TASK_FAILURE_POLICY" -DefaultValue "soft-warning")
    if ([string]::IsNullOrWhiteSpace($winTaskFailurePolicyRaw)) {
        $winTaskFailurePolicyRaw = "soft-warning"
    }
    $winTaskFailurePolicy = $winTaskFailurePolicyRaw.Trim().ToLowerInvariant()
    if ($winTaskFailurePolicy -ne "soft-warning" -and $winTaskFailurePolicy -ne "strict") {
        Write-Warning ("Invalid WIN_TASK_FAILURE_POLICY '{0}'. Falling back to 'soft-warning'." -f $winTaskFailurePolicyRaw)
        $winTaskFailurePolicy = "soft-warning"
    }
    $winStep8MaxRebootsText = Get-ConfigValue -Config $configMap -Key "WIN_STEP8_MAX_REBOOTS" -DefaultValue "3"
    $winStep8MaxReboots = 3
    if ($winStep8MaxRebootsText -match '^\d+$') {
        $winStep8MaxReboots = [int]$winStep8MaxRebootsText
    }
    if ($winStep8MaxReboots -lt 0) {
        $winStep8MaxReboots = 0
    }
    if ($winStep8MaxReboots -gt 3) {
        Write-Warning ("WIN_STEP8_MAX_REBOOTS '{0}' is above supported max. Using 3." -f $winStep8MaxReboots)
        $winStep8MaxReboots = 3
    }
    $step8ExecutorRaw = [string](Get-ConfigValue -Config $configMap -Key "STEP8_EXECUTOR" -DefaultValue "run-command")
    if ([string]::IsNullOrWhiteSpace($step8ExecutorRaw)) {
        $step8ExecutorRaw = "run-command"
    }
    $step8Executor = "run-command"
    switch ($step8ExecutorRaw.Trim().ToLowerInvariant()) {
        "ssh" { $step8Executor = "ssh" }
        "runcommand" { $step8Executor = "run-command" }
        "run-command" { $step8Executor = "run-command" }
        default {
            Write-Warning ("Invalid STEP8_EXECUTOR '{0}'. Falling back to 'run-command'." -f $step8ExecutorRaw)
            $step8Executor = "run-command"
        }
    }
    if ($script:SshMode) {
        $step8Executor = "ssh"
        $script:ConfigOverrides["STEP8_EXECUTOR"] = "ssh"
    }
    $step8UseSshExecutor = [bool]($step8Executor -eq "ssh")
    $sshMaxRetriesText = [string](Get-ConfigValue -Config $configMap -Key "SSH_MAX_RETRIES" -DefaultValue "3")
    $sshMaxRetries = Resolve-CoVmSshRetryCount -RetryText $sshMaxRetriesText -DefaultValue 3
    $configuredPlinkPath = [string](Get-ConfigValue -Config $configMap -Key "PUTTY_PLINK_PATH" -DefaultValue "")
    $configuredPscpPath = [string](Get-ConfigValue -Config $configMap -Key "PUTTY_PSCP_PATH" -DefaultValue "")

    $windowsPostRebootProbeScript = Get-CoVmWindowsPostRebootProbeScript `
        -ServerName $serverName `
        -VmUser $vmUser `
        -AssistantUser $vmAssistantUser

    if ($script:AutoMode) {
        Show-CoVmRuntimeConfigurationSnapshot `
            -Platform "windows" `
            -ScriptName "az-vm-win.ps1" `
            -ScriptRoot $PSScriptRoot `
            -AutoMode:$script:AutoMode `
            -UpdateMode:$script:UpdateMode `
            -SubstepMode:$script:SubstepMode `
            -SshMode:$step8UseSshExecutor `
            -ConfigMap $configMap `
            -ConfigOverrides $script:ConfigOverrides `
            -Context $step1Context
    }
}

# 2) Resource availability check:
Invoke-Step "Step 2/9 - region, image, and VM size availability will be checked..." {
    Invoke-CoVmPrecheckStep -Context $step1Context
}

# 3) Resource group check:
Invoke-Step "Step 3/9 - resource group will be checked..." {
    Invoke-CoVmResourceGroupStep -Context $step1Context -AutoMode:$script:AutoMode -UpdateMode:$script:UpdateMode
}

# 4) Network components provisioning:
Invoke-Step "Step 4/9 - VNet, subnet, NSG, NSG rules, public IP, and NIC will be created..." {
    Invoke-CoVmNetworkStep -Context $step1Context
}

# 5) VM init PowerShell script preparation:
Invoke-Step "Step 5/9 - VM init PowerShell script will be prepared..." {
    Show-CoVmStepFirstUseValues `
        -StepLabel "Step 5/9 - Windows init script preparation" `
        -Context $step1Context `
        -Keys @("VmInitScriptFile") `
        -ExtraValues @{
            Platform = "windows"
        }

    $vmInitScript = Get-CoVmWindowsInitScriptContent
    $writeSettings = Get-CoVmWriteSettingsForPlatform -Platform "windows"
    Write-TextFileNormalized `
        -Path $vmInitScriptFile `
        -Content $vmInitScript `
        -Encoding $writeSettings.Encoding `
        -LineEnding $writeSettings.LineEnding `
        -EnsureTrailingNewline
}

# 6) VM update PowerShell script preparation:
Invoke-Step "Step 6/9 - VM update PowerShell script will be prepared..." {
    Show-CoVmStepFirstUseValues `
        -StepLabel "Step 6/9 - Windows update script preparation" `
        -Context $step1Context `
        -Keys @("VmUpdateScriptFile", "VmAssistantUser", "VmAssistantPass")

    $taskBlocks = Resolve-CoVmGuestTaskBlocks -Platform "windows" -Context $step1Context -VmInitScriptFile $vmInitScriptFile
    Show-CoVmStepFirstUseValues `
        -StepLabel "Step 6/9 - Windows update script preparation" `
        -Context $step1Context `
        -ExtraValues @{
            WindowsTaskBlockCount = @($taskBlocks).Count
        }
    $updateScript = Get-CoVmUpdateScriptContentFromTasks -Platform "windows" -TaskBlocks $taskBlocks
    $writeSettings = Get-CoVmWriteSettingsForPlatform -Platform "windows"
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
        -UpdateMode:$script:UpdateMode `
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
                --nics $NIC `
                -o json
        }
}

# 8) VM init/update script execution:
Invoke-Step "Step 8/9 - VM init and update scripts will be executed..." {
    $step8ExecutorLabel = if ($step8UseSshExecutor) { "ssh" } else { "run-command" }
    Show-CoVmStepFirstUseValues `
        -StepLabel "Step 8/9 - Windows guest execution" `
        -Context $step1Context `
        -ExtraValues @{
            Step8Executor = $step8ExecutorLabel
            WindowsRunCommandId = "RunPowerShellScript"
            WindowsUpdateScriptFile = $vmUpdateScriptFile
            WinTaskFailurePolicy = $winTaskFailurePolicy
            WinStep8MaxReboots = $winStep8MaxReboots
            SshMaxRetries = $sshMaxRetries
            PuttyPlinkPath = $configuredPlinkPath
            PuttyPscpPath = $configuredPscpPath
        }

    $taskBlocks = Resolve-CoVmGuestTaskBlocks -Platform "windows" -Context $step1Context -VmInitScriptFile $vmInitScriptFile

    if ($step8UseSshExecutor) {
        Write-Host "Preparing SSH bootstrap over run-command before Step 8 SSH task flow..."
        $sshBootstrapTaskNameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($bootstrapTaskName in @("00-init-script", "01-ensure-local-admin-user", "02-openssh-install-service", "03-sshd-config-port", "04-rdp-firewall")) {
            [void]$sshBootstrapTaskNameSet.Add([string]$bootstrapTaskName)
        }

        $sshBootstrapTaskBlocks = @(
            $taskBlocks | Where-Object {
                $sshBootstrapTaskNameSet.Contains([string]$_.Name)
            }
        )
        if (-not $sshBootstrapTaskBlocks -or $sshBootstrapTaskBlocks.Count -eq 0) {
            throw "Step 8 SSH bootstrap could not build bootstrap task list."
        }

        $bootstrapSb = New-Object System.Text.StringBuilder
        foreach ($bootstrapTask in $sshBootstrapTaskBlocks) {
            [void]$bootstrapSb.AppendLine(("# SSH bootstrap task: {0}" -f [string]$bootstrapTask.Name))
            [void]$bootstrapSb.AppendLine(([string]$bootstrapTask.Script).Trim())
            [void]$bootstrapSb.AppendLine("")
        }
        $bootstrapScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("az-vm-win-ssh-bootstrap-{0}.ps1" -f $vmName)
        $bootstrapWriteSettings = Get-CoVmWriteSettingsForPlatform -Platform "windows"
        Write-TextFileNormalized `
            -Path $bootstrapScriptPath `
            -Content $bootstrapSb.ToString() `
            -Encoding $bootstrapWriteSettings.Encoding `
            -LineEnding $bootstrapWriteSettings.LineEnding `
            -EnsureTrailingNewline

        try {
            $bootstrapInitResult = Invoke-VmRunCommandScriptFile `
                -ResourceGroup $resourceGroup `
                -VmName $vmName `
                -CommandId "RunPowerShellScript" `
                -ScriptFilePath $bootstrapScriptPath `
                -ModeLabel "ssh-bootstrap-init"
            if (-not [string]::IsNullOrWhiteSpace([string]$bootstrapInitResult.Message)) {
                Write-Host $bootstrapInitResult.Message
            }
        }
        finally {
            Remove-Item -Path $bootstrapScriptPath -Force -ErrorAction SilentlyContinue
        }
        Write-Host "Waiting 20 seconds for SSH service to settle after bootstrap..."
        Start-Sleep -Seconds 20

        $vmRuntimeDetails = Get-CoVmVmDetails -Context $step1Context
        $sshHost = [string]$vmRuntimeDetails.VmFqdn
        if ([string]::IsNullOrWhiteSpace($sshHost)) {
            $sshHost = [string]$vmRuntimeDetails.PublicIP
        }
        if ([string]::IsNullOrWhiteSpace($sshHost)) {
            throw "Step 8 SSH mode could not resolve VM SSH host (FQDN/Public IP)."
        }

        Show-CoVmStepFirstUseValues `
            -StepLabel "Step 8/9 - Windows guest execution" `
            -Context $step1Context `
            -ExtraValues @{
                Step8SshHost = $sshHost
                Step8SshUser = $vmUser
                Step8SshPort = $sshPort
            }

        Invoke-CoVmStep8OverSsh `
            -Platform "windows" `
            -SubstepMode:$script:SubstepMode `
            -RepoRoot $repoRoot `
            -ResourceGroup $resourceGroup `
            -VmName $vmName `
            -SshHost $sshHost `
            -SshUser $vmUser `
            -SshPassword $vmPass `
            -SshPort $sshPort `
            -ScriptFilePath $vmUpdateScriptFile `
            -TaskBlocks $taskBlocks `
            -RebootAfterExecution `
            -PostRebootProbeScript $windowsPostRebootProbeScript `
            -PostRebootProbeCommandId "RunPowerShellScript" `
            -MaxReboots $winStep8MaxReboots `
            -TaskFailurePolicy $winTaskFailurePolicy `
            -SshMaxRetries $sshMaxRetries `
            -ConfiguredPlinkPath $configuredPlinkPath `
            -ConfiguredPscpPath $configuredPscpPath
    }
    else {
        Invoke-CoVmStep8RunCommand `
            -SubstepMode:$script:SubstepMode `
            -ResourceGroup $resourceGroup `
            -VmName $vmName `
            -CommandId "RunPowerShellScript" `
            -ScriptFilePath $vmUpdateScriptFile `
            -TaskBlocks $taskBlocks `
            -CombinedShell "powershell" `
            -RebootAfterExecution `
            -PostRebootProbeScript $windowsPostRebootProbeScript `
            -PostRebootProbeCommandId "RunPowerShellScript" `
            -MaxReboots $winStep8MaxReboots `
            -TaskFailurePolicy $winTaskFailurePolicy
    }
}

# 9) VM connection details:
Invoke-Step "Step 9/9 - VM connection details will be printed..." {
    Show-CoVmStepFirstUseValues `
        -StepLabel "Step 9/9 - connection output" `
        -Context $step1Context `
        -ExtraValues @{
            ManagerUser = $vmUser
            AssistantUser = $vmAssistantUser
        }

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
}

# End of setup:
Write-Host "All console output was saved to 'az-vm-win-log.txt'."
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







