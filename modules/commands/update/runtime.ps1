# Update command runtime helpers.

function Assert-AzVmUpdateAutoOptions {
    param(
        [hashtable]$Options,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag,
        [hashtable]$ConfigMap
    )

    if (-not (Get-AzVmCliOptionBool -Options $Options -Name 'auto' -DefaultValue $false)) {
        return
    }

    $validationConfig = if ($ConfigMap) { Resolve-AzVmSupportedDotEnvConfig -ConfigMap $ConfigMap } else { @{} }
    $effectiveGroup = [string](Get-AzVmCliOptionText -Options $Options -Name 'group')
    if ([string]::IsNullOrWhiteSpace([string]$effectiveGroup)) {
        $effectiveGroup = [string](Get-ConfigValue -Config $validationConfig -Key 'SELECTED_RESOURCE_GROUP' -DefaultValue '')
    }

    if ([string]::IsNullOrWhiteSpace([string]$effectiveGroup)) {
        Throw-FriendlyError `
            -Detail "Update auto mode could not resolve a managed resource group from CLI or .env SELECTED_RESOURCE_GROUP." `
            -Code 2 `
            -Summary "Update auto mode cannot resolve target resource group." `
            -Hint "Set SELECTED_RESOURCE_GROUP in .env, or pass --group."
    }
}

function Get-AzVmManagedTargetOsType {
    param(
        [string]$ResourceGroup,
        [string]$VmName
    )

    $osType = az vm show -g $ResourceGroup -n $VmName --query "storageProfile.osDisk.osType" -o tsv --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ''
    }

    $normalized = ([string]$osType).Trim().ToLowerInvariant()
    if ($normalized -eq 'windows' -or $normalized -eq 'linux') {
        return $normalized
    }

    return ''
}

function New-AzVmUpdateCommandRuntime {
    param(
        [hashtable]$Options,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag,
        [switch]$AutoMode
    )

    $actionPlan = Resolve-AzVmActionPlan -CommandName 'update' -Options $Options
    $envFilePath = Join-Path (Get-AzVmRepoRoot) '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    Assert-AzVmUpdateAutoOptions -Options $Options -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -ConfigMap $configMap
    $cliSubscriptionId = [string](Get-AzVmCliOptionText -Options $Options -Name 'subscription-id')

    if (-not $AutoMode -and [string]::IsNullOrWhiteSpace([string]$cliSubscriptionId)) {
        $currentSubscription = Get-AzVmResolvedSubscriptionContext
        $selectedSubscription = Select-AzVmSubscriptionInteractive -DefaultSubscriptionId ([string]$currentSubscription.SubscriptionId)
        Set-AzVmResolvedSubscriptionContext `
            -SubscriptionId ([string]$selectedSubscription.id) `
            -SubscriptionName ([string]$selectedSubscription.name) `
            -TenantId ([string]$selectedSubscription.tenantId) `
            -ResolutionSource 'interactive'
        Set-AzVmConfigValueSource -Key 'SELECTED_AZURE_SUBSCRIPTION_ID' -Source 'interactive value'
    }

    $defaultResourceGroup = [string](Get-ConfigValue -Config $configMap -Key 'SELECTED_RESOURCE_GROUP' -DefaultValue '')
    $vmNameOverride = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-name')
    $vmName = if (-not [string]::IsNullOrWhiteSpace([string]$vmNameOverride)) { $vmNameOverride.Trim() } else { [string](Get-ConfigValue -Config $configMap -Key 'SELECTED_VM_NAME' -DefaultValue '') }
    $targetResourceGroup = Resolve-AzVmTargetResourceGroup -Options $Options -AutoMode:$AutoMode -DefaultResourceGroup $defaultResourceGroup -VmName $vmName -OperationName 'update'
    $resolvedVmName = [string](Resolve-AzVmTargetVmName -ResourceGroup $targetResourceGroup -DefaultVmName $vmName -AutoMode:$AutoMode -OperationName 'update')
    if (-not (Test-AzVmAzResourceExists -AzArgs @('vm', 'show', '-g', $targetResourceGroup, '-n', $resolvedVmName))) {
        Throw-FriendlyError `
            -Detail ("VM '{0}' was not found in managed resource group '{1}'." -f $resolvedVmName, $targetResourceGroup) `
            -Code 66 `
            -Summary "Update command cannot continue because the target VM does not exist." `
            -Hint "Run create to provision a fresh managed VM, or choose an existing managed VM target."
    }

    $targetLocation = Get-AzVmResourceGroupLocation -ResourceGroup $targetResourceGroup
    $targetOsType = Get-AzVmManagedTargetOsType -ResourceGroup $targetResourceGroup -VmName $resolvedVmName
    $networkDescriptor = Get-AzVmVmNetworkDescriptor -ResourceGroup $targetResourceGroup -VmName $resolvedVmName

    $updateOverrides = @{
        SELECTED_AZURE_SUBSCRIPTION_ID = [string]$((Get-AzVmResolvedSubscriptionContext).SubscriptionId)
        SELECTED_RESOURCE_GROUP = $targetResourceGroup
        SELECTED_VM_NAME = $resolvedVmName
        SELECTED_AZURE_REGION = $targetLocation
        VNET_NAME = [string]$networkDescriptor.VnetName
        SUBNET_NAME = [string]$networkDescriptor.SubnetName
        NSG_NAME = [string]$networkDescriptor.NsgName
        PUBLIC_IP_NAME = [string]$networkDescriptor.PublicIpName
        NIC_NAME = [string]$networkDescriptor.NicName
        VM_DISK_NAME = [string]$networkDescriptor.OsDiskName
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$targetOsType)) {
        $updateOverrides['SELECTED_VM_OS'] = $targetOsType
    }

    foreach ($overrideKey in @($updateOverrides.Keys)) {
        Set-AzVmConfigValueSource -Key ([string]$overrideKey) -Source 'azure value'
    }

    return [pscustomobject]@{
        ActionPlan = $actionPlan
        InitialConfigOverrides = $updateOverrides
        WindowsFlag = [bool]$WindowsFlag
        LinuxFlag = [bool]$LinuxFlag
    }
}
