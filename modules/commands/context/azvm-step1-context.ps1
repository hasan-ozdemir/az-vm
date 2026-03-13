# Shared Step-1 context builders and security-value helpers.

function Get-AzVmStep1ContextPersistenceMap {
    param(
        [string]$Platform,
        [hashtable]$Context
    )

    $tcpPortsCsv = [string]$Context.TcpPortsConfiguredCsv
    if ([string]::IsNullOrWhiteSpace([string]$tcpPortsCsv)) {
        $tcpPortsCsv = (@($Context.TcpPorts) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ','
    }

    $vmImageConfigKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey "VM_IMAGE"
    $vmSizeConfigKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey "VM_SIZE"
    $vmDiskSizeConfigKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey "VM_DISK_SIZE_GB"

    $persist = [ordered]@{
        VM_OS_TYPE = [string]$Platform
        AZ_LOCATION = [string]$Context.AzLocation
        RESOURCE_GROUP = [string]$Context.ResourceGroup
        VNET_NAME = [string]$Context.VNET
        SUBNET_NAME = [string]$Context.SUBNET
        NSG_NAME = [string]$Context.NSG
        NSG_RULE_NAME = [string]$Context.NsgRule
        PUBLIC_IP_NAME = [string]$Context.IP
        NIC_NAME = [string]$Context.NIC
        VM_NAME = [string]$Context.VmName
        VM_DISK_NAME = [string]$Context.VmDiskName
        VM_STORAGE_SKU = [string]$Context.VmStorageSku
        VM_SSH_PORT = [string]$Context.SshPort
        VM_RDP_PORT = [string]$Context.RdpPort
        TCP_PORTS = [string]$tcpPortsCsv
    }

    $persist[$vmImageConfigKey] = [string]$Context.VmImage
    $persist[$vmSizeConfigKey] = [string]$Context.VmSize
    $persist[$vmDiskSizeConfigKey] = [string]$Context.VmDiskSize
    return $persist
}

function Save-AzVmStep1ContextPersistenceMap {
    param(
        [string]$EnvFilePath,
        [System.Collections.IDictionary]$PersistMap
    )

    foreach ($key in @($PersistMap.Keys)) {
        $name = [string]$key
        if ([string]::IsNullOrWhiteSpace([string]$name)) {
            continue
        }

        Set-DotEnvValue -Path $EnvFilePath -Key $name -Value ([string]$PersistMap[$name])
    }
}

function New-AzVmStep1ConfigDisplayMap {
    param(
        [string]$Platform,
        [hashtable]$Context,
        [string]$OperationName
    )

    $values = [ordered]@{
        Operation = [string]$OperationName
        Platform = [string]$Platform
        ResourceGroup = [string]$Context.ResourceGroup
        AzLocation = [string]$Context.AzLocation
        VmName = [string]$Context.VmName
        VmImage = [string]$Context.VmImage
        VmStorageSku = [string]$Context.VmStorageSku
        VmSize = [string]$Context.VmSize
        VmDiskName = [string]$Context.VmDiskName
        VmDiskSize = [string]$Context.VmDiskSize
        VNET = [string]$Context.VNET
        SUBNET = [string]$Context.SUBNET
        NSG = [string]$Context.NSG
        NsgRule = [string]$Context.NsgRule
        IP = [string]$Context.IP
        NIC = [string]$Context.NIC
        VmUser = [string]$Context.VmUser
        VmAssistantUser = [string]$Context.VmAssistantUser
        SshPort = [string]$Context.SshPort
        RdpPort = [string]$Context.RdpPort
        TcpPorts = @($Context.TcpPorts)
        VmInitTaskDir = [string]$Context.VmInitTaskDir
        VmUpdateTaskDir = [string]$Context.VmUpdateTaskDir
    }

    return $values
}

function Read-AzVmStep1OverrideValue {
    param(
        [string]$Label,
        [string]$CurrentValue,
        [switch]$AllowEmpty
    )

    $raw = Read-Host ("{0} (current={1})" -f $Label, $CurrentValue)
    if ([string]::IsNullOrWhiteSpace([string]$raw)) {
        return [string]$CurrentValue
    }

    $candidate = [string]$raw.Trim()
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace([string]$candidate)) {
        return [string]$CurrentValue
    }

    return $candidate
}

function Invoke-AzVmInteractiveStep1Editor {
    param(
        [hashtable]$ConfigMap,
        [string]$EnvFilePath,
        [ValidateSet('windows','linux')]
        [string]$Platform,
        [string]$ScriptRoot,
        [string]$VmNameDefault,
        [string]$VmImageDefault,
        [string]$VmSizeDefault,
        [string]$VmDiskSizeDefault,
        [hashtable]$ConfigOverrides,
        [ValidateSet('create','update','configure','generic')]
        [string]$OperationName,
        [hashtable]$Context,
        [switch]$PersistGeneratedResourceGroup,
        [switch]$DeferEnvWrites
    )

    Write-Host ""
    Show-AzVmKeyValueList -Title "VM configuration review (leave blank to keep current value):" -Values (New-AzVmStep1ConfigDisplayMap -Platform $Platform -Context $Context -OperationName $OperationName)

    if ([string]::Equals([string]$OperationName, 'update', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "Locked target values: ResourceGroup, AzLocation, VmName, VNET, SUBNET, NSG, IP, NIC, and VmDiskName are taken from the existing managed VM target." -ForegroundColor Yellow
    }

    $vmImageConfigKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey "VM_IMAGE"
    $vmSizeConfigKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey "VM_SIZE"
    $vmDiskSizeConfigKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey "VM_DISK_SIZE_GB"

    if ([string]::Equals([string]$OperationName, 'create', [System.StringComparison]::OrdinalIgnoreCase)) {
        while ($true) {
            $candidateVmName = Read-AzVmStep1OverrideValue -Label 'VM_NAME' -CurrentValue ([string]$Context.VmName)
            if (Test-AzVmVmNameFormat -VmName $candidateVmName) {
                $ConfigOverrides['VM_NAME'] = [string]$candidateVmName
                break
            }

            Write-Host "Invalid VM name. Use 3-16 characters, start with a letter, then continue with letters, numbers, or hyphen." -ForegroundColor Yellow
        }

        while ($true) {
            $candidateLocation = Read-AzVmStep1OverrideValue -Label 'AZ_LOCATION' -CurrentValue ([string]$Context.AzLocation)
            try {
                Assert-LocationExists -Location $candidateLocation
                $ConfigOverrides['AZ_LOCATION'] = ([string]$candidateLocation).Trim().ToLowerInvariant()
                break
            }
            catch {
                Write-Host "Invalid Azure region. Enter a valid Azure location value." -ForegroundColor Yellow
            }
        }
    }

    $ConfigOverrides['VM_SIZE'] = Read-AzVmStep1OverrideValue -Label 'VM_SIZE' -CurrentValue ([string]$Context.VmSize)
    $ConfigOverrides[$vmImageConfigKey] = Read-AzVmStep1OverrideValue -Label $vmImageConfigKey -CurrentValue ([string]$Context.VmImage)
    $ConfigOverrides[$vmDiskSizeConfigKey] = Read-AzVmStep1OverrideValue -Label $vmDiskSizeConfigKey -CurrentValue ([string]$Context.VmDiskSize)
    $ConfigOverrides['VM_STORAGE_SKU'] = Read-AzVmStep1OverrideValue -Label 'VM_STORAGE_SKU' -CurrentValue ([string]$Context.VmStorageSku)

    $resolvedContext = Invoke-AzVmStep1Common `
        -ConfigMap $ConfigMap `
        -EnvFilePath $EnvFilePath `
        -Platform $Platform `
        -AutoMode `
        -PersistGeneratedResourceGroup:$PersistGeneratedResourceGroup `
        -ScriptRoot $ScriptRoot `
        -VmNameDefault $VmNameDefault `
        -VmImageDefault $VmImageDefault `
        -VmSizeDefault $VmSizeDefault `
        -VmDiskSizeDefault $VmDiskSizeDefault `
        -ConfigOverrides $ConfigOverrides `
        -OperationName $OperationName `
        -DeferEnvWrites:$DeferEnvWrites `
        -SkipInteractiveConfigEditor

    if ([string]::Equals([string]$OperationName, 'create', [System.StringComparison]::OrdinalIgnoreCase)) {
        foreach ($fieldName in @('RESOURCE_GROUP','VNET_NAME','SUBNET_NAME','NSG_NAME','NSG_RULE_NAME','PUBLIC_IP_NAME','NIC_NAME','VM_DISK_NAME')) {
            $currentValue = switch ($fieldName) {
                'RESOURCE_GROUP' { [string]$resolvedContext.ResourceGroup }
                'VNET_NAME' { [string]$resolvedContext.VNET }
                'SUBNET_NAME' { [string]$resolvedContext.SUBNET }
                'NSG_NAME' { [string]$resolvedContext.NSG }
                'NSG_RULE_NAME' { [string]$resolvedContext.NsgRule }
                'PUBLIC_IP_NAME' { [string]$resolvedContext.IP }
                'NIC_NAME' { [string]$resolvedContext.NIC }
                'VM_DISK_NAME' { [string]$resolvedContext.VmDiskName }
            }

            $candidateValue = Read-AzVmStep1OverrideValue -Label $fieldName -CurrentValue $currentValue
            $ConfigOverrides[$fieldName] = [string]$candidateValue
        }

        $resolvedContext = Invoke-AzVmStep1Common `
            -ConfigMap $ConfigMap `
            -EnvFilePath $EnvFilePath `
            -Platform $Platform `
            -AutoMode `
            -PersistGeneratedResourceGroup:$PersistGeneratedResourceGroup `
            -ScriptRoot $ScriptRoot `
            -VmNameDefault $VmNameDefault `
            -VmImageDefault $VmImageDefault `
            -VmSizeDefault $VmSizeDefault `
            -VmDiskSizeDefault $VmDiskSizeDefault `
            -ConfigOverrides $ConfigOverrides `
            -OperationName $OperationName `
            -DeferEnvWrites:$DeferEnvWrites `
            -SkipInteractiveConfigEditor
    }

    return $resolvedContext
}

function Get-AzVmManagedNameSeed {
    param(
        [hashtable]$ConfigMap,
        [hashtable]$ConfigOverrides,
        [string]$OperationName,
        [string]$NameKey,
        [string]$TemplateKey,
        [string]$TemplateDefaultValue
    )

    $explicitOverride = ''
    if ($ConfigOverrides -and $ConfigOverrides.ContainsKey($NameKey) -and -not [string]::IsNullOrWhiteSpace([string]$ConfigOverrides[$NameKey])) {
        $explicitOverride = [string]$ConfigOverrides[$NameKey]
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$explicitOverride)) {
        return [pscustomobject]@{
            Value = [string]$explicitOverride
            Explicit = $true
        }
    }

    if (-not [string]::Equals([string]$OperationName, 'create', [System.StringComparison]::OrdinalIgnoreCase)) {
        $configuredName = [string](Get-ConfigValue -Config $ConfigMap -Key $NameKey -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace([string]$configuredName)) {
            return [pscustomobject]@{
                Value = [string]$configuredName
                Explicit = $true
            }
        }
    }

    return [pscustomobject]@{
        Value = [string](Get-ConfigValue -Config $ConfigMap -Key $TemplateKey -DefaultValue $TemplateDefaultValue)
        Explicit = $false
    }
}

# Handles Invoke-AzVmStep1Common.
function Invoke-AzVmStep1Common {
    param(
        [hashtable]$ConfigMap,
        [string]$EnvFilePath,
        [ValidateSet('windows','linux')]
        [string]$Platform,
        [switch]$AutoMode,
        [switch]$PersistGeneratedResourceGroup,
        [string]$ScriptRoot,
        [string]$VmNameDefault,
        [string]$VmImageDefault,
        [string]$VmSizeDefault,
        [string]$VmDiskSizeDefault,
        [hashtable]$ConfigOverrides,
        [ValidateSet('create','update','configure','generic')]
        [string]$OperationName = 'generic',
        [switch]$DeferEnvWrites,
        [switch]$SkipInteractiveConfigEditor
    )

    $pendingEnvUpdates = [ordered]@{}

    $vmNameDefaultResolved = ''
    if ($ConfigOverrides -and $ConfigOverrides.ContainsKey('VM_NAME') -and -not [string]::IsNullOrWhiteSpace([string]$ConfigOverrides['VM_NAME'])) {
        $vmNameDefaultResolved = [string]$ConfigOverrides['VM_NAME']
    }
    else {
        $vmNameDefaultResolved = [string](Get-ConfigValue -Config $ConfigMap -Key "VM_NAME" -DefaultValue $VmNameDefault)
    }

    $vmName = $vmNameDefaultResolved
    do {
        if ($AutoMode) {
            if ([string]::IsNullOrWhiteSpace([string]$vmNameDefaultResolved)) {
                Throw-FriendlyError `
                    -Detail "VM_NAME is required for this non-interactive command flow." `
                    -Code 2 `
                    -Summary "VM name is required." `
                    -Hint "Set VM_NAME in .env, or pass --vm-name where the command supports it."
            }
            $userInput = $vmNameDefaultResolved
        }
        else {
            if ([string]::Equals([string]$OperationName, 'update', [System.StringComparison]::OrdinalIgnoreCase)) {
                $userInput = $vmNameDefaultResolved
                Write-Host ("Update target VM '{0}' is fixed by the selected managed VM target." -f [string]$userInput) -ForegroundColor Cyan
            }
            elseif ([string]::IsNullOrWhiteSpace([string]$vmNameDefaultResolved)) {
                $userInput = Read-Host "Enter VM name (actual Azure VM name)"
            }
            else {
                $userInput = Read-Host "Enter VM name (actual Azure VM name; default=$vmNameDefaultResolved)"
            }
        }

        if ([string]::IsNullOrWhiteSpace($userInput)) {
            $userInput = $vmNameDefaultResolved
        }

        if (Test-AzVmVmNameFormat -VmName $userInput) {
            $isValid = $true
        }
        else {
            if ($AutoMode) {
                Throw-FriendlyError `
                    -Detail ("VM name '{0}' is invalid." -f [string]$userInput) `
                    -Code 2 `
                    -Summary "VM name format is invalid." `
                    -Hint "Use 3-16 characters, start with a letter, then continue with letters, numbers, or hyphen."
            }

            Write-Host "Invalid VM name. Use 3-16 characters, start with a letter, then continue with letters, numbers, or hyphen." -ForegroundColor Red
            $isValid = $false
        }
    } until ($isValid)

    $vmName = $userInput
    if ($ConfigOverrides) {
        $ConfigOverrides["VM_NAME"] = $vmName
    }

    Write-Host "VM name '$vmName' will be used for the Azure VM and default resource naming." -ForegroundColor Green

    $vmImageConfigKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey "VM_IMAGE"
    $vmSizeConfigKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey "VM_SIZE"
    $vmDiskSizeConfigKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey "VM_DISK_SIZE_GB"
    $vmInitTaskDirConfigKey = Get-AzVmPlatformTaskCatalogConfigKey -Platform $Platform -Stage 'init'
    $vmUpdateTaskDirConfigKey = Get-AzVmPlatformTaskCatalogConfigKey -Platform $Platform -Stage 'update'
    $baseTokens = @{ VM_NAME = [string]$vmName }

    $defaultAzLocation = Resolve-AzVmTemplate -Template (Get-ConfigValue -Config $ConfigMap -Key "AZ_LOCATION" -DefaultValue "") -Tokens $baseTokens
    $vmImage = Resolve-AzVmTemplate -Template (Get-ConfigValue -Config $ConfigMap -Key $vmImageConfigKey -DefaultValue $VmImageDefault) -Tokens $baseTokens
    $vmStorageSku = Resolve-AzVmTemplate -Template (Get-ConfigValue -Config $ConfigMap -Key "VM_STORAGE_SKU" -DefaultValue "StandardSSD_LRS") -Tokens $baseTokens
    $defaultVmSize = Resolve-AzVmTemplate -Template (Get-ConfigValue -Config $ConfigMap -Key $vmSizeConfigKey -DefaultValue $VmSizeDefault) -Tokens $baseTokens
    $vmSecurityType = Resolve-AzVmSecurityTypeValue -RawValue ([string](Get-ConfigValue -Config $ConfigMap -Key "VM_SECURITY_TYPE" -DefaultValue ""))
    $vmEnableSecureBoot = $false
    $vmEnableVtpm = $false
    $vmEnableHibernation = Resolve-AzVmBooleanConfigValue -RawValue ([string](Get-ConfigValue -Config $ConfigMap -Key "VM_ENABLE_HIBERNATION" -DefaultValue "true")) -KeyName 'VM_ENABLE_HIBERNATION' -DefaultValue $true -TreatEmptyAsDefault
    $vmEnableNestedVirtualization = Resolve-AzVmBooleanConfigValue -RawValue ([string](Get-ConfigValue -Config $ConfigMap -Key "VM_ENABLE_NESTED_VIRTUALIZATION" -DefaultValue "true")) -KeyName 'VM_ENABLE_NESTED_VIRTUALIZATION' -DefaultValue $true -TreatEmptyAsDefault
    if ([string]::Equals([string]$vmSecurityType, 'TrustedLaunch', [System.StringComparison]::OrdinalIgnoreCase)) {
        $vmEnableSecureBoot = Resolve-AzVmBooleanConfigValue -RawValue ([string](Get-ConfigValue -Config $ConfigMap -Key "VM_ENABLE_SECURE_BOOT" -DefaultValue "true")) -KeyName 'VM_ENABLE_SECURE_BOOT' -DefaultValue $true -TreatEmptyAsDefault
        $vmEnableVtpm = Resolve-AzVmBooleanConfigValue -RawValue ([string](Get-ConfigValue -Config $ConfigMap -Key "VM_ENABLE_VTPM" -DefaultValue "true")) -KeyName 'VM_ENABLE_VTPM' -DefaultValue $true -TreatEmptyAsDefault
    }
    $azLocation = $defaultAzLocation
    $vmSize = $defaultVmSize
    $forcedAzLocation = ''
    $forcedVmSize = ''
    $forcedVmImage = ''
    $forcedVmDiskSize = ''
    $forcedVmStorageSku = ''
    if ($ConfigOverrides) {
        if ($ConfigOverrides.ContainsKey('AZ_LOCATION')) {
            $forcedAzLocation = [string]$ConfigOverrides['AZ_LOCATION']
        }
        if ($ConfigOverrides.ContainsKey('VM_SIZE')) {
            $forcedVmSize = [string]$ConfigOverrides['VM_SIZE']
        }
        if ($ConfigOverrides.ContainsKey($vmImageConfigKey)) {
            $forcedVmImage = [string]$ConfigOverrides[$vmImageConfigKey]
        }
        if ($ConfigOverrides.ContainsKey($vmDiskSizeConfigKey)) {
            $forcedVmDiskSize = [string]$ConfigOverrides[$vmDiskSizeConfigKey]
        }
        if ($ConfigOverrides.ContainsKey('VM_STORAGE_SKU')) {
            $forcedVmStorageSku = [string]$ConfigOverrides['VM_STORAGE_SKU']
        }
    }

    $hasForcedAzLocation = -not [string]::IsNullOrWhiteSpace([string]$forcedAzLocation)
    $hasForcedVmSize = -not [string]::IsNullOrWhiteSpace([string]$forcedVmSize)
    if ($hasForcedAzLocation) {
        $azLocation = [string]$forcedAzLocation
    }
    if ($hasForcedVmSize) {
        $vmSize = [string]$forcedVmSize
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$forcedVmImage)) {
        $vmImage = [string]$forcedVmImage
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$forcedVmStorageSku)) {
        $vmStorageSku = [string]$forcedVmStorageSku
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$defaultAzLocation)) {
        $defaultAzLocation = ([string]$defaultAzLocation).Trim().ToLowerInvariant()
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$azLocation)) {
        $azLocation = ([string]$azLocation).Trim().ToLowerInvariant()
    }

    $shouldPromptLocationAndSku = (-not $AutoMode) -and -not ($hasForcedAzLocation -or $hasForcedVmSize) -and -not [string]::Equals([string]$OperationName, 'update', [System.StringComparison]::OrdinalIgnoreCase)
    if ($shouldPromptLocationAndSku) {
        $priceHours = Get-PriceHoursFromConfig -Config $ConfigMap -DefaultHours 730
        $regionBackToken = Get-AzVmSkuPickerRegionBackToken
        while ($true) {
            $azLocation = Select-AzLocationInteractive -DefaultLocation $azLocation
            if ([string]::IsNullOrWhiteSpace([string]$azLocation)) {
                Write-Host "Selected Azure region is empty. Please select a valid region." -ForegroundColor Yellow
                continue
            }
            $vmSizeSelection = Select-VmSkuInteractive -Location $azLocation -DefaultVmSize $defaultVmSize -PriceHours $priceHours
            if ([string]::Equals([string]$vmSizeSelection, [string]$regionBackToken, [System.StringComparison]::Ordinal)) {
                continue
            }

            $vmSize = [string]$vmSizeSelection
            break
        }
        if ($ConfigOverrides) {
            $ConfigOverrides["AZ_LOCATION"] = $azLocation
            $ConfigOverrides["VM_SIZE"] = $vmSize
        }

        Write-Host "Interactive selection -> AZ_LOCATION='$azLocation', VM_SIZE='$vmSize'." -ForegroundColor Green
    }

    if ([string]::IsNullOrWhiteSpace([string]$azLocation)) {
        Throw-FriendlyError `
            -Detail "AZ_LOCATION is empty. Region selection is required before resource group creation." `
            -Code 22 `
            -Summary "Azure region is required." `
            -Hint "Set AZ_LOCATION in .env or select a region interactively."
    }

    Assert-LocationExists -Location $azLocation
    $regionCode = Get-AzVmRegionCode -Location $azLocation

    $nameTokens = @{
        VM_NAME = [string]$vmName
        REGION_CODE = [string]$regionCode
        N = "1"
    }

    $resourceGroupTemplate = [string](Get-ConfigValue -Config $ConfigMap -Key "RESOURCE_GROUP_TEMPLATE" -DefaultValue "rg-{VM_NAME}-{REGION_CODE}-g{N}")

    $configuredResourceGroupRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "RESOURCE_GROUP" -DefaultValue "")
    $configuredResourceGroup = ''
    if ($ConfigOverrides -and $ConfigOverrides.ContainsKey('RESOURCE_GROUP') -and -not [string]::IsNullOrWhiteSpace([string]$ConfigOverrides['RESOURCE_GROUP'])) {
        $configuredResourceGroup = [string]$ConfigOverrides['RESOURCE_GROUP']
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$configuredResourceGroupRaw)) {
        $configuredResourceGroup = Resolve-AzVmTemplate -Template $configuredResourceGroupRaw -Tokens $nameTokens
    }

    $resourceGroup = ''
    $resourceGroupGenerated = $false
    if ([string]::Equals([string]$OperationName, 'update', [System.StringComparison]::OrdinalIgnoreCase)) {
        if ([string]::IsNullOrWhiteSpace([string]$configuredResourceGroup)) {
            Throw-FriendlyError `
                -Detail "Update target resource group is empty." `
                -Code 66 `
                -Summary "Update command could not resolve the managed resource group." `
                -Hint "Provide --group together with update, or select an existing managed resource group interactively."
        }

        $resourceGroup = [string]$configuredResourceGroup
        Assert-AzVmManagedResourceGroup -ResourceGroup $resourceGroup -OperationName 'update'
    }
    elseif ([string]::Equals([string]$OperationName, 'create', [System.StringComparison]::OrdinalIgnoreCase)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$configuredResourceGroup) -and $ConfigOverrides -and $ConfigOverrides.ContainsKey('RESOURCE_GROUP')) {
            $resourceGroup = [string]$configuredResourceGroup
            Write-Host ("Create command will use the requested new resource group name '{0}'." -f $resourceGroup) -ForegroundColor Green
        }
        else {
            $resourceGroup = Resolve-AzVmResourceGroupNameFromTemplate `
                -Template $resourceGroupTemplate `
                -VmName $vmName `
                -RegionCode $regionCode `
                -UseNextIndex
            $resourceGroupGenerated = $true
            Write-Host ("Generated resource group name: {0}" -f [string]$resourceGroup) -ForegroundColor Cyan
        }

        if (Test-AzVmResourceGroupExists -ResourceGroup $resourceGroup) {
            Throw-FriendlyError `
                -Detail ("Create command generated resource group '{0}', but it already exists." -f [string]$resourceGroup) `
                -Code 62 `
                -Summary "Create command requires a new managed resource group." `
                -Hint "Retry create so the next global gX identifier can be selected, or choose another unused managed resource group name."
        }
    }
    else {
        $resourceGroupForced = ($ConfigOverrides -and $ConfigOverrides.ContainsKey('RESOURCE_GROUP') -and -not [string]::IsNullOrWhiteSpace([string]$ConfigOverrides['RESOURCE_GROUP']))
        if ($resourceGroupForced -and -not [string]::IsNullOrWhiteSpace([string]$configuredResourceGroup)) {
            $resourceGroup = [string]$configuredResourceGroup
            Write-Host ("Resource group override '{0}' will be used." -f $resourceGroup) -ForegroundColor Green
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$configuredResourceGroup)) {
            $configuredExists = Test-AzVmResourceGroupExists -ResourceGroup $configuredResourceGroup
            if ($configuredExists) {
                $resourceGroup = [string]$configuredResourceGroup
                Write-Host ("Resource group '{0}' exists and will be used." -f $resourceGroup) -ForegroundColor Green
            }
            else {
                Write-Host ("Configured resource group '{0}' does not exist. A new resource group name will be generated." -f $configuredResourceGroup) -ForegroundColor Yellow
            }
        }

        if ([string]::IsNullOrWhiteSpace([string]$resourceGroup)) {
            $resourceGroup = Resolve-AzVmResourceGroupNameFromTemplate `
                -Template $resourceGroupTemplate `
                -VmName $vmName `
                -RegionCode $regionCode `
                -UseNextIndex
            $resourceGroupGenerated = $true
            Write-Host ("Generated resource group name: {0}" -f [string]$resourceGroup) -ForegroundColor Cyan
        }
    }

    $resourceGroupExists = Test-AzVmResourceGroupExists -ResourceGroup $resourceGroup
    if ($resourceGroupExists) {
        if ([string]::Equals([string]$OperationName, 'create', [System.StringComparison]::OrdinalIgnoreCase)) {
            Throw-FriendlyError `
                -Detail ("Create command requires a new managed resource group, but '{0}' already exists." -f [string]$resourceGroup) `
                -Code 62 `
                -Summary "Create command cannot continue with an existing resource group." `
                -Hint "Accept the suggested next gX resource group name, or enter another unused managed resource group name."
        }

        Assert-AzVmManagedResourceGroup -ResourceGroup $resourceGroup -OperationName 'provisioning'
    }

    $managedResourceIndexAllocator = $null
    if (-not [string]::Equals([string]$OperationName, 'update', [System.StringComparison]::OrdinalIgnoreCase)) {
        $managedResourceIndexAllocator = New-AzVmManagedResourceIndexAllocator
    }

    $vnetSeed = Get-AzVmManagedNameSeed -ConfigMap $ConfigMap -ConfigOverrides $ConfigOverrides -OperationName $OperationName -NameKey 'VNET_NAME' -TemplateKey 'VNET_NAME_TEMPLATE' -TemplateDefaultValue 'net-{VM_NAME}-{REGION_CODE}-n{N}'
    $vnetRaw = [string]$vnetSeed.Value
    $vnetExplicit = [bool]$vnetSeed.Explicit
    if ($vnetExplicit) {
        $VNET = [string]$vnetRaw
    }
    else {
        $VNET = Resolve-AzVmNameFromTemplate -Template $vnetRaw -ResourceType 'net' -VmName $vmName -RegionCode $regionCode -ResourceGroup $resourceGroup -UseNextIndex -IndexAllocator $managedResourceIndexAllocator -LogicalName 'VNET_NAME'
    }
    Register-AzVmManagedResourceNameIndex -Allocator $managedResourceIndexAllocator -Name $VNET -LogicalName 'VNET_NAME' | Out-Null

    $subnetSeed = Get-AzVmManagedNameSeed -ConfigMap $ConfigMap -ConfigOverrides $ConfigOverrides -OperationName $OperationName -NameKey 'SUBNET_NAME' -TemplateKey 'SUBNET_NAME_TEMPLATE' -TemplateDefaultValue 'subnet-{VM_NAME}-{REGION_CODE}-n{N}'
    $subnetRaw = [string]$subnetSeed.Value
    $subnetExplicit = [bool]$subnetSeed.Explicit
    if ($subnetExplicit) {
        $SUBNET = [string]$subnetRaw
    }
    else {
        $SUBNET = Resolve-AzVmNameFromTemplate -Template $subnetRaw -ResourceType 'subnet' -VmName $vmName -RegionCode $regionCode -ResourceGroup $resourceGroup -UseNextIndex -IndexAllocator $managedResourceIndexAllocator -LogicalName 'SUBNET_NAME'
    }
    Register-AzVmManagedResourceNameIndex -Allocator $managedResourceIndexAllocator -Name $SUBNET -LogicalName 'SUBNET_NAME' | Out-Null

    $nsgSeed = Get-AzVmManagedNameSeed -ConfigMap $ConfigMap -ConfigOverrides $ConfigOverrides -OperationName $OperationName -NameKey 'NSG_NAME' -TemplateKey 'NSG_NAME_TEMPLATE' -TemplateDefaultValue 'nsg-{VM_NAME}-{REGION_CODE}-n{N}'
    $nsgRaw = [string]$nsgSeed.Value
    $nsgExplicit = [bool]$nsgSeed.Explicit
    if ($nsgExplicit) {
        $NSG = [string]$nsgRaw
    }
    else {
        $NSG = Resolve-AzVmNameFromTemplate -Template $nsgRaw -ResourceType 'nsg' -VmName $vmName -RegionCode $regionCode -ResourceGroup $resourceGroup -UseNextIndex -IndexAllocator $managedResourceIndexAllocator -LogicalName 'NSG_NAME'
    }
    Register-AzVmManagedResourceNameIndex -Allocator $managedResourceIndexAllocator -Name $NSG -LogicalName 'NSG_NAME' | Out-Null

    $nsgRuleSeed = Get-AzVmManagedNameSeed -ConfigMap $ConfigMap -ConfigOverrides $ConfigOverrides -OperationName $OperationName -NameKey 'NSG_RULE_NAME' -TemplateKey 'NSG_RULE_NAME_TEMPLATE' -TemplateDefaultValue 'nsg-rule-{VM_NAME}-{REGION_CODE}-n{N}'
    $nsgRuleRaw = [string]$nsgRuleSeed.Value
    $nsgRuleExplicit = [bool]$nsgRuleSeed.Explicit
    if ($nsgRuleExplicit) {
        $nsgRule = [string]$nsgRuleRaw
    }
    else {
        $nsgRule = Resolve-AzVmNameFromTemplate -Template $nsgRuleRaw -ResourceType 'nsgrule' -VmName $vmName -RegionCode $regionCode -ResourceGroup $resourceGroup -UseNextIndex -IndexAllocator $managedResourceIndexAllocator -LogicalName 'NSG_RULE_NAME'
    }
    Register-AzVmManagedResourceNameIndex -Allocator $managedResourceIndexAllocator -Name $nsgRule -LogicalName 'NSG_RULE_NAME' | Out-Null

    $ipSeed = Get-AzVmManagedNameSeed -ConfigMap $ConfigMap -ConfigOverrides $ConfigOverrides -OperationName $OperationName -NameKey 'PUBLIC_IP_NAME' -TemplateKey 'PUBLIC_IP_NAME_TEMPLATE' -TemplateDefaultValue 'ip-{VM_NAME}-{REGION_CODE}-n{N}'
    $ipRaw = [string]$ipSeed.Value
    $ipExplicit = [bool]$ipSeed.Explicit
    if ($ipExplicit) {
        $IP = [string]$ipRaw
    }
    else {
        $IP = Resolve-AzVmNameFromTemplate -Template $ipRaw -ResourceType 'ip' -VmName $vmName -RegionCode $regionCode -ResourceGroup $resourceGroup -UseNextIndex -IndexAllocator $managedResourceIndexAllocator -LogicalName 'PUBLIC_IP_NAME'
    }
    Register-AzVmManagedResourceNameIndex -Allocator $managedResourceIndexAllocator -Name $IP -LogicalName 'PUBLIC_IP_NAME' | Out-Null

    $nicSeed = Get-AzVmManagedNameSeed -ConfigMap $ConfigMap -ConfigOverrides $ConfigOverrides -OperationName $OperationName -NameKey 'NIC_NAME' -TemplateKey 'NIC_NAME_TEMPLATE' -TemplateDefaultValue 'nic-{VM_NAME}-{REGION_CODE}-n{N}'
    $nicRaw = [string]$nicSeed.Value
    $nicExplicit = [bool]$nicSeed.Explicit
    if ($nicExplicit) {
        $NIC = [string]$nicRaw
    }
    else {
        $NIC = Resolve-AzVmNameFromTemplate -Template $nicRaw -ResourceType 'nic' -VmName $vmName -RegionCode $regionCode -ResourceGroup $resourceGroup -UseNextIndex -IndexAllocator $managedResourceIndexAllocator -LogicalName 'NIC_NAME'
    }
    Register-AzVmManagedResourceNameIndex -Allocator $managedResourceIndexAllocator -Name $NIC -LogicalName 'NIC_NAME' | Out-Null

    $vmDiskSeed = Get-AzVmManagedNameSeed -ConfigMap $ConfigMap -ConfigOverrides $ConfigOverrides -OperationName $OperationName -NameKey 'VM_DISK_NAME' -TemplateKey 'VM_DISK_NAME_TEMPLATE' -TemplateDefaultValue 'disk-{VM_NAME}-{REGION_CODE}-n{N}'
    $vmDiskNameRaw = [string]$vmDiskSeed.Value
    $vmDiskExplicit = [bool]$vmDiskSeed.Explicit
    if ($vmDiskExplicit) {
        $vmDiskName = [string]$vmDiskNameRaw
    }
    else {
        $vmDiskName = Resolve-AzVmNameFromTemplate -Template $vmDiskNameRaw -ResourceType 'disk' -VmName $vmName -RegionCode $regionCode -ResourceGroup $resourceGroup -UseNextIndex -IndexAllocator $managedResourceIndexAllocator -LogicalName 'VM_DISK_NAME'
    }
    Register-AzVmManagedResourceNameIndex -Allocator $managedResourceIndexAllocator -Name $vmDiskName -LogicalName 'VM_DISK_NAME' | Out-Null

    Assert-AzVmManagedResourceNamesValid -NameMap ([ordered]@{
        RESOURCE_GROUP = [string]$resourceGroup
        VNET_NAME = [string]$VNET
        SUBNET_NAME = [string]$SUBNET
        NSG_NAME = [string]$NSG
        NSG_RULE_NAME = [string]$nsgRule
        PUBLIC_IP_NAME = [string]$IP
        NIC_NAME = [string]$NIC
        VM_DISK_NAME = [string]$vmDiskName
    })

    Invoke-AzVmExplicitOverridePrecheck `
        -ResourceGroup $resourceGroup `
        -VnetName $VNET `
        -SubnetName $SUBNET `
        -NsgName $NSG `
        -NsgRuleName $nsgRule `
        -PublicIpName $IP `
        -NicName $NIC `
        -VmDiskName $vmDiskName `
        -ResourceGroupExists:$resourceGroupExists `
        -VnetExplicit:$vnetExplicit `
        -SubnetExplicit:$subnetExplicit `
        -NsgExplicit:$nsgExplicit `
        -NsgRuleExplicit:$nsgRuleExplicit `
        -PublicIpExplicit:$ipExplicit `
        -NicExplicit:$nicExplicit `
        -VmDiskExplicit:$vmDiskExplicit

    if ([string]::Equals([string]$OperationName, 'create', [System.StringComparison]::OrdinalIgnoreCase)) {
        Assert-AzVmVmNameConflictFree -VmName $vmName -TargetResourceGroup $resourceGroup
    }

    $vmDiskSize = Resolve-AzVmTemplate -Template (Get-ConfigValue -Config $ConfigMap -Key $vmDiskSizeConfigKey -DefaultValue $VmDiskSizeDefault) -Tokens $baseTokens
    if (-not [string]::IsNullOrWhiteSpace([string]$forcedVmDiskSize)) {
        $vmDiskSize = [string]$forcedVmDiskSize
    }

    $companyName = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $ConfigMap -Key "company_name" -DefaultValue '')) -Tokens $baseTokens
    $employeeEmailAddress = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $ConfigMap -Key 'employee_email_address' -DefaultValue '')) -Tokens $baseTokens
    $employeeFullName = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $ConfigMap -Key 'employee_full_name' -DefaultValue '')) -Tokens $baseTokens
    $vmUser = Get-AzVmRequiredResolvedConfigValue -ConfigMap $ConfigMap -Key 'VM_ADMIN_USER' -Tokens $baseTokens -Summary 'VM admin user is required.' -Hint 'Set VM_ADMIN_USER in .env to the primary VM username.'
    $vmPass = Get-AzVmRequiredResolvedConfigValue -ConfigMap $ConfigMap -Key 'VM_ADMIN_PASS' -Tokens $baseTokens -Summary 'VM admin password is required.' -Hint 'Set VM_ADMIN_PASS in .env to a non-placeholder password.'
    $vmAssistantUser = Get-AzVmRequiredResolvedConfigValue -ConfigMap $ConfigMap -Key 'VM_ASSISTANT_USER' -Tokens $baseTokens -Summary 'VM assistant user is required.' -Hint 'Set VM_ASSISTANT_USER in .env to the secondary VM username.'
    $vmAssistantPass = Get-AzVmRequiredResolvedConfigValue -ConfigMap $ConfigMap -Key 'VM_ASSISTANT_PASS' -Tokens $baseTokens -Summary 'VM assistant password is required.' -Hint 'Set VM_ASSISTANT_PASS in .env to a non-placeholder password.'
    $sshPortValue = [string](Get-ConfigValue -Config $ConfigMap -Key "VM_SSH_PORT" -DefaultValue (Get-AzVmDefaultSshPortText))
    $sshPort = Resolve-AzVmTemplate -Template $sshPortValue -Tokens $baseTokens
    $rdpPortValue = [string](Get-ConfigValue -Config $ConfigMap -Key "VM_RDP_PORT" -DefaultValue (Get-AzVmDefaultRdpPortText))
    $rdpPort = Resolve-AzVmTemplate -Template $rdpPortValue -Tokens $baseTokens
    $vmInitTaskDirName = Resolve-AzVmTemplate -Template (Get-ConfigValue -Config $ConfigMap -Key $vmInitTaskDirConfigKey -DefaultValue ([string]$((Get-AzVmPlatformDefaults -Platform $Platform).VmInitTaskDirDefault))) -Tokens $baseTokens
    $vmUpdateTaskDirName = Resolve-AzVmTemplate -Template (Get-ConfigValue -Config $ConfigMap -Key $vmUpdateTaskDirConfigKey -DefaultValue ([string]$((Get-AzVmPlatformDefaults -Platform $Platform).VmUpdateTaskDirDefault))) -Tokens $baseTokens
    $vmInitTaskDir = Resolve-ConfigPath -PathValue $vmInitTaskDirName -RootPath $ScriptRoot
    $vmUpdateTaskDir = Resolve-ConfigPath -PathValue $vmUpdateTaskDirName -RootPath $ScriptRoot

    $defaultPortsCsv = Get-AzVmDefaultTcpPortsCsv
    $tcpPortsConfiguredCsv = Get-ConfigValue -Config $ConfigMap -Key "TCP_PORTS" -DefaultValue $defaultPortsCsv
    $tcpPorts = @($tcpPortsConfiguredCsv -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })

    if (-not ($sshPort -match '^\d+$')) {
        throw "Invalid SSH port '$sshPort'."
    }
    if ($tcpPorts -notcontains $sshPort) {
        $tcpPorts += $sshPort
    }
    $includeRdp = [bool]((Get-AzVmPlatformDefaults -Platform $Platform).IncludeRdp)
    if ($includeRdp) {
        if (-not ($rdpPort -match '^\d+$')) {
            throw "Invalid RDP port '$rdpPort'."
        }
        if ($tcpPorts -notcontains $rdpPort) {
            $tcpPorts += $rdpPort
        }
    }
    if (-not $tcpPorts -or $tcpPorts.Count -eq 0) {
        throw "No valid TCP ports were found in TCP_PORTS."
    }

    $context = [ordered]@{
        RegionCode = $regionCode
        ResourceGroup = $resourceGroup
        AzLocation = $azLocation
        DefaultAzLocation = $defaultAzLocation
        VNET = $VNET
        SUBNET = $SUBNET
        NSG = $NSG
        NsgRule = $nsgRule
        IP = $IP
        NIC = $NIC
        VmName = $vmName
        VmImage = $vmImage
        VmStorageSku = $vmStorageSku
        VmSecurityType = $vmSecurityType
        VmEnableSecureBoot = [bool]$vmEnableSecureBoot
        VmEnableVtpm = [bool]$vmEnableVtpm
        VmEnableHibernation = [bool]$vmEnableHibernation
        VmEnableNestedVirtualization = [bool]$vmEnableNestedVirtualization
        VmSize = $vmSize
        DefaultVmSize = $defaultVmSize
        VmDiskName = $vmDiskName
        VmDiskSize = $vmDiskSize
        CompanyName = [string]$companyName
        EmployeeEmailAddress = [string]$employeeEmailAddress
        EmployeeFullName = [string]$employeeFullName
        VmUser = $vmUser
        VmPass = $vmPass
        VmAssistantUser = $vmAssistantUser
        VmAssistantPass = $vmAssistantPass
        SshPort = $sshPort
        RdpPort = $rdpPort
        TcpPorts = @($tcpPorts)
        TcpPortsConfiguredCsv = [string]$tcpPortsConfiguredCsv
        VmInitTaskDir = $vmInitTaskDir
        VmUpdateTaskDir = $vmUpdateTaskDir
    }

    if (-not $AutoMode -and -not $SkipInteractiveConfigEditor -and ($OperationName -in @('create','update'))) {
        $context = Invoke-AzVmInteractiveStep1Editor `
            -ConfigMap $ConfigMap `
            -EnvFilePath $EnvFilePath `
            -Platform $Platform `
            -ScriptRoot $ScriptRoot `
            -VmNameDefault $VmNameDefault `
            -VmImageDefault $VmImageDefault `
            -VmSizeDefault $VmSizeDefault `
            -VmDiskSizeDefault $VmDiskSizeDefault `
            -ConfigOverrides $ConfigOverrides `
            -OperationName $OperationName `
            -Context $context `
            -PersistGeneratedResourceGroup:$PersistGeneratedResourceGroup `
            -DeferEnvWrites:$DeferEnvWrites
    }

    $persistMap = Get-AzVmStep1ContextPersistenceMap -Platform $Platform -Context $context
    if (-not $AutoMode -and $PersistGeneratedResourceGroup) {
        if ($DeferEnvWrites) {
            $pendingEnvUpdates = $persistMap
        }
        else {
            Save-AzVmStep1ContextPersistenceMap -EnvFilePath $EnvFilePath -PersistMap $persistMap
        }
    }

    $context['PendingEnvUpdates'] = $pendingEnvUpdates
    return $context
}

# Handles Assert-AzVmVmNameConflictFree.
function Assert-AzVmVmNameConflictFree {
    param(
        [string]$VmName,
        [string]$TargetResourceGroup
    )

    if ([string]::IsNullOrWhiteSpace([string]$VmName)) {
        Throw-FriendlyError `
            -Detail "VM name is empty." `
            -Code 2 `
            -Summary "VM name validation failed." `
            -Hint "Provide a valid VM_NAME before continuing."
    }

    $vmMatchesJson = az resource list --resource-type "Microsoft.Compute/virtualMachines" --query "[?name=='$VmName'].{name:name,resourceGroup:resourceGroup,id:id}" -o json --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        Throw-FriendlyError `
            -Detail "az resource list failed while checking VM name uniqueness." `
            -Code 62 `
            -Summary "VM name uniqueness check could not be completed." `
            -Hint "Check Azure login status and subscription access."
    }

    $vmMatches = @(
        ConvertFrom-JsonArrayCompat -InputObject $vmMatchesJson |
            Where-Object { $_ -ne $null }
    )
    if (@($vmMatches).Count -eq 0) {
        return
    }

    $otherGroupMatches = @(
        @($vmMatches) | Where-Object {
            $candidateGroup = [string]$_.resourceGroup
            -not [string]::Equals($candidateGroup, [string]$TargetResourceGroup, [System.StringComparison]::OrdinalIgnoreCase)
        }
    )
    if (@($otherGroupMatches).Count -eq 0) {
        return
    }

    $conflictGroups = @(
        @($otherGroupMatches) |
            ForEach-Object { [string]$_.resourceGroup } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Sort-Object -Unique
    )
    $conflictGroupText = if (@($conflictGroups).Count -gt 0) { $conflictGroups -join ", " } else { "(unknown resource group)" }

    Throw-FriendlyError `
        -Detail ("VM name '{0}' already exists in resource group(s): {1}." -f [string]$VmName, [string]$conflictGroupText) `
        -Code 62 `
        -Summary "VM name must be unique before provisioning continues." `
        -Hint "Choose another VM_NAME or target the existing resource group that already owns this VM name."
}

# Handles Resolve-AzVmSecurityTypeValue.
function Resolve-AzVmSecurityTypeValue {
    param(
        [string]$RawValue
    )

    $valueText = [string]$RawValue
    if ([string]::IsNullOrWhiteSpace([string]$valueText)) {
        return ''
    }

    $normalized = $valueText.Trim().ToLowerInvariant()
    switch ($normalized) {
        'standard' { return 'Standard' }
        'trustedlaunch' { return 'TrustedLaunch' }
    }

    Throw-FriendlyError `
        -Detail ("VM_SECURITY_TYPE '{0}' is invalid." -f $RawValue) `
        -Code 22 `
        -Summary "VM security type is invalid." `
        -Hint "Use VM_SECURITY_TYPE=Standard or VM_SECURITY_TYPE=TrustedLaunch."
}

# Handles Resolve-AzVmBooleanConfigValue.
function Resolve-AzVmBooleanConfigValue {
    param(
        [string]$RawValue,
        [string]$KeyName,
        [bool]$DefaultValue = $false,
        [switch]$TreatEmptyAsDefault
    )

    $valueText = [string]$RawValue
    if ([string]::IsNullOrWhiteSpace([string]$valueText)) {
        if ($TreatEmptyAsDefault) {
            return [bool]$DefaultValue
        }

        Throw-FriendlyError `
            -Detail ("Config key '{0}' is empty." -f $KeyName) `
            -Code 22 `
            -Summary "Boolean config value is missing." `
            -Hint ("Set {0}=true or {0}=false." -f $KeyName)
    }

    $normalized = $valueText.Trim().ToLowerInvariant()
    if ($normalized -in @('1','true','yes','y','on')) {
        return $true
    }
    if ($normalized -in @('0','false','no','n','off')) {
        return $false
    }

    Throw-FriendlyError `
        -Detail ("Config key '{0}' has invalid boolean value '{1}'." -f $KeyName, $RawValue) `
        -Code 22 `
        -Summary "Boolean config value is invalid." `
        -Hint ("Use {0}=true or {0}=false." -f $KeyName)
}
