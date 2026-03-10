# Main command pipeline and end-to-end execution flow.

# Handles Invoke-AzVmMain.
function Invoke-AzVmMain {
    param(
        [switch]$WindowsFlag,
        [switch]$LinuxFlag,
        [ValidateSet('create','update')]
        [string]$CommandName = 'create',
        [hashtable]$InitialConfigOverrides = @{},
        [psobject]$ActionPlan = $null
    )

    try {
        $script:HadError = $false
        $script:ExitCode = 0
        $script:TranscriptStarted = $false
        $repoRoot = Get-AzVmRepoRoot
        chcp 65001 | Out-Null
        $Host.UI.RawUI.WindowTitle = 'az vm'

        Write-Host 'script filename: az-vm.ps1'
        Write-Host "script description:
- A unified Linux/Windows virtual machine deployment flow is executed.
- OS type is selected by --windows/--linux or VM_OS_TYPE from .env.
- Init tasks run in full create/update flow via Azure Run Command task-batch.
- Update tasks run via persistent pyssh task-by-task.
- SSH and RDP (Windows) access are prepared from VM_SSH_PORT / VM_RDP_PORT.
- Command mode: $CommandName.
- Run mode: interactive (default), auto (--auto).
- Performance timing mode: --perf.
- Create mode: keep existing resources by default.
- Update mode: always run create-or-update commands without delete."

        $effectiveActionPlan = $ActionPlan
        if ($null -eq $effectiveActionPlan) {
            $effectiveActionPlan = [pscustomobject]@{
                Mode = 'full'
                Target = 'vm-summary'
                Actions = @(Get-AzVmActionOrder)
            }
        }

        $actionMode = [string]$effectiveActionPlan.Mode
        $actionTarget = [string]$effectiveActionPlan.Target
        $isPartialActionMode = -not [string]::Equals($actionMode, 'full', [System.StringComparison]::OrdinalIgnoreCase)
        if ($isPartialActionMode) {
            Write-Host ("Selected execution mode: {0} (step target={1})" -f $actionMode, $actionTarget) -ForegroundColor Cyan
        }

        if (-not $script:AutoMode) {
            Read-Host -Prompt 'Press Enter to start...' | Out-Null
        }

        $envFilePath = Join-Path $repoRoot '.env'
        $configMap = Read-DotEnvFile -Path $envFilePath

        $platform = Resolve-AzVmPlatformSelection -ConfigMap $configMap -EnvFilePath $envFilePath -AutoMode:$script:AutoMode -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -ConfigOverrides $script:ConfigOverrides
        $platformDefaults = Get-AzVmPlatformDefaults -Platform $platform
        $effectiveConfigMap = Resolve-AzVmPlatformConfigMap -ConfigMap $configMap -Platform $platform
        if ($InitialConfigOverrides -and $InitialConfigOverrides.Count -gt 0) {
            foreach ($overrideKey in @($InitialConfigOverrides.Keys)) {
                $overrideName = [string]$overrideKey
                $overrideValue = [string]$InitialConfigOverrides[$overrideKey]
                if ([string]::IsNullOrWhiteSpace($overrideName)) {
                    continue
                }
                $effectiveConfigMap[$overrideName] = $overrideValue
                $script:ConfigOverrides[$overrideName] = $overrideValue
            }
        }

        $logTimestamp = (Get-Date).ToString('ddMMMyy-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture).ToLowerInvariant()
        $logPath = Join-Path $repoRoot ("az-vm-log-{0}.txt" -f $logTimestamp)

        Start-Transcript -Path $logPath -Force
        $script:TranscriptStarted = $true

        $runConfigureAction = Test-AzVmActionIncluded -ActionPlan $effectiveActionPlan -ActionName 'configure'
        $runGroupAction = Test-AzVmActionIncluded -ActionPlan $effectiveActionPlan -ActionName 'group'
        $runNetworkAction = Test-AzVmActionIncluded -ActionPlan $effectiveActionPlan -ActionName 'network'
        $runDeployAction = Test-AzVmActionIncluded -ActionPlan $effectiveActionPlan -ActionName 'vm-deploy'
        $runInitAction = Test-AzVmActionIncluded -ActionPlan $effectiveActionPlan -ActionName 'vm-init'
        $runUpdateAction = Test-AzVmActionIncluded -ActionPlan $effectiveActionPlan -ActionName 'vm-update'
        $runFinishAction = Test-AzVmActionIncluded -ActionPlan $effectiveActionPlan -ActionName 'vm-summary'

        if ($isPartialActionMode) {
            $bootstrapRuntime = Initialize-AzVmCommandRuntimeContext -AutoMode:$script:AutoMode -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -UseInteractiveStep1 -PersistGeneratedResourceGroup
            $step1Context = $bootstrapRuntime.Context
            $platform = [string]$bootstrapRuntime.Platform
            $platformDefaults = $bootstrapRuntime.PlatformDefaults
            $effectiveConfigMap = $bootstrapRuntime.EffectiveConfigMap

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
            $rdpPort = [string]$step1Context.RdpPort
            $tcpPorts = @($step1Context.TcpPorts)
            $vmInitTaskDir = [string]$step1Context.VmInitTaskDir
            $vmUpdateTaskDir = [string]$step1Context.VmUpdateTaskDir

            $taskOutcomeMode = [string]$bootstrapRuntime.TaskOutcomeMode
            $configuredPySshClientPath = [string]$bootstrapRuntime.ConfiguredPySshClientPath
            $sshTaskTimeoutSeconds = [int]$bootstrapRuntime.SshTaskTimeoutSeconds
            $sshConnectTimeoutSeconds = [int]$bootstrapRuntime.SshConnectTimeoutSeconds

            $sshMaxRetries = 1
            if ($platform -ne 'windows') {
                $sshMaxRetriesText = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'SSH_MAX_RETRIES' -DefaultValue '3')
                $sshMaxRetries = Resolve-AzVmSshRetryCount -RetryText $sshMaxRetriesText -DefaultValue 3
            }

            $vmExistsAtRunStart = Test-AzVmAzResourceExists -AzArgs @("vm", "show", "-g", $resourceGroup, "-n", $vmName)

            if ([string]::Equals($actionMode, 'single', [System.StringComparison]::OrdinalIgnoreCase)) {
                Assert-AzVmSingleActionDependencies -ActionName $actionTarget -Context $step1Context
            }

            if ($runConfigureAction -or $runDeployAction) {
                Invoke-Step 'Step 1/7 - initial configuration and availability checks will be completed...' {
                    Show-AzVmStepFirstUseValues -StepLabel 'Step 1/7 - configure and precheck' -Context $step1Context -ExtraValues @{
                        Platform = $platform
                        VmName = $vmName
                        ResourceGroup = $resourceGroup
                        AzLocation = $azLocation
                        VmSize = $vmSize
                    }
                    Invoke-AzVmPrecheckStep -Context $step1Context
                }
            }

            if ($runGroupAction) {
                Invoke-Step 'Step 2/7 - resource group will be checked...' {
                    Invoke-AzVmResourceGroupStep -Context $step1Context -AutoMode:$script:AutoMode -UpdateMode:$script:UpdateMode -ExecutionMode $script:ExecutionMode
                }
            }

            if ($runNetworkAction) {
                Invoke-Step 'Step 3/7 - VNet, subnet, NSG, NSG rules, public IP, and NIC will be created...' {
                    Invoke-AzVmNetworkStep -Context $step1Context -ExecutionMode $script:ExecutionMode
                }
            }

            if ($runDeployAction) {
                Invoke-Step 'Step 4/7 - virtual machine will be created...' {
                    $vmCreateSecurityArgs = @(Get-AzVmCreateSecurityArguments -Context $step1Context)
                    if ($platform -eq 'windows') {
                        Invoke-AzVmVmCreateStep -Context $step1Context -AutoMode:$script:AutoMode -UpdateMode:$script:UpdateMode -ExecutionMode $script:ExecutionMode -CreateVmAction {
                            az vm create --resource-group $resourceGroup --name $vmName --image $vmImage --size $vmSize --storage-sku $vmStorageSku --os-disk-name $vmDiskName --os-disk-size-gb $vmDiskSize --admin-username $vmUser --admin-password $vmPass --authentication-type password --nics $NIC @vmCreateSecurityArgs -o json --only-show-errors
                        } | Out-Null
                    }
                    else {
                        Invoke-AzVmVmCreateStep -Context $step1Context -AutoMode:$script:AutoMode -UpdateMode:$script:UpdateMode -ExecutionMode $script:ExecutionMode -CreateVmAction {
                            az vm create --resource-group $resourceGroup --name $vmName --image $vmImage --size $vmSize --storage-sku $vmStorageSku --os-disk-name $vmDiskName --os-disk-size-gb $vmDiskSize --admin-username $vmUser --admin-password $vmPass --authentication-type password --nics $NIC @vmCreateSecurityArgs -o json --only-show-errors
                        } | Out-Null
                    }
                }
            }

            if ($runInitAction) {
                Invoke-Step 'Step 5/7 - VM init tasks will be executed via Azure Run Command...' {
                    Show-AzVmStepFirstUseValues -StepLabel 'Step 5/7 - vm-init task catalog' -Context $step1Context -ExtraValues @{
                        Platform = $platform
                        VmInitTaskDir = $vmInitTaskDir
                        RunCommandId = [string]$platformDefaults.RunCommandId
                        VmExistsAtRunStart = $vmExistsAtRunStart
                    }

                    $initTaskCatalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath $vmInitTaskDir -Platform $platform -Stage 'init'
                    $initTaskTemplates = @($initTaskCatalog.ActiveTasks)
                    $initDisabledTasks = @($initTaskCatalog.DisabledTasks)
                    $initTaskBlocks = if (@($initTaskTemplates).Count -gt 0) {
                        @(Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks $initTaskTemplates -Context $step1Context)
                    }
                    else {
                        @()
                    }

                    Show-AzVmStepFirstUseValues -StepLabel 'Step 5/7 - vm-init task catalog' -Context $step1Context -ExtraValues @{
                        InitTaskCount = @($initTaskBlocks).Count
                        InitDisabledTaskCount = @($initDisabledTasks).Count
                    }
                    if (@($initDisabledTasks).Count -gt 0) {
                        $initDisabledNames = @($initDisabledTasks | ForEach-Object { [string]$_.Name })
                        Write-Host ("Disabled init tasks (ignored): {0}" -f ($initDisabledNames -join ', ')) -ForegroundColor Yellow
                    }

                    if (@($initTaskBlocks).Count -eq 0) {
                        Write-Host 'Init task catalog is empty; Step 5 vm-init stage is skipped.' -ForegroundColor Yellow
                    }
                    else {
                        $combinedShell = if ($platform -eq 'linux') { 'bash' } else { 'powershell' }
                        Invoke-VmRunCommandBlocks -ResourceGroup $resourceGroup -VmName $vmName -CommandId ([string]$platformDefaults.RunCommandId) -TaskBlocks $initTaskBlocks -CombinedShell $combinedShell -TaskOutcomeMode $taskOutcomeMode | Out-Null
                    }

                    if ($runUpdateAction -and @($initTaskBlocks).Count -gt 0) {
                        Write-Host 'Waiting 20 seconds for SSH service to settle after init...'
                        Start-Sleep -Seconds 20
                    }
                }
            }

            if ($runUpdateAction) {
                Invoke-Step 'Step 6/7 - VM update tasks will be executed via persistent SSH...' {
                    Show-AzVmStepFirstUseValues -StepLabel 'Step 6/7 - vm-update task catalog' -Context $step1Context -ExtraValues @{
                        Platform = $platform
                        VmUpdateTaskDir = $vmUpdateTaskDir
                        TaskOutcomeMode = $taskOutcomeMode
                        SshMaxRetries = $sshMaxRetries
                        SshTaskTimeoutSeconds = $sshTaskTimeoutSeconds
                        SshConnectTimeoutSeconds = $sshConnectTimeoutSeconds
                        PySshClientPath = $configuredPySshClientPath
                    }

                    $updateTaskCatalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath $vmUpdateTaskDir -Platform $platform -Stage 'update'
                    $updateTaskTemplates = @($updateTaskCatalog.ActiveTasks)
                    $updateDisabledTasks = @($updateTaskCatalog.DisabledTasks)
                    $updateTaskBlocks = if (@($updateTaskTemplates).Count -gt 0) {
                        @(Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks $updateTaskTemplates -Context $step1Context)
                    }
                    else {
                        @()
                    }

                    Show-AzVmStepFirstUseValues -StepLabel 'Step 6/7 - vm-update task catalog' -Context $step1Context -ExtraValues @{
                        UpdateTaskCount = @($updateTaskBlocks).Count
                        UpdateDisabledTaskCount = @($updateDisabledTasks).Count
                    }
                    if (@($updateDisabledTasks).Count -gt 0) {
                        $updateDisabledNames = @($updateDisabledTasks | ForEach-Object { [string]$_.Name })
                        Write-Host ("Disabled update tasks (ignored): {0}" -f ($updateDisabledNames -join ', ')) -ForegroundColor Yellow
                    }

                    $vmRuntimeDetails = Get-AzVmVmDetails -Context $step1Context
                    $sshHost = [string]$vmRuntimeDetails.VmFqdn
                    if ([string]::IsNullOrWhiteSpace($sshHost)) {
                        $sshHost = [string]$vmRuntimeDetails.PublicIP
                    }
                    if ([string]::IsNullOrWhiteSpace($sshHost)) {
                        throw 'Step 6 could not resolve VM SSH host (FQDN/Public IP).'
                    }

                    $step6SshUser = [string]$vmUser
                    $step6SshPassword = [string]$vmPass
                    Show-AzVmStepFirstUseValues -StepLabel 'Step 6/7 - vm-update execution' -Context $step1Context -ExtraValues @{
                        Step6SshHost = $sshHost
                        Step6SshUser = $step6SshUser
                        Step6SshPort = $sshPort
                    }

                    if (@($updateTaskBlocks).Count -eq 0) {
                        Write-Host 'Update task catalog is empty; Step 6 vm-update stage is skipped.' -ForegroundColor Yellow
                    }
                    else {
                        Invoke-AzVmSshTaskBlocks -Platform $platform -RepoRoot $repoRoot -SshHost $sshHost -SshUser $step6SshUser -SshPassword $step6SshPassword -SshPort $sshPort -ResourceGroup $resourceGroup -VmName $vmName -TaskBlocks $updateTaskBlocks -TaskOutcomeMode $taskOutcomeMode -SshMaxRetries $sshMaxRetries -SshTaskTimeoutSeconds $sshTaskTimeoutSeconds -SshConnectTimeoutSeconds $sshConnectTimeoutSeconds -ConfiguredPySshClientPath $configuredPySshClientPath | Out-Null
                    }
                }
            }

            if ($runFinishAction) {
                Invoke-Step 'Step 7/7 - VM connection details will be printed...' {
                    Show-AzVmStepFirstUseValues -StepLabel 'Step 7/7 - connection output' -Context $step1Context -ExtraValues @{ Platform = $platform; ManagerUser = $vmUser; AssistantUser = $vmAssistantUser }

                    if ([bool]$platformDefaults.IncludeRdp) {
                        $connectionModel = Get-AzVmConnectionDisplayModel -Context $step1Context -ManagerUser $vmUser -AssistantUser $vmAssistantUser -SshPort $sshPort -RdpPort $rdpPort -IncludeRdp
                    }
                    else {
                        $connectionModel = Get-AzVmConnectionDisplayModel -Context $step1Context -ManagerUser $vmUser -AssistantUser $vmAssistantUser -SshPort $sshPort
                    }

                    Write-Host 'VM Public IP Address:'
                    Write-Host ([string]$connectionModel.PublicIP)
                    Write-Host 'SSH Connection Commands:'
                    foreach ($sshConnection in @($connectionModel.SshConnections)) {
                        Write-Host ("- {0}: {1}" -f ([string]$sshConnection.User), ([string]$sshConnection.Command))
                    }

                    if ([bool]$platformDefaults.IncludeRdp) {
                        Write-Host 'RDP Connection Commands:'
                        foreach ($rdpConnection in @($connectionModel.RdpConnections)) {
                            Write-Host ("- {0}: {1}" -f ([string]$rdpConnection.User), ([string]$rdpConnection.Command))
                            Write-Host ("  username: {0}" -f ([string]$rdpConnection.Username))
                        }
                    }
                    else {
                        Write-Host 'RDP note: Linux flow does not configure an RDP service by default.' -ForegroundColor Yellow
                    }
                }
            }

            Write-Host ("Stopped after {0}-step target '{1}'." -f $actionMode, $actionTarget) -ForegroundColor Green
            Write-Host ("All console output was saved to '{0}'." -f [System.IO.Path]::GetFileName($logPath))
            return
        }

        Invoke-Step 'Step 1/7 - initial configuration and availability checks will be completed...' {
            $step1Context = Invoke-AzVmStep1Common `
                -ConfigMap $effectiveConfigMap `
                -EnvFilePath $envFilePath `
                -Platform $platform `
                -AutoMode:$script:AutoMode `
                -PersistGeneratedResourceGroup `
                -ScriptRoot $repoRoot `
                -VmNameDefault ([string]$platformDefaults.VmNameDefault) `
                -VmImageDefault ([string]$platformDefaults.VmImageDefault) `
                -VmSizeDefault ([string]$platformDefaults.VmSizeDefault) `
                -VmDiskSizeDefault ([string]$platformDefaults.VmDiskSizeDefault) `
                -ConfigOverrides $script:ConfigOverrides

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
            $rdpPort = [string]$step1Context.RdpPort
            $tcpPorts = @($step1Context.TcpPorts)
            $vmInitTaskDir = [string]$step1Context.VmInitTaskDir
            $vmUpdateTaskDir = [string]$step1Context.VmUpdateTaskDir
            $step1Context['VmOsType'] = $platform

            $taskOutcomeModeRaw = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'VM_TASK_OUTCOME_MODE' -DefaultValue 'continue')
            if ([string]::IsNullOrWhiteSpace($taskOutcomeModeRaw)) { $taskOutcomeModeRaw = 'continue' }
            $taskOutcomeMode = $taskOutcomeModeRaw.Trim().ToLowerInvariant()
            if ($taskOutcomeMode -ne 'continue' -and $taskOutcomeMode -ne 'strict') {
                Throw-FriendlyError `
                    -Detail ("Invalid VM_TASK_OUTCOME_MODE '{0}'." -f $taskOutcomeModeRaw) `
                    -Code 14 `
                    -Summary "Task outcome mode is invalid." `
                    -Hint "Set VM_TASK_OUTCOME_MODE=continue or VM_TASK_OUTCOME_MODE=strict."
            }

            $sshMaxRetriesText = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'SSH_MAX_RETRIES' -DefaultValue '3')
            $sshMaxRetries = 1
            if ($sshMaxRetriesText -match '^\d+$') {
                $sshMaxRetries = [int]$sshMaxRetriesText
                if ($sshMaxRetries -lt 1) { $sshMaxRetries = 1 }
                if ($sshMaxRetries -gt 3) { $sshMaxRetries = 3 }
            }
            if ($platform -eq 'windows') {
                $sshMaxRetries = 1
            }
            $configuredPySshClientPath = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'PYSSH_CLIENT_PATH' -DefaultValue (Get-AzVmDefaultPySshClientPathText))
            $sshTaskTimeoutText = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'SSH_TASK_TIMEOUT_SECONDS' -DefaultValue ([string]$script:SshTaskTimeoutSeconds))
            $sshTaskTimeoutSeconds = $script:SshTaskTimeoutSeconds
            if ($sshTaskTimeoutText -match '^\d+$') {
                $sshTaskTimeoutSeconds = [int]$sshTaskTimeoutText
            }
            if ($sshTaskTimeoutSeconds -lt 30) { $sshTaskTimeoutSeconds = 30 }
            if ($sshTaskTimeoutSeconds -gt 7200) { $sshTaskTimeoutSeconds = 7200 }

            $sshConnectTimeoutText = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'SSH_CONNECT_TIMEOUT_SECONDS' -DefaultValue ([string]$script:SshConnectTimeoutSeconds))
            $sshConnectTimeoutSeconds = $script:SshConnectTimeoutSeconds
            if ($sshConnectTimeoutText -match '^\d+$') {
                $sshConnectTimeoutSeconds = [int]$sshConnectTimeoutText
            }
            if ($sshConnectTimeoutSeconds -lt 5) { $sshConnectTimeoutSeconds = 5 }
            if ($sshConnectTimeoutSeconds -gt 300) { $sshConnectTimeoutSeconds = 300 }

            $azCommandTimeoutText = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'AZ_COMMAND_TIMEOUT_SECONDS' -DefaultValue ([string]$script:AzCommandTimeoutSeconds))
            $azCommandTimeoutSeconds = $script:AzCommandTimeoutSeconds
            if ($azCommandTimeoutText -match '^\d+$') {
                $azCommandTimeoutSeconds = [int]$azCommandTimeoutText
            }
            if ($azCommandTimeoutSeconds -lt 30) { $azCommandTimeoutSeconds = 30 }
            if ($azCommandTimeoutSeconds -gt 7200) { $azCommandTimeoutSeconds = 7200 }

            $script:AzCommandTimeoutSeconds = $azCommandTimeoutSeconds
            $script:SshTaskTimeoutSeconds = $sshTaskTimeoutSeconds
            $script:SshConnectTimeoutSeconds = $sshConnectTimeoutSeconds
            $step1Context['AzCommandTimeoutSeconds'] = $azCommandTimeoutSeconds
            $step1Context['SshTaskTimeoutSeconds'] = $sshTaskTimeoutSeconds
            $step1Context['SshConnectTimeoutSeconds'] = $sshConnectTimeoutSeconds

            if ($script:AutoMode) {
                Show-AzVmRuntimeConfigurationSnapshot -Platform $platform -ScriptName 'az-vm.ps1' -ScriptRoot $repoRoot -AutoMode:$script:AutoMode -UpdateMode:$script:UpdateMode -RenewMode:$script:RenewMode -ConfigMap $effectiveConfigMap -ConfigOverrides $script:ConfigOverrides -Context $step1Context
            }

            Invoke-AzVmPrecheckStep -Context $step1Context
        }

        Invoke-Step 'Step 2/7 - resource group will be checked...' {
            Invoke-AzVmResourceGroupStep -Context $step1Context -AutoMode:$script:AutoMode -UpdateMode:$script:UpdateMode -ExecutionMode $script:ExecutionMode
        }

        Invoke-Step 'Step 3/7 - VNet, subnet, NSG, NSG rules, public IP, and NIC will be created...' {
            Invoke-AzVmNetworkStep -Context $step1Context -ExecutionMode $script:ExecutionMode
        }

        $vmExistsAtRunStart = Test-AzVmAzResourceExists -AzArgs @("vm", "show", "-g", $resourceGroup, "-n", $vmName)

        Invoke-Step 'Step 4/7 - virtual machine will be created...' {
            $vmCreateSecurityArgs = @(Get-AzVmCreateSecurityArguments -Context $step1Context)
            if ($platform -eq 'windows') {
                Invoke-AzVmVmCreateStep -Context $step1Context -AutoMode:$script:AutoMode -UpdateMode:$script:UpdateMode -ExecutionMode $script:ExecutionMode -CreateVmAction {
                    az vm create --resource-group $resourceGroup --name $vmName --image $vmImage --size $vmSize --storage-sku $vmStorageSku --os-disk-name $vmDiskName --os-disk-size-gb $vmDiskSize --admin-username $vmUser --admin-password $vmPass --authentication-type password --nics $NIC @vmCreateSecurityArgs -o json --only-show-errors
                } | Out-Null
            }
            else {
                Invoke-AzVmVmCreateStep -Context $step1Context -AutoMode:$script:AutoMode -UpdateMode:$script:UpdateMode -ExecutionMode $script:ExecutionMode -CreateVmAction {
                    az vm create --resource-group $resourceGroup --name $vmName --image $vmImage --size $vmSize --storage-sku $vmStorageSku --os-disk-name $vmDiskName --os-disk-size-gb $vmDiskSize --admin-username $vmUser --admin-password $vmPass --authentication-type password --nics $NIC @vmCreateSecurityArgs -o json --only-show-errors
                } | Out-Null
            }
        }

        Invoke-Step 'Step 5/7 - VM init tasks will be executed via Azure Run Command...' {
            Show-AzVmStepFirstUseValues -StepLabel 'Step 5/7 - vm-init task catalog' -Context $step1Context -ExtraValues @{
                Platform = $platform
                VmInitTaskDir = $vmInitTaskDir
                RunCommandId = [string]$platformDefaults.RunCommandId
                VmExistsAtRunStart = $vmExistsAtRunStart
            }
            $initTaskCatalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath $vmInitTaskDir -Platform $platform -Stage 'init'
            $initTaskTemplates = @($initTaskCatalog.ActiveTasks)
            $initDisabledTasks = @($initTaskCatalog.DisabledTasks)
            $initTaskBlocks = if (@($initTaskTemplates).Count -gt 0) {
                @(Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks $initTaskTemplates -Context $step1Context)
            }
            else {
                @()
            }
            Show-AzVmStepFirstUseValues -StepLabel 'Step 5/7 - vm-init task catalog' -Context $step1Context -ExtraValues @{
                InitTaskCount = @($initTaskBlocks).Count
                InitDisabledTaskCount = @($initDisabledTasks).Count
            }
            if (@($initDisabledTasks).Count -gt 0) {
                $initDisabledNames = @($initDisabledTasks | ForEach-Object { [string]$_.Name })
                Write-Host ("Disabled init tasks (ignored): {0}" -f ($initDisabledNames -join ', ')) -ForegroundColor Yellow
            }

            if (@($initTaskBlocks).Count -gt 0) {
                $combinedShell = if ($platform -eq 'linux') { 'bash' } else { 'powershell' }
                Invoke-VmRunCommandBlocks -ResourceGroup $resourceGroup -VmName $vmName -CommandId ([string]$platformDefaults.RunCommandId) -TaskBlocks $initTaskBlocks -CombinedShell $combinedShell -TaskOutcomeMode $taskOutcomeMode | Out-Null
            }
            else {
                Write-Host 'Init task catalog is empty; Step 5 vm-init stage is skipped.' -ForegroundColor Yellow
            }

            if (@($initTaskBlocks).Count -gt 0) {
                Write-Host 'Waiting 20 seconds for SSH service to settle after init...'
                Start-Sleep -Seconds 20
            }
        }

        Invoke-Step 'Step 6/7 - VM update tasks will be executed via persistent SSH...' {
            Show-AzVmStepFirstUseValues -StepLabel 'Step 6/7 - vm-update task catalog' -Context $step1Context -ExtraValues @{
                Platform = $platform
                VmUpdateTaskDir = $vmUpdateTaskDir
                TaskOutcomeMode = $taskOutcomeMode
                SshMaxRetries = $sshMaxRetries
                SshTaskTimeoutSeconds = $sshTaskTimeoutSeconds
                SshConnectTimeoutSeconds = $sshConnectTimeoutSeconds
                PySshClientPath = $configuredPySshClientPath
            }
            $updateTaskCatalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath $vmUpdateTaskDir -Platform $platform -Stage 'update'
            $updateTaskTemplates = @($updateTaskCatalog.ActiveTasks)
            $updateDisabledTasks = @($updateTaskCatalog.DisabledTasks)
            $updateTaskBlocks = if (@($updateTaskTemplates).Count -gt 0) {
                @(Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks $updateTaskTemplates -Context $step1Context)
            }
            else {
                @()
            }
            Show-AzVmStepFirstUseValues -StepLabel 'Step 6/7 - vm-update task catalog' -Context $step1Context -ExtraValues @{
                UpdateTaskCount = @($updateTaskBlocks).Count
                UpdateDisabledTaskCount = @($updateDisabledTasks).Count
            }
            if (@($updateDisabledTasks).Count -gt 0) {
                $updateDisabledNames = @($updateDisabledTasks | ForEach-Object { [string]$_.Name })
                Write-Host ("Disabled update tasks (ignored): {0}" -f ($updateDisabledNames -join ', ')) -ForegroundColor Yellow
            }

            $vmRuntimeDetails = Get-AzVmVmDetails -Context $step1Context
            $sshHost = [string]$vmRuntimeDetails.VmFqdn
            if ([string]::IsNullOrWhiteSpace($sshHost)) {
                $sshHost = [string]$vmRuntimeDetails.PublicIP
            }
            if ([string]::IsNullOrWhiteSpace($sshHost)) {
                throw 'Step 6 could not resolve VM SSH host (FQDN/Public IP).'
            }

            $step6SshUser = [string]$vmUser
            $step6SshPassword = [string]$vmPass
            Show-AzVmStepFirstUseValues -StepLabel 'Step 6/7 - vm-update execution' -Context $step1Context -ExtraValues @{ Step6SshHost = $sshHost; Step6SshUser = $step6SshUser; Step6SshPort = $sshPort }

            if (@($updateTaskBlocks).Count -eq 0) {
                Write-Host 'Update task catalog is empty; Step 6 vm-update stage is skipped.' -ForegroundColor Yellow
            }
            else {
                Invoke-AzVmSshTaskBlocks -Platform $platform -RepoRoot $repoRoot -SshHost $sshHost -SshUser $step6SshUser -SshPassword $step6SshPassword -SshPort $sshPort -ResourceGroup $resourceGroup -VmName $vmName -TaskBlocks $updateTaskBlocks -TaskOutcomeMode $taskOutcomeMode -SshMaxRetries $sshMaxRetries -SshTaskTimeoutSeconds $sshTaskTimeoutSeconds -SshConnectTimeoutSeconds $sshConnectTimeoutSeconds -ConfiguredPySshClientPath $configuredPySshClientPath | Out-Null
            }
        }

        Invoke-Step 'Step 7/7 - VM connection details will be printed...' {
            Show-AzVmStepFirstUseValues -StepLabel 'Step 7/7 - connection output' -Context $step1Context -ExtraValues @{ Platform = $platform; ManagerUser = $vmUser; AssistantUser = $vmAssistantUser }

            if ([bool]$platformDefaults.IncludeRdp) {
                $connectionModel = Get-AzVmConnectionDisplayModel -Context $step1Context -ManagerUser $vmUser -AssistantUser $vmAssistantUser -SshPort $sshPort -RdpPort $rdpPort -IncludeRdp
            }
            else {
                $connectionModel = Get-AzVmConnectionDisplayModel -Context $step1Context -ManagerUser $vmUser -AssistantUser $vmAssistantUser -SshPort $sshPort
            }

            Write-Host 'VM Public IP Address:'
            Write-Host ([string]$connectionModel.PublicIP)
            Write-Host 'SSH Connection Commands:'
            foreach ($sshConnection in @($connectionModel.SshConnections)) {
                Write-Host ("- {0}: {1}" -f ([string]$sshConnection.User), ([string]$sshConnection.Command))
            }

            if ([bool]$platformDefaults.IncludeRdp) {
                Write-Host 'RDP Connection Commands:'
                foreach ($rdpConnection in @($connectionModel.RdpConnections)) {
                    Write-Host ("- {0}: {1}" -f ([string]$rdpConnection.User), ([string]$rdpConnection.Command))
                    Write-Host ("  username: {0}" -f ([string]$rdpConnection.Username))
                }
            }
            else {
                Write-Host 'RDP note: Linux flow does not configure an RDP service by default.' -ForegroundColor Yellow
            }
        }

        Write-Host ("All console output was saved to '{0}'." -f [System.IO.Path]::GetFileName($logPath))
    }
    catch {
        $resolvedError = Resolve-AzVmFriendlyError -ErrorRecord $_ -DefaultErrorSummary $script:DefaultErrorSummary -DefaultErrorHint $script:DefaultErrorHint

        Write-Host ''
        Write-Host 'Script exited gracefully.' -ForegroundColor Yellow
        Write-Host ("Reason: {0}" -f $resolvedError.Summary) -ForegroundColor Red
        Write-Host ("Detail: {0}" -f $resolvedError.ErrorMessage)
        Write-Host ("Suggested action: {0}" -f $resolvedError.Hint) -ForegroundColor Cyan
        $script:HadError = $true
        $script:ExitCode = [int]$resolvedError.Code
    }
    finally {
        if ($script:TranscriptStarted) {
            Stop-Transcript | Out-Null
            $script:TranscriptStarted = $false
        }
        if (-not $script:AutoMode) {
            Read-Host -Prompt 'Press Enter to exit.' | Out-Null
        }
    }

    if ($script:HadError) {
        exit $script:ExitCode
    }
}

