# Imported runtime region: test-orchestration.

# Handles Test-AzVmVmNameFormat.
function Test-AzVmVmNameFormat {
    param(
        [string]$VmName
    )

    if ([string]::IsNullOrWhiteSpace([string]$VmName)) {
        return $false
    }

    return ([string]$VmName -match '^[a-zA-Z][a-zA-Z0-9\-]{2,15}$')
}

# Handles Get-AzVmManagedNameValidationRule.
function Get-AzVmManagedNameValidationRule {
    param(
        [string]$ConfigKey
    )

    switch ([string]$ConfigKey) {
        'RESOURCE_GROUP' {
            return [pscustomobject]@{
                DisplayName = 'resource group'
                MaxLength = 90
                Pattern = '^[A-Za-z0-9._()\-]+$'
                TrailingDotForbidden = $true
                Hint = "Use 1-90 characters with letters, numbers, dot, underscore, hyphen, or parentheses."
            }
        }
        'VNET_NAME' {
            return [pscustomobject]@{
                DisplayName = 'virtual network'
                MaxLength = 64
                Pattern = '^[A-Za-z0-9][A-Za-z0-9._\-]{0,63}$'
                TrailingDotForbidden = $false
                Hint = "Use 1-64 characters with letters, numbers, dot, underscore, or hyphen."
            }
        }
        'SUBNET_NAME' {
            return [pscustomobject]@{
                DisplayName = 'subnet'
                MaxLength = 80
                Pattern = '^[A-Za-z0-9][A-Za-z0-9._\-]{0,79}$'
                TrailingDotForbidden = $false
                Hint = "Use 1-80 characters with letters, numbers, dot, underscore, or hyphen."
            }
        }
        'NSG_NAME' {
            return [pscustomobject]@{
                DisplayName = 'network security group'
                MaxLength = 80
                Pattern = '^[A-Za-z0-9][A-Za-z0-9._\-]{0,79}$'
                TrailingDotForbidden = $false
                Hint = "Use 1-80 characters with letters, numbers, dot, underscore, or hyphen."
            }
        }
        'NSG_RULE_NAME' {
            return [pscustomobject]@{
                DisplayName = 'network security rule'
                MaxLength = 80
                Pattern = '^[A-Za-z0-9][A-Za-z0-9._\-]{0,79}$'
                TrailingDotForbidden = $false
                Hint = "Use 1-80 characters with letters, numbers, dot, underscore, or hyphen."
            }
        }
        'PUBLIC_IP_NAME' {
            return [pscustomobject]@{
                DisplayName = 'public IP'
                MaxLength = 80
                Pattern = '^[A-Za-z0-9][A-Za-z0-9._\-]{0,79}$'
                TrailingDotForbidden = $false
                Hint = "Use 1-80 characters with letters, numbers, dot, underscore, or hyphen."
            }
        }
        'NIC_NAME' {
            return [pscustomobject]@{
                DisplayName = 'network interface'
                MaxLength = 80
                Pattern = '^[A-Za-z0-9][A-Za-z0-9._\-]{0,79}$'
                TrailingDotForbidden = $false
                Hint = "Use 1-80 characters with letters, numbers, dot, underscore, or hyphen."
            }
        }
        'VM_DISK_NAME' {
            return [pscustomobject]@{
                DisplayName = 'managed disk'
                MaxLength = 80
                Pattern = '^[A-Za-z0-9][A-Za-z0-9._\-]{0,79}$'
                TrailingDotForbidden = $false
                Hint = "Use 1-80 characters with letters, numbers, dot, underscore, or hyphen."
            }
        }
    }

    return $null
}

# Handles Assert-AzVmManagedNameContract.
function Assert-AzVmManagedNameContract {
    param(
        [string]$ConfigKey,
        [string]$NameValue
    )

    $rule = Get-AzVmManagedNameValidationRule -ConfigKey $ConfigKey
    if ($null -eq $rule) {
        return
    }

    $valueText = [string]$NameValue
    if ([string]::IsNullOrWhiteSpace([string]$valueText)) {
        Throw-FriendlyError `
            -Detail ("{0} resolved to an empty value." -f [string]$ConfigKey) `
            -Code 22 `
            -Summary "Managed resource naming is invalid." `
            -Hint ([string]$rule.Hint)
    }

    if ($valueText.Length -gt [int]$rule.MaxLength) {
        Throw-FriendlyError `
            -Detail ("{0} '{1}' is too long ({2} characters, max {3})." -f [string]$rule.DisplayName, $valueText, $valueText.Length, [int]$rule.MaxLength) `
            -Code 22 `
            -Summary "Managed resource naming is invalid." `
            -Hint ([string]$rule.Hint)
    }

    if (-not ($valueText -match [string]$rule.Pattern)) {
        Throw-FriendlyError `
            -Detail ("{0} '{1}' contains unsupported characters for this az-vm naming contract." -f [string]$rule.DisplayName, $valueText) `
            -Code 22 `
            -Summary "Managed resource naming is invalid." `
            -Hint ([string]$rule.Hint)
    }

    if ([bool]$rule.TrailingDotForbidden -and $valueText.EndsWith('.', [System.StringComparison]::Ordinal)) {
        Throw-FriendlyError `
            -Detail ("{0} '{1}' must not end with a dot." -f [string]$rule.DisplayName, $valueText) `
            -Code 22 `
            -Summary "Managed resource naming is invalid." `
            -Hint ([string]$rule.Hint)
    }
}

# Handles Get-AzVmPublicIpZoneArgs.
function Get-AzVmPublicIpZoneArgs {
    param(
        [string]$Location
    )

    $locationName = [string]$Location
    if ([string]::IsNullOrWhiteSpace([string]$locationName)) {
        return @()
    }

    $zonesJson = az account list-locations --query "[?name=='$locationName'] | [0].availabilityZoneMappings[].logicalZone" -o json --only-show-errors
    Assert-LastExitCode "az account list-locations (public IP zones)"
    $zones = ConvertFrom-JsonCompat -InputObject $zonesJson

    $zoneList = @()
    if ($zones -is [System.Array]) {
        $zoneList = @($zones)
    }
    elseif ($null -ne $zones) {
        $zoneList = @($zones)
    }

    $normalizedZones = @(
        $zoneList |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { ([string]$_).Trim() } |
            Sort-Object -Unique
    )

    if ($normalizedZones.Count -lt 1) {
        return @()
    }

    return @('--zone') + $normalizedZones
}

# Handles Assert-AzVmManagedResourceNamesValid.
function Assert-AzVmManagedResourceNamesValid {
    param(
        [hashtable]$NameMap
    )

    if ($null -eq $NameMap) {
        return
    }

    foreach ($configKey in @($NameMap.Keys)) {
        Assert-AzVmManagedNameContract -ConfigKey ([string]$configKey) -NameValue ([string]$NameMap[[string]$configKey])
    }
}

# Handles Invoke-AzVmExplicitOverridePrecheck.
function Invoke-AzVmExplicitOverridePrecheck {
    param(
        [string]$ResourceGroup,
        [string]$VnetName,
        [string]$SubnetName,
        [string]$NsgName,
        [string]$NsgRuleName,
        [string]$PublicIpName,
        [string]$NicName,
        [string]$VmDiskName,
        [switch]$ResourceGroupExists,
        [switch]$VnetExplicit,
        [switch]$SubnetExplicit,
        [switch]$NsgExplicit,
        [switch]$NsgRuleExplicit,
        [switch]$PublicIpExplicit,
        [switch]$NicExplicit,
        [switch]$VmDiskExplicit
    )

    if (-not $ResourceGroupExists) {
        return
    }

    $resourceChecks = @(
        @{ Enabled = [bool]$VnetExplicit; Label = 'VNET_NAME'; Type = 'Microsoft.Network/virtualNetworks'; Name = [string]$VnetName },
        @{ Enabled = [bool]$NsgExplicit; Label = 'NSG_NAME'; Type = 'Microsoft.Network/networkSecurityGroups'; Name = [string]$NsgName },
        @{ Enabled = [bool]$PublicIpExplicit; Label = 'PUBLIC_IP_NAME'; Type = 'Microsoft.Network/publicIPAddresses'; Name = [string]$PublicIpName },
        @{ Enabled = [bool]$NicExplicit; Label = 'NIC_NAME'; Type = 'Microsoft.Network/networkInterfaces'; Name = [string]$NicName },
        @{ Enabled = [bool]$VmDiskExplicit; Label = 'VM_DISK_NAME'; Type = 'Microsoft.Compute/disks'; Name = [string]$VmDiskName }
    )

    foreach ($resourceCheck in @($resourceChecks)) {
        if (-not [bool]$resourceCheck.Enabled) {
            continue
        }

        $resourceExists = Test-AzVmAzResourceExistsByType -ResourceGroup $ResourceGroup -ResourceType ([string]$resourceCheck.Type) -ResourceName ([string]$resourceCheck.Name)
        $resourceState = if ($resourceExists) { 'existing resource will be reused' } else { 'resource will be created later' }
        Write-Host ("Explicit override validated: {0}='{1}' -> {2}." -f [string]$resourceCheck.Label, [string]$resourceCheck.Name, [string]$resourceState) -ForegroundColor DarkCyan
    }

    if ($SubnetExplicit -and -not [string]::IsNullOrWhiteSpace([string]$VnetName)) {
        $vnetExists = Test-AzVmAzResourceExistsByType -ResourceGroup $ResourceGroup -ResourceType 'Microsoft.Network/virtualNetworks' -ResourceName $VnetName
        if ($vnetExists) {
            $subnetExists = Test-AzVmAzResourceExists -AzArgs @('network', 'vnet', 'subnet', 'show', '-g', $ResourceGroup, '--vnet-name', $VnetName, '-n', $SubnetName)
            $subnetState = if ($subnetExists) { 'existing resource will be reused' } else { 'resource will be created later' }
            Write-Host ("Explicit override validated: SUBNET_NAME='{0}' under VNET_NAME='{1}' -> {2}." -f [string]$SubnetName, [string]$VnetName, [string]$subnetState) -ForegroundColor DarkCyan
        }
    }

    if ($NsgRuleExplicit -and -not [string]::IsNullOrWhiteSpace([string]$NsgName)) {
        $nsgExists = Test-AzVmAzResourceExistsByType -ResourceGroup $ResourceGroup -ResourceType 'Microsoft.Network/networkSecurityGroups' -ResourceName $NsgName
        if ($nsgExists) {
            $ruleExists = Test-AzVmNsgRuleExists -ResourceGroup $ResourceGroup -NsgName $NsgName -RuleName $NsgRuleName
            $ruleState = if ($ruleExists) { 'existing resource will be reused' } else { 'resource will be created later' }
            Write-Host ("Explicit override validated: NSG_RULE_NAME='{0}' in NSG_NAME='{1}' -> {2}." -f [string]$NsgRuleName, [string]$NsgName, [string]$ruleState) -ForegroundColor DarkCyan
        }
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
        [hashtable]$ConfigOverrides
    )

    $vmNameDefaultResolved = [string](Get-ConfigValue -Config $ConfigMap -Key "VM_NAME" -DefaultValue $VmNameDefault)
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
            if ([string]::IsNullOrWhiteSpace([string]$vmNameDefaultResolved)) {
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
    if (-not $AutoMode) {
        Set-DotEnvValue -Path $EnvFilePath -Key "VM_NAME" -Value $vmName
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
    if ($ConfigOverrides) {
        if ($ConfigOverrides.ContainsKey('AZ_LOCATION')) {
            $forcedAzLocation = [string]$ConfigOverrides['AZ_LOCATION']
        }
        if ($ConfigOverrides.ContainsKey('VM_SIZE')) {
            $forcedVmSize = [string]$ConfigOverrides['VM_SIZE']
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

    if (-not [string]::IsNullOrWhiteSpace([string]$defaultAzLocation)) {
        $defaultAzLocation = ([string]$defaultAzLocation).Trim().ToLowerInvariant()
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$azLocation)) {
        $azLocation = ([string]$azLocation).Trim().ToLowerInvariant()
    }

    $shouldPromptLocationAndSku = (-not $AutoMode) -and -not ($hasForcedAzLocation -or $hasForcedVmSize)
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

        Set-DotEnvValue -Path $EnvFilePath -Key "AZ_LOCATION" -Value $azLocation
        Set-DotEnvValue -Path $EnvFilePath -Key $vmSizeConfigKey -Value $vmSize
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
    if (-not [string]::IsNullOrWhiteSpace([string]$configuredResourceGroupRaw)) {
        $configuredResourceGroup = Resolve-AzVmTemplate -Template $configuredResourceGroupRaw -Tokens $nameTokens
    }
    $resourceGroupForced = ($ConfigOverrides -and $ConfigOverrides.ContainsKey('RESOURCE_GROUP') -and -not [string]::IsNullOrWhiteSpace([string]$ConfigOverrides['RESOURCE_GROUP']))

    $resourceGroup = ''
    $resourceGroupGenerated = $false
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

    $resourceGroupExists = Test-AzVmResourceGroupExists -ResourceGroup $resourceGroup
    if ($resourceGroupExists) {
        Assert-AzVmManagedResourceGroup -ResourceGroup $resourceGroup -OperationName 'provisioning'
    }

    if ($resourceGroupGenerated -and $PersistGeneratedResourceGroup) {
        Set-DotEnvValue -Path $EnvFilePath -Key "RESOURCE_GROUP" -Value $resourceGroup
        if ($ConfigOverrides) {
            $ConfigOverrides["RESOURCE_GROUP"] = $resourceGroup
        }
    }

    Assert-AzVmVmNameConflictFree -VmName $vmName -TargetResourceGroup $resourceGroup

    $vnetRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "VNET_NAME" -DefaultValue "")
    $vnetExplicit = -not [string]::IsNullOrWhiteSpace([string]$vnetRaw)
    if (-not $vnetExplicit) {
        $vnetRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "VNET_NAME_TEMPLATE" -DefaultValue "net-{VM_NAME}-{REGION_CODE}-n{N}")
    }
    $VNET = Resolve-AzVmNameFromTemplate -Template $vnetRaw -ResourceType 'net' -VmName $vmName -RegionCode $regionCode -ResourceGroup $resourceGroup -UseNextIndex

    $subnetRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "SUBNET_NAME" -DefaultValue "")
    $subnetExplicit = -not [string]::IsNullOrWhiteSpace([string]$subnetRaw)
    if (-not $subnetExplicit) {
        $subnetRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "SUBNET_NAME_TEMPLATE" -DefaultValue "subnet-{VM_NAME}-{REGION_CODE}-n{N}")
    }
    $SUBNET = Resolve-AzVmNameFromTemplate -Template $subnetRaw -ResourceType 'subnet' -VmName $vmName -RegionCode $regionCode -ResourceGroup $resourceGroup -UseNextIndex

    $nsgRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "NSG_NAME" -DefaultValue "")
    $nsgExplicit = -not [string]::IsNullOrWhiteSpace([string]$nsgRaw)
    if (-not $nsgExplicit) {
        $nsgRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "NSG_NAME_TEMPLATE" -DefaultValue "nsg-{VM_NAME}-{REGION_CODE}-n{N}")
    }
    $NSG = Resolve-AzVmNameFromTemplate -Template $nsgRaw -ResourceType 'nsg' -VmName $vmName -RegionCode $regionCode -ResourceGroup $resourceGroup -UseNextIndex

    $nsgRuleRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "NSG_RULE_NAME" -DefaultValue "")
    $nsgRuleExplicit = -not [string]::IsNullOrWhiteSpace([string]$nsgRuleRaw)
    if (-not $nsgRuleExplicit) {
        $nsgRuleRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "NSG_RULE_NAME_TEMPLATE" -DefaultValue "nsg-rule-{VM_NAME}-{REGION_CODE}-n{N}")
    }
    $nsgRule = Resolve-AzVmNameFromTemplate -Template $nsgRuleRaw -ResourceType 'nsgrule' -VmName $vmName -RegionCode $regionCode -ResourceGroup $resourceGroup -UseNextIndex

    $ipRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "PUBLIC_IP_NAME" -DefaultValue "")
    $ipExplicit = -not [string]::IsNullOrWhiteSpace([string]$ipRaw)
    if (-not $ipExplicit) {
        $ipRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "PUBLIC_IP_NAME_TEMPLATE" -DefaultValue "ip-{VM_NAME}-{REGION_CODE}-n{N}")
    }
    $IP = Resolve-AzVmNameFromTemplate -Template $ipRaw -ResourceType 'ip' -VmName $vmName -RegionCode $regionCode -ResourceGroup $resourceGroup -UseNextIndex

    $nicRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "NIC_NAME" -DefaultValue "")
    $nicExplicit = -not [string]::IsNullOrWhiteSpace([string]$nicRaw)
    if (-not $nicExplicit) {
        $nicRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "NIC_NAME_TEMPLATE" -DefaultValue "nic-{VM_NAME}-{REGION_CODE}-n{N}")
    }
    $NIC = Resolve-AzVmNameFromTemplate -Template $nicRaw -ResourceType 'nic' -VmName $vmName -RegionCode $regionCode -ResourceGroup $resourceGroup -UseNextIndex

    $vmDiskNameRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "VM_DISK_NAME" -DefaultValue "")
    $vmDiskExplicit = -not [string]::IsNullOrWhiteSpace([string]$vmDiskNameRaw)
    if (-not $vmDiskExplicit) {
        $vmDiskNameRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "VM_DISK_NAME_TEMPLATE" -DefaultValue "disk-{VM_NAME}-{REGION_CODE}-n{N}")
    }
    $vmDiskName = Resolve-AzVmNameFromTemplate -Template $vmDiskNameRaw -ResourceType 'disk' -VmName $vmName -RegionCode $regionCode -ResourceGroup $resourceGroup -UseNextIndex

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

    if ($PersistGeneratedResourceGroup) {
        $generatedNameMap = [ordered]@{}
        if (-not $vnetExplicit) { $generatedNameMap["VNET_NAME"] = [string]$VNET }
        if (-not $subnetExplicit) { $generatedNameMap["SUBNET_NAME"] = [string]$SUBNET }
        if (-not $nsgExplicit) { $generatedNameMap["NSG_NAME"] = [string]$NSG }
        if (-not $nsgRuleExplicit) { $generatedNameMap["NSG_RULE_NAME"] = [string]$nsgRule }
        if (-not $ipExplicit) { $generatedNameMap["PUBLIC_IP_NAME"] = [string]$IP }
        if (-not $nicExplicit) { $generatedNameMap["NIC_NAME"] = [string]$NIC }
        if (-not $vmDiskExplicit) { $generatedNameMap["VM_DISK_NAME"] = [string]$vmDiskName }

        foreach ($generatedKey in @($generatedNameMap.Keys)) {
            $generatedValue = [string]$generatedNameMap[$generatedKey]
            Set-DotEnvValue -Path $EnvFilePath -Key $generatedKey -Value $generatedValue
            if ($ConfigOverrides) {
                $ConfigOverrides[$generatedKey] = $generatedValue
            }
        }
    }

    $vmDiskSize = Resolve-AzVmTemplate -Template (Get-ConfigValue -Config $ConfigMap -Key $vmDiskSizeConfigKey -DefaultValue $VmDiskSizeDefault) -Tokens $baseTokens
    $companyName = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $ConfigMap -Key "company_name" -DefaultValue '')) -Tokens $baseTokens
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

    return [ordered]@{
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

# Handles Get-AzVmCreateSecurityArguments.
function Get-AzVmCreateSecurityArguments {
    param(
        [hashtable]$Context
    )

    $arguments = @()
    $securityType = [string]$Context.VmSecurityType
    if ([string]::IsNullOrWhiteSpace([string]$securityType)) {
        return @($arguments)
    }

    $secureBootText = 'false'
    if ([bool]$Context.VmEnableSecureBoot) {
        $secureBootText = 'true'
    }

    $vtpmText = 'false'
    if ([bool]$Context.VmEnableVtpm) {
        $vtpmText = 'true'
    }

    $arguments += @('--security-type', $securityType)
    $arguments += @('--enable-secure-boot', $secureBootText)
    $arguments += @('--enable-vtpm', $vtpmText)
    return @($arguments)
}

# Handles Get-AzVmCreateSecurityArgumentsForCurrentVmState.
function Get-AzVmCreateSecurityArgumentsForCurrentVmState {
    param(
        [hashtable]$Context,
        [string]$ResourceGroup,
        [string]$VmName,
        [switch]$SuppressNotice
    )

    $desiredArguments = @(Get-AzVmCreateSecurityArguments -Context $Context)
    if (@($desiredArguments).Count -eq 0) {
        return @()
    }

    if ([string]::IsNullOrWhiteSpace([string]$ResourceGroup) -or [string]::IsNullOrWhiteSpace([string]$VmName)) {
        return @($desiredArguments)
    }

    $vmExists = $false
    try {
        $vmExists = Test-AzVmAzResourceExists -AzArgs @('vm', 'show', '-g', $ResourceGroup, '-n', $VmName)
    }
    catch {
        $vmExists = $false
    }

    if (-not $vmExists) {
        return @($desiredArguments)
    }

    if (-not $SuppressNotice) {
        Write-Host ("Existing VM '{0}' already exists in resource group '{1}'. Security-type create arguments are omitted because Azure does not allow changing securityProfile.securityType during create-or-update on an existing VM." -f $VmName, $ResourceGroup) -ForegroundColor DarkCyan
    }

    return @()
}

# Handles Get-AzVmSecurityTypeFeatureRegistrationSnapshot.
function Get-AzVmSecurityTypeFeatureRegistrationSnapshot {
    $result = [ordered]@{
        UseStandardSecurityType = ''
        StandardSecurityTypeAsFirstClassEnum = ''
    }

    $result.UseStandardSecurityType = Get-AzVmSafeTrimmedText -Value (az feature show --namespace Microsoft.Compute --name UseStandardSecurityType --query properties.state -o tsv --only-show-errors 2>$null)
    if ($LASTEXITCODE -ne 0) {
        $result.UseStandardSecurityType = ''
    }

    $result.StandardSecurityTypeAsFirstClassEnum = Get-AzVmSafeTrimmedText -Value (az feature show --namespace Microsoft.Compute --name StandardSecurityTypeAsFirstClassEnum --query properties.state -o tsv --only-show-errors 2>$null)
    if ($LASTEXITCODE -ne 0) {
        $result.StandardSecurityTypeAsFirstClassEnum = ''
    }

    return [pscustomobject]$result
}

# Handles Assert-AzVmSecurityTypePreconditions.
function Assert-AzVmSecurityTypePreconditions {
    param(
        [hashtable]$Context
    )

    $securityType = Get-AzVmSafeTrimmedText -Value $Context.VmSecurityType
    if (-not [string]::Equals([string]$securityType, 'Standard', [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    $featureStates = Get-AzVmSecurityTypeFeatureRegistrationSnapshot
    $stateTexts = @(
        "UseStandardSecurityType=$([string]$featureStates.UseStandardSecurityType)"
        "StandardSecurityTypeAsFirstClassEnum=$([string]$featureStates.StandardSecurityTypeAsFirstClassEnum)"
    )

    $isRegistered = [string]::Equals([string]$featureStates.UseStandardSecurityType, 'Registered', [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals([string]$featureStates.StandardSecurityTypeAsFirstClassEnum, 'Registered', [System.StringComparison]::OrdinalIgnoreCase)

    if ($isRegistered) {
        Write-Host ("Standard VM security type is available in this subscription. Feature states: {0}" -f ($stateTexts -join ', ')) -ForegroundColor DarkCyan
        return
    }

    Throw-FriendlyError `
        -Detail ("VM_SECURITY_TYPE=Standard requires an Azure subscription feature registration. Current states: {0}." -f ($stateTexts -join ', ')) `
        -Code 22 `
        -Summary "Standard VM security type is not available in this subscription." `
        -Hint "Register Microsoft.Compute/UseStandardSecurityType or Microsoft.Compute/StandardSecurityTypeAsFirstClassEnum, wait for state Registered, then retry."
}

# Handles Invoke-AzVmPrecheckStep.
function Invoke-AzVmPrecheckStep {
    param(
        [hashtable]$Context
    )

    Show-AzVmStepFirstUseValues `
        -StepLabel "Step 1/7 - resource availability precheck" `
        -Context $Context `
        -Keys @("AzLocation", "VmImage", "VmSize", "VmDiskSize")

    Assert-LocationExists -Location $Context.AzLocation
    Assert-VmImageAvailable -Location $Context.AzLocation -ImageUrn $Context.VmImage
    Assert-VmSkuAvailableViaRest -Location $Context.AzLocation -VmSize $Context.VmSize
    Assert-VmOsDiskSizeCompatible -Location $Context.AzLocation -ImageUrn $Context.VmImage -VmDiskSizeGb $Context.VmDiskSize
    Assert-AzVmSecurityTypePreconditions -Context $Context
}

# Handles Get-AzVmNestedVirtualizationSupportInfo.
function Get-AzVmVmSkuCapabilitySnapshot {
    param(
        [string]$Location,
        [string]$VmSize
    )

    $result = [ordered]@{
        Known = $false
        Message = ''
        Evidence = @()
        CapabilityRows = @()
        Family = ''
    }

    if ([string]::IsNullOrWhiteSpace([string]$Location) -or [string]::IsNullOrWhiteSpace([string]$VmSize)) {
        $result.Message = 'location-or-vm-size-missing'
        return [pscustomobject]$result
    }

    $subscriptionId = az account show --query id -o tsv --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$subscriptionId)) {
        $result.Message = 'subscription-read-failed'
        return [pscustomobject]$result
    }

    $filter = [uri]::EscapeDataString(("location eq '{0}'" -f [string]$Location))
    $url = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Compute/skus?api-version=2023-07-01&`$filter=$filter"
    $skuJson = az rest --method get --url $url -o json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$skuJson)) {
        $result.Message = 'compute-skus-read-failed'
        return [pscustomobject]$result
    }

    try {
        $skuPayload = ConvertFrom-JsonCompat -InputObject $skuJson
    }
    catch {
        $result.Message = 'compute-skus-parse-failed'
        return [pscustomobject]$result
    }

    $skuRows = @(
        (ConvertTo-ObjectArrayCompat -InputObject $skuPayload.value) |
            Where-Object {
                [string]::Equals([string]$_.resourceType, 'virtualMachines', [System.StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals([string]$_.name, [string]$VmSize, [System.StringComparison]::OrdinalIgnoreCase)
            }
    )
    if (@($skuRows).Count -eq 0) {
        $result.Message = 'vm-size-metadata-not-found'
        return [pscustomobject]$result
    }

    $capabilityRows = @(
        (ConvertTo-ObjectArrayCompat -InputObject $skuRows[0].capabilities) |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_.name)
            }
    )

    $result.Known = $true
    $result.Evidence = @(
        @($capabilityRows) | ForEach-Object {
            "{0}={1}" -f [string]$_.name, [string]$_.value
        }
    )
    $result.CapabilityRows = @($capabilityRows)
    $result.Family = [string]$skuRows[0].family
    return [pscustomobject]$result
}

# Handles Get-AzVmSafeTrimmedText.
function Get-AzVmSafeTrimmedText {
    param(
        [AllowNull()]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    $text = [string]$Value
    if ($null -eq $text) {
        return ''
    }

    return $text.Trim()
}

# Handles Resolve-AzVmFeatureSupportReasonText.
function Resolve-AzVmFeatureSupportReasonText {
    param(
        [string]$FeatureLabel,
        [string]$CapabilityLabel,
        [string]$ReasonCode,
        [string[]]$Evidence = @()
    )

    $evidenceText = if (@($Evidence).Count -gt 0) { @($Evidence) -join ', ' } else { '' }
    switch ([string]$ReasonCode) {
        'location-or-vm-size-missing' { return 'Azure region or VM size is empty.' }
        'subscription-read-failed' { return 'Azure subscription metadata could not be read.' }
        'compute-skus-read-failed' { return 'Azure compute SKU metadata could not be read from the REST API.' }
        'compute-skus-parse-failed' { return 'Azure compute SKU metadata could not be parsed.' }
        'vm-size-metadata-not-found' { return 'Azure compute SKU metadata for the selected region and VM size was not found.' }
        'hibernation-capability-not-advertised' { return ("Azure SKU metadata does not advertise capability '{0}' for this VM size in this region." -f [string]$CapabilityLabel) }
        'nested-capability-not-advertised' { return ("Azure SKU metadata does not advertise any capability containing 'nested' for this VM size in this region.") }
        'nested-requires-standard-security' { return "Azure nested virtualization on this VM requires security type 'Standard' instead of 'TrustedLaunch'." }
        'nested-managed-by-security-type' { return 'Azure does not expose a separate nested virtualization toggle for this VM; availability is determined by VM size and security type.' }
        'nested-capability-inconclusive' { return 'Azure nested virtualization metadata is inconclusive. Guest OS validation is required after deployment.' }
        'hibernation-not-supported' {
            if ([string]::IsNullOrWhiteSpace([string]$evidenceText)) { return 'Azure SKU metadata reports hibernation as unsupported.' }
            return "Azure SKU metadata reports: $evidenceText."
        }
        'nested-not-supported' {
            if ([string]::IsNullOrWhiteSpace([string]$evidenceText)) { return 'Azure SKU metadata reports nested virtualization as unsupported.' }
            return "Azure SKU metadata reports: $evidenceText."
        }
        'hibernation-supported' {
            if ([string]::IsNullOrWhiteSpace([string]$evidenceText)) { return 'Azure SKU metadata reports hibernation support.' }
            return "Azure SKU metadata reports: $evidenceText."
        }
        'nested-supported' {
            if ([string]::IsNullOrWhiteSpace([string]$evidenceText)) { return 'Azure SKU metadata reports nested virtualization support.' }
            return "Azure SKU metadata reports: $evidenceText."
        }
        default { return ("{0} support metadata returned '{1}'." -f [string]$FeatureLabel, [string]$ReasonCode) }
    }
}

# Handles Get-AzVmHibernationSupportInfo.
function Get-AzVmHibernationSupportInfo {
    param(
        [string]$Location,
        [string]$VmSize
    )

    $snapshot = Get-AzVmVmSkuCapabilitySnapshot -Location $Location -VmSize $VmSize
    $result = [ordered]@{
        Known = [bool]$snapshot.Known
        Supported = $false
        Evidence = @()
        Message = [string]$snapshot.Message
        Family = [string]$snapshot.Family
    }

    if (-not [bool]$snapshot.Known) {
        return [pscustomobject]$result
    }

    $hibernationRows = @(
        @($snapshot.CapabilityRows) | Where-Object {
            [string]::Equals([string]$_.name, 'HibernationSupported', [System.StringComparison]::OrdinalIgnoreCase)
        }
    )
    if (@($hibernationRows).Count -eq 0) {
        $result.Known = $true
        $result.Message = 'hibernation-capability-not-advertised'
        return [pscustomobject]$result
    }

    $result.Evidence = @(
        @($hibernationRows) | ForEach-Object {
            "{0}={1}" -f [string]$_.name, [string]$_.value
        }
    )
    foreach ($hibernationRow in @($hibernationRows)) {
        $capValue = (Get-AzVmSafeTrimmedText -Value $hibernationRow.value).ToLowerInvariant()
        if ($capValue -in @('true', 'yes', 'supported', 'on', '1')) {
            $result.Supported = $true
            $result.Message = 'hibernation-supported'
            return [pscustomobject]$result
        }
    }

    $result.Message = 'hibernation-not-supported'
    return [pscustomobject]$result
}

# Handles Get-AzVmNestedVirtualizationSupportInfo.
function Get-AzVmNestedVirtualizationSupportInfo {
    param(
        [string]$Location,
        [string]$VmSize
    )

    $snapshot = Get-AzVmVmSkuCapabilitySnapshot -Location $Location -VmSize $VmSize
    $result = [ordered]@{
        Known = [bool]$snapshot.Known
        Supported = $false
        Evidence = @()
        Message = [string]$snapshot.Message
        Family = [string]$snapshot.Family
    }

    if (-not [bool]$snapshot.Known) {
        return [pscustomobject]$result
    }

    $capabilities = @(
        @($snapshot.CapabilityRows) | Where-Object {
            $capName = [string]$_.name
            -not [string]::IsNullOrWhiteSpace([string]$capName) -and $capName.ToLowerInvariant().Contains('nested')
        }
    )
    if (@($capabilities).Count -eq 0) {
        $result.Known = $false
        $result.Message = 'nested-capability-inconclusive'
        return [pscustomobject]$result
    }

    $result.Evidence = @(
        @($capabilities) | ForEach-Object {
            "{0}={1}" -f [string]$_.name, [string]$_.value
        }
    )

    foreach ($capability in @($capabilities)) {
        $capValue = (Get-AzVmSafeTrimmedText -Value $capability.value).ToLowerInvariant()
        if ($capValue -in @('true', 'yes', 'supported', 'on', '1')) {
            $result.Supported = $true
            $result.Message = 'nested-supported'
            return [pscustomobject]$result
        }
    }

    $result.Message = 'nested-not-supported'
    return [pscustomobject]$result
}

# Handles Ensure-AzVmDeallocatedForFeatureUpdate.
function Ensure-AzVmDeallocatedForFeatureUpdate {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [ref]$DeallocatedFlag
    )

    if ($DeallocatedFlag.Value) {
        return
    }

    Invoke-TrackedAction -Label ("az vm deallocate -g {0} -n {1}" -f $ResourceGroup, $VmName) -Action {
        az vm deallocate -g $ResourceGroup -n $VmName -o none --only-show-errors
        Assert-LastExitCode "az vm deallocate"
    } | Out-Null
    $DeallocatedFlag.Value = $true
}

# Handles Get-AzVmVmAdditionalCapabilityFlag.
function Get-AzVmVmAdditionalCapabilityFlag {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$QueryPath
    )

    $rawValue = az vm show -g $ResourceGroup -n $VmName --query $QueryPath -o tsv --only-show-errors 2>$null
    $querySucceeded = ($LASTEXITCODE -eq 0)
    $stateText = Get-AzVmSafeTrimmedText -Value $rawValue

    return [pscustomobject]@{
        Known = [bool]$querySucceeded
        RawValue = [string]$stateText
        Enabled = ($querySucceeded -and [string]::Equals([string]$stateText, 'true', [System.StringComparison]::OrdinalIgnoreCase))
    }
}

# Handles Wait-AzVmProvisioningSucceeded.
function Wait-AzVmProvisioningSucceeded {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [int]$MaxAttempts = 24,
        [int]$DelaySeconds = 10
    )

    $lastSnapshot = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $snapshotJson = az vm get-instance-view -g $ResourceGroup -n $VmName --query "{provisioningCode:statuses[?starts_with(code,'ProvisioningState/')].code | [0],provisioningDisplay:statuses[?starts_with(code,'ProvisioningState/')].displayStatus | [0],powerCode:statuses[?starts_with(code,'PowerState/')].code | [0],powerDisplay:statuses[?starts_with(code,'PowerState/')].displayStatus | [0]}" -o json --only-show-errors 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$snapshotJson)) {
            $lastSnapshot = ConvertFrom-JsonCompat -InputObject $snapshotJson
            $provisioningCode = Get-AzVmSafeTrimmedText -Value $lastSnapshot.provisioningCode
            $provisioningDisplay = Get-AzVmSafeTrimmedText -Value $lastSnapshot.provisioningDisplay
            if ([string]::Equals([string]$provisioningCode, 'ProvisioningState/succeeded', [System.StringComparison]::OrdinalIgnoreCase) -or
                [string]::Equals([string]$provisioningDisplay, 'Provisioning succeeded', [System.StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{
                    Ready = $true
                    Snapshot = $lastSnapshot
                }
            }
        }

        if ($attempt -lt $MaxAttempts) {
            $statusText = if ($null -ne $lastSnapshot) {
                ("provisioning={0}; power={1}" -f (Get-AzVmSafeTrimmedText -Value $lastSnapshot.provisioningDisplay), (Get-AzVmSafeTrimmedText -Value $lastSnapshot.powerDisplay))
            }
            else {
                'instance view not ready'
            }

            Write-Host ("VM provisioning is not ready yet for '{0}' in group '{1}'. {2}. Retrying in {3}s (attempt {4}/{5})..." -f $VmName, $ResourceGroup, $statusText, $DelaySeconds, $attempt, $MaxAttempts) -ForegroundColor Yellow
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    return [pscustomobject]@{
        Ready = $false
        Snapshot = $lastSnapshot
    }
}

# Handles Invoke-AzVmPostDeployFeatureEnablement.
function Invoke-AzVmPostDeployFeatureEnablement {
    param(
        [hashtable]$Context,
        [switch]$VmCreatedThisRun
    )

    $resourceGroup = [string]$Context.ResourceGroup
    $vmName = [string]$Context.VmName
    $vmDiskName = [string]$Context.VmDiskName
    $deallocated = $false
    $hibernationAttempted = $false
    $hibernationEnabled = $false
    $hibernationMessage = ''
    $nestedAttempted = $false
    $nestedEnabled = $false
    $nestedMessage = ''
    $hibernationDesired = $true
    $nestedDesired = $true
    if ($Context.ContainsKey('VmEnableHibernation')) {
        $hibernationDesired = [bool]$Context.VmEnableHibernation
    }
    if ($Context.ContainsKey('VmEnableNestedVirtualization')) {
        $nestedDesired = [bool]$Context.VmEnableNestedVirtualization
    }
    $hibernationSupport = Get-AzVmHibernationSupportInfo -Location ([string]$Context.AzLocation) -VmSize ([string]$Context.VmSize)
    $nestedSupport = Get-AzVmNestedVirtualizationSupportInfo -Location ([string]$Context.AzLocation) -VmSize ([string]$Context.VmSize)
    $nestedSecurityState = Get-AzVmSafeTrimmedText -Value $Context.VmSecurityType
    $vmLifecycleLabel = if ($VmCreatedThisRun) { 'newly created' } else { 'existing' }
    Write-Host ("Post-deploy feature verification will run for the {0} VM '{1}'." -f $vmLifecycleLabel, $vmName) -ForegroundColor DarkCyan

    try {
        $provisioningWaitResult = Wait-AzVmProvisioningSucceeded -ResourceGroup $resourceGroup -VmName $vmName -MaxAttempts 30 -DelaySeconds 10
        if (-not [bool]$provisioningWaitResult.Ready) {
            $snapshot = $provisioningWaitResult.Snapshot
            $provisioningText = if ($null -ne $snapshot) { Get-AzVmSafeTrimmedText -Value $snapshot.provisioningDisplay } else { '(unknown)' }
            $powerText = if ($null -ne $snapshot) { Get-AzVmSafeTrimmedText -Value $snapshot.powerDisplay } else { '(unknown)' }
            Throw-FriendlyError `
                -Detail ("VM '{0}' in resource group '{1}' did not reach provisioning succeeded before feature verification. provisioning='{2}', power='{3}'." -f $vmName, $resourceGroup, $provisioningText, $powerText) `
                -Code 66 `
                -Summary "VM provisioning is not ready for feature verification." `
                -Hint "Wait until provisioning succeeds, then retry the create/update flow."
        }

        $securityProfileJson = az vm show -g $resourceGroup -n $vmName --query "{securityType:securityProfile.securityType,secureBoot:securityProfile.uefiSettings.secureBootEnabled,vTpm:securityProfile.uefiSettings.vTpmEnabled}" -o json --only-show-errors 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$securityProfileJson)) {
            $securityProfile = ConvertFrom-JsonCompat -InputObject $securityProfileJson
            Write-Host ("VM security profile: SecurityType={0}, SecureBoot={1}, vTPM={2}" -f [string]$securityProfile.securityType, [string]$securityProfile.secureBoot, [string]$securityProfile.vTpm) -ForegroundColor DarkCyan
            $resolvedSecurityType = Get-AzVmSafeTrimmedText -Value $securityProfile.securityType
            if (-not [string]::IsNullOrWhiteSpace([string]$resolvedSecurityType)) {
                $nestedSecurityState = $resolvedSecurityType
            }
        }
    }
    catch {
    }

    try {
        if (-not $hibernationDesired) {
            $hibernationMessage = 'disabled-by-config'
            Write-Host ("Hibernation enablement is disabled by VM_ENABLE_HIBERNATION=false for VM '{0}'." -f $vmName) -ForegroundColor DarkCyan
        }
        else {
            $hibernationAttempted = $true
            $hibernationSupportReason = Resolve-AzVmFeatureSupportReasonText -FeatureLabel 'Hibernation' -CapabilityLabel 'HibernationSupported' -ReasonCode ([string]$hibernationSupport.Message) -Evidence @($hibernationSupport.Evidence)
            if ([bool]$hibernationSupport.Known -and [bool]$hibernationSupport.Supported) {
                Write-Host ("Hibernation is supported for VM size '{0}'. {1}" -f [string]$Context.VmSize, $hibernationSupportReason) -ForegroundColor DarkCyan
            }
            elseif ([bool]$hibernationSupport.Known) {
                Throw-FriendlyError `
                    -Detail ("VM_ENABLE_HIBERNATION=true requires Azure hibernation support for VM '{0}', but VM size '{1}' did not advertise support. {2}" -f $vmName, [string]$Context.VmSize, $hibernationSupportReason) `
                    -Code 66 `
                    -Summary "Hibernation could not be enabled." `
                    -Hint "Use a VM size that supports hibernation, or set VM_ENABLE_HIBERNATION=false before retrying."
            }
            else {
                Write-Host ("Hibernation capability metadata is inconclusive for VM size '{0}'. Azure verification will be attempted. {1}" -f [string]$Context.VmSize, $hibernationSupportReason) -ForegroundColor Yellow
            }

            $hibernationState = Get-AzVmVmAdditionalCapabilityFlag -ResourceGroup $resourceGroup -VmName $vmName -QueryPath 'additionalCapabilities.hibernationEnabled'
            if ([bool]$hibernationState.Enabled) {
                Write-Host ("Hibernation is already enabled on VM '{0}'." -f $vmName) -ForegroundColor Green
                $hibernationEnabled = $true
                $hibernationMessage = 'already-enabled'
            }
            else {
                Ensure-AzVmDeallocatedForFeatureUpdate -ResourceGroup $resourceGroup -VmName $vmName -DeallocatedFlag ([ref]$deallocated)

                Invoke-TrackedAction -Label ("az disk update -g {0} -n {1} --set supportsHibernation=true" -f $resourceGroup, $vmDiskName) -Action {
                    az disk update -g $resourceGroup -n $vmDiskName --set supportsHibernation=true -o none --only-show-errors
                    Assert-LastExitCode "az disk update --set supportsHibernation=true"
                } | Out-Null

                Invoke-TrackedAction -Label ("az vm update -g {0} -n {1} --enable-hibernation true" -f $resourceGroup, $vmName) -Action {
                    az vm update -g $resourceGroup -n $vmName --enable-hibernation true -o none --only-show-errors
                    Assert-LastExitCode "az vm update --enable-hibernation true"
                } | Out-Null

                $hibernationStateAfter = Get-AzVmVmAdditionalCapabilityFlag -ResourceGroup $resourceGroup -VmName $vmName -QueryPath 'additionalCapabilities.hibernationEnabled'
                if ([bool]$hibernationStateAfter.Enabled) {
                    $hibernationEnabled = $true
                    $hibernationMessage = 'enabled'
                    Write-Host ("Hibernation was enabled on VM '{0}'." -f $vmName) -ForegroundColor Green
                }
                else {
                    $hibernationMessage = if ([bool]$hibernationStateAfter.Known) { "Azure reported hibernationEnabled='{0}' after the update command." -f [string]$hibernationStateAfter.RawValue } else { 'Azure could not report hibernationEnabled after the update command.' }
                    Throw-FriendlyError `
                        -Detail ("Hibernation verification failed for VM '{0}'. {1}" -f $vmName, $hibernationMessage) `
                        -Code 66 `
                        -Summary "Hibernation could not be enabled." `
                        -Hint "Check Azure VM and disk feature support, then retry the create/update flow."
                }
            }
        }

        if (-not $nestedDesired) {
            $nestedMessage = 'disabled-by-config'
            Write-Host ("Nested virtualization enablement is disabled by VM_ENABLE_NESTED_VIRTUALIZATION=false for VM '{0}'." -f $vmName) -ForegroundColor DarkCyan
        }
        else {
            $nestedAttempted = $true
            if ([string]::Equals([string]$nestedSecurityState, 'TrustedLaunch', [System.StringComparison]::OrdinalIgnoreCase)) {
                $nestedMessage = 'nested-requires-standard-security'
                Throw-FriendlyError `
                    -Detail ("VM_ENABLE_NESTED_VIRTUALIZATION=true requires security type 'Standard', but VM '{0}' currently reports security type '{1}'. {2}" -f $vmName, [string]$nestedSecurityState, (Resolve-AzVmFeatureSupportReasonText -FeatureLabel 'Nested virtualization' -CapabilityLabel 'nested' -ReasonCode $nestedMessage -Evidence @($nestedSupport.Evidence))) `
                    -Code 66 `
                    -Summary "Nested virtualization could not be enabled." `
                    -Hint "Use VM_SECURITY_TYPE=Standard for this VM and retry."
            }

            $nestedSupportReason = Resolve-AzVmFeatureSupportReasonText -FeatureLabel 'Nested virtualization' -CapabilityLabel 'nested' -ReasonCode ([string]$nestedSupport.Message) -Evidence @($nestedSupport.Evidence)
            if ([bool]$nestedSupport.Known -and [bool]$nestedSupport.Supported) {
                Write-Host ("Nested virtualization is supported for VM size '{0}'. {1}" -f [string]$Context.VmSize, $nestedSupportReason) -ForegroundColor DarkCyan
            }
            elseif ([bool]$nestedSupport.Known) {
                $nestedMessage = [string]$nestedSupport.Message
                Throw-FriendlyError `
                    -Detail ("VM_ENABLE_NESTED_VIRTUALIZATION=true requires Azure nested virtualization support for VM '{0}', but VM size '{1}' did not advertise support. {2}" -f $vmName, [string]$Context.VmSize, $nestedSupportReason) `
                    -Code 66 `
                    -Summary "Nested virtualization could not be enabled." `
                    -Hint "Use a VM size that supports nested virtualization, or set VM_ENABLE_NESTED_VIRTUALIZATION=false before retrying."
            }
            else {
                $nestedMessage = 'nested-capability-inconclusive'
                Write-Host ("Nested virtualization capability metadata is inconclusive for VM size '{0}'. Guest validation will be attempted. {1}" -f [string]$Context.VmSize, $nestedSupportReason) -ForegroundColor Yellow
            }
        }

        if ($nestedAttempted) {
            if ($deallocated) {
                Invoke-TrackedAction -Label ("az vm start -g {0} -n {1}" -f $resourceGroup, $vmName) -Action {
                    az vm start -g $resourceGroup -n $vmName -o none --only-show-errors
                    Assert-LastExitCode "az vm start"
                } | Out-Null
                $deallocated = $false
                Write-Host ("VM '{0}' was started before nested virtualization guest validation." -f $vmName) -ForegroundColor DarkCyan
            }

            $nestedValidation = Get-AzVmNestedVirtualizationGuestValidation `
                -ResourceGroup $resourceGroup `
                -VmName $vmName `
                -OsType ([string]$Context.VmOsType) `
                -MaxAttempts 8 `
                -RetryDelaySeconds 20

            if ([bool]$nestedValidation.Known -and [bool]$nestedValidation.Enabled) {
                $nestedEnabled = $true
                $nestedMessage = 'guest-validated'
                Write-Host ("Nested virtualization guest validation passed for VM '{0}'. {1}" -f $vmName, ((@($nestedValidation.Evidence) -join '; '))) -ForegroundColor Green
            }
            else {
                $nestedEvidenceText = if (@($nestedValidation.Evidence).Count -gt 0) { (@($nestedValidation.Evidence) -join '; ') } else { [string]$nestedValidation.ErrorMessage }
                Throw-FriendlyError `
                    -Detail ("Nested virtualization guest validation failed for VM '{0}'. {1}" -f $vmName, [string]$nestedEvidenceText) `
                    -Code 66 `
                    -Summary "Nested virtualization could not be enabled." `
                    -Hint "Check the VM size, security type, and guest virtualization requirements, then retry the create/update flow."
            }
        }
    }
    finally {
        if ($deallocated) {
            try {
                Invoke-TrackedAction -Label ("az vm start -g {0} -n {1}" -f $resourceGroup, $vmName) -Action {
                    az vm start -g $resourceGroup -n $vmName -o none --only-show-errors
                    Assert-LastExitCode "az vm start"
                } | Out-Null
                Write-Host ("VM '{0}' was started after feature enablement." -f $vmName) -ForegroundColor DarkCyan
            }
            catch {
                Write-Warning ("VM '{0}' could not be started after feature enablement: {1}" -f $vmName, $_.Exception.Message)
            }
        }
    }

    return [pscustomobject]@{
        HibernationAttempted = [bool]$hibernationAttempted
        HibernationEnabled = [bool]$hibernationEnabled
        HibernationMessage = [string]$hibernationMessage
        NestedAttempted = [bool]$nestedAttempted
        NestedEnabled = [bool]$nestedEnabled
        NestedMessage = [string]$nestedMessage
    }
}

# Handles Invoke-AzVmResourceGroupStep.
function Invoke-AzVmResourceGroupStep {
    param(
        [hashtable]$Context,
        [switch]$AutoMode,
        [switch]$UpdateMode,
        [ValidateSet("default","update","destructive rebuild")]
        [string]$ExecutionMode = "default"
    )

    $resourceGroup = [string]$Context.ResourceGroup
    $azLocation = [string]$Context.AzLocation
    if ([string]::IsNullOrWhiteSpace([string]$azLocation)) {
        Throw-FriendlyError `
            -Detail "AZ_LOCATION is empty. Resource group creation cannot continue without a region." `
            -Code 22 `
            -Summary "Azure region is required before resource group creation." `
            -Hint "Set AZ_LOCATION in .env or complete interactive region selection."
    }

    $effectiveMode = if ([string]::IsNullOrWhiteSpace([string]$ExecutionMode)) { "default" } else { [string]$ExecutionMode.Trim().ToLowerInvariant() }
    Show-AzVmStepFirstUseValues `
        -StepLabel "Step 2/7 - resource group check" `
        -Context $Context `
        -Keys @("ResourceGroup", "AzLocation") `
        -ExtraValues @{
            ResourceExecutionMode = $effectiveMode
        }
    Write-Host "'$resourceGroup'"
    $resourceExists = az group exists -n $resourceGroup --only-show-errors
    Assert-LastExitCode "az group exists"
    $resourceExistsBool = [string]::Equals([string]$resourceExists, "true", [System.StringComparison]::OrdinalIgnoreCase)
    $shouldCreateResourceGroup = $true

    switch ($effectiveMode) {
        "default" {
            if ($resourceExistsBool) {
                Write-Host "Default mode: existing resource group '$resourceGroup' will be kept; create step is skipped." -ForegroundColor Yellow
                $shouldCreateResourceGroup = $false
            }
        }
        "update" {
            if ($resourceExistsBool) {
                Write-Host "Update mode: existing resource group '$resourceGroup' will be kept; create-or-update command will run." -ForegroundColor Yellow
            }
        }
        "destructive rebuild" {
            if ($resourceExistsBool) {
                Write-Host "destructive rebuild mode: resource group '$resourceGroup' exists and can be deleted before recreate."
                $shouldDelete = $true
                if ($AutoMode) {
                    Write-Host "Auto mode: deletion was confirmed automatically."
                }
                else {
                    $shouldDelete = Confirm-YesNo -PromptText "Are you sure you want to delete resource group '$resourceGroup'?" -DefaultYes $false
                }

                if ($shouldDelete) {
                    Invoke-TrackedAction -Label "az group delete -n $resourceGroup --yes --no-wait" -Action {
                        az group delete -n $resourceGroup --yes --no-wait
                        Assert-LastExitCode "az group delete"
                    } | Out-Null
                    Invoke-TrackedAction -Label "az group wait -n $resourceGroup --deleted" -Action {
                        az group wait -n $resourceGroup --deleted
                        Assert-LastExitCode "az group wait deleted"
                    } | Out-Null
                    Write-Host "Resource group '$resourceGroup' was deleted."
                }
                else {
                    Write-Host "Resource group '$resourceGroup' was not deleted by user choice; continuing with recreate command." -ForegroundColor Yellow
                }
            }
        }
    }

    if (-not $shouldCreateResourceGroup) {
        Set-AzVmManagedTagOnResourceGroup -ResourceGroup $resourceGroup
        return
    }

    Write-Host "Creating resource group '$resourceGroup'..."
    $groupCreateSucceeded = $false
    $groupCreateAttempts = 12
    $groupCreateDelaySeconds = 10
    for ($groupCreateAttempt = 1; $groupCreateAttempt -le $groupCreateAttempts; $groupCreateAttempt++) {
        $attemptLabel = "az group create -n $resourceGroup -l $($Context.AzLocation)"
        if ($groupCreateAttempts -gt 1) {
            $attemptLabel = "$attemptLabel (attempt $groupCreateAttempt/$groupCreateAttempts)"
        }

        $groupCreateOutput = Invoke-TrackedAction -Label $attemptLabel -Action {
            az group create -n $resourceGroup -l $Context.AzLocation --tags ("{0}={1}" -f [string]$script:ManagedByTagKey, [string]$script:ManagedByTagValue) -o json 2>&1
        }
        $groupCreateExitCode = [int]$LASTEXITCODE
        if ($groupCreateExitCode -eq 0) {
            $groupCreateSucceeded = $true
            break
        }

        $groupCreateText = (@($groupCreateOutput) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        $isGroupBeingDeleted = ($groupCreateText -match '(?i)(ResourceGroupBeingDeleted|deprovisioning state)')
        if ($isGroupBeingDeleted -and $groupCreateAttempt -lt $groupCreateAttempts) {
            Write-Host ("Resource group '{0}' is still deprovisioning. Retrying in {1}s..." -f $resourceGroup, $groupCreateDelaySeconds) -ForegroundColor Yellow
            Start-Sleep -Seconds $groupCreateDelaySeconds
            continue
        }

        throw "az group create failed with exit code $groupCreateExitCode."
    }

    if (-not $groupCreateSucceeded) {
        throw "az group create failed because resource group '$resourceGroup' did not become ready in time."
    }

    Set-AzVmManagedTagOnResourceGroup -ResourceGroup $resourceGroup
}

# Handles Test-AzVmAzResourceExists.
function Test-AzVmAzResourceExists {
    param(
        [string[]]$AzArgs
    )

    $null = Invoke-AzVmWithSuppressedAzCliStderr -Action {
        az @AzArgs --only-show-errors -o none
    }
    return ($LASTEXITCODE -eq 0)
}

# Handles Test-AzVmResourceGroupExists.
function Test-AzVmResourceGroupExists {
    param(
        [string]$ResourceGroup
    )

    if ([string]::IsNullOrWhiteSpace([string]$ResourceGroup)) {
        return $false
    }

    $existsRaw = az group exists -n ([string]$ResourceGroup) --only-show-errors
    Assert-LastExitCode "az group exists"
    return [string]::Equals([string]$existsRaw, "true", [System.StringComparison]::OrdinalIgnoreCase)
}

# Handles Get-AzVmManagedResourceGroupRows.
function Get-AzVmManagedResourceGroupRows {
    $tagFilter = ("{0}={1}" -f [string]$script:ManagedByTagKey, [string]$script:ManagedByTagValue)
    $rows = az group list --tag $tagFilter -o json --only-show-errors
    Assert-LastExitCode "az group list (managed-by filter)"
    return @(ConvertFrom-JsonArrayCompat -InputObject $rows)
}

# Handles Test-AzVmResourceGroupManaged.
function Test-AzVmResourceGroupManaged {
    param(
        [string]$ResourceGroup
    )

    if ([string]::IsNullOrWhiteSpace([string]$ResourceGroup)) {
        return $false
    }

    $groupJson = az group show -n ([string]$ResourceGroup) -o json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$groupJson)) {
        return $false
    }

    $groupObj = ConvertFrom-JsonCompat -InputObject $groupJson
    if (-not $groupObj -or -not $groupObj.tags) {
        return $false
    }

    $tagValue = ''
    if ($groupObj.tags.PSObject.Properties.Match([string]$script:ManagedByTagKey).Count -gt 0) {
        $tagValue = [string]$groupObj.tags.([string]$script:ManagedByTagKey)
    }
    return [string]::Equals(([string]$tagValue).Trim(), [string]$script:ManagedByTagValue, [System.StringComparison]::OrdinalIgnoreCase)
}

# Handles Assert-AzVmManagedResourceGroup.
function Assert-AzVmManagedResourceGroup {
    param(
        [string]$ResourceGroup,
        [string]$OperationName = 'operation'
    )

    if (-not (Test-AzVmResourceGroupExists -ResourceGroup $ResourceGroup)) {
        Throw-FriendlyError `
            -Detail ("Resource group '{0}' was not found." -f $ResourceGroup) `
            -Code 61 `
            -Summary ("Resource group check failed before {0}." -f $OperationName) `
            -Hint "Provide a valid resource group name and verify Azure subscription context."
    }

    if (-not (Test-AzVmResourceGroupManaged -ResourceGroup $ResourceGroup)) {
        Throw-FriendlyError `
            -Detail ("Resource group '{0}' is not managed by this application (required tag: {1}={2})." -f $ResourceGroup, [string]$script:ManagedByTagKey, [string]$script:ManagedByTagValue) `
            -Code 61 `
            -Summary ("Resource group is outside az-vm managed scope for {0}." -f $OperationName) `
            -Hint ("Use a resource group tagged with {0}={1}, or run create to generate managed resources." -f [string]$script:ManagedByTagKey, [string]$script:ManagedByTagValue)
    }
}

# Handles Set-AzVmManagedTagOnResourceGroup.
function Set-AzVmManagedTagOnResourceGroup {
    param(
        [string]$ResourceGroup
    )

    if ([string]::IsNullOrWhiteSpace([string]$ResourceGroup)) {
        return
    }

    $groupJson = az group show -n $ResourceGroup -o json --only-show-errors
    Assert-LastExitCode "az group show (tag merge)"
    $groupObj = ConvertFrom-JsonCompat -InputObject $groupJson

    $merged = [ordered]@{}
    if ($groupObj -and $groupObj.tags) {
        foreach ($prop in @($groupObj.tags.PSObject.Properties)) {
            $merged[[string]$prop.Name] = [string]$prop.Value
        }
    }
    $merged[[string]$script:ManagedByTagKey] = [string]$script:ManagedByTagValue
    $tagArgs = @()
    foreach ($key in @($merged.Keys)) {
        $tagArgs += ("{0}={1}" -f [string]$key, [string]$merged[$key])
    }

    Invoke-TrackedAction -Label ("az group update -n {0} --tags ..." -f $ResourceGroup) -Action {
        $groupUpdateArgs = @("group", "update", "-n", [string]$ResourceGroup, "--tags")
        $groupUpdateArgs += @($tagArgs)
        $groupUpdateArgs += @("-o", "none", "--only-show-errors")
        az @groupUpdateArgs
        Assert-LastExitCode "az group update (managed-by tag)"
    } | Out-Null
}

# Handles Test-AzVmAzResourceExistsByType.
function Test-AzVmAzResourceExistsByType {
    param(
        [string]$ResourceGroup,
        [string]$ResourceType,
        [string]$ResourceName
    )

    if ([string]::IsNullOrWhiteSpace([string]$ResourceGroup) -or [string]::IsNullOrWhiteSpace([string]$ResourceType) -or [string]::IsNullOrWhiteSpace([string]$ResourceName)) {
        return $false
    }

    $namesJson = az resource list -g ([string]$ResourceGroup) --resource-type ([string]$ResourceType) --query "[].name" -o json --only-show-errors
    Assert-LastExitCode ("az resource list ({0})" -f [string]$ResourceType)
    $names = @(
        ConvertFrom-JsonArrayCompat -InputObject $namesJson |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    foreach ($name in $names) {
        if ([string]::Equals([string]$name, [string]$ResourceName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

# Handles Test-AzVmNsgRuleExists.
function Test-AzVmNsgRuleExists {
    param(
        [string]$ResourceGroup,
        [string]$NsgName,
        [string]$RuleName
    )

    if ([string]::IsNullOrWhiteSpace([string]$ResourceGroup) -or [string]::IsNullOrWhiteSpace([string]$NsgName) -or [string]::IsNullOrWhiteSpace([string]$RuleName)) {
        return $false
    }

    $namesJson = az network nsg rule list -g ([string]$ResourceGroup) --nsg-name ([string]$NsgName) --query "[].name" -o json --only-show-errors
    Assert-LastExitCode "az network nsg rule list"
    $names = @(
        ConvertFrom-JsonArrayCompat -InputObject $namesJson |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    foreach ($name in $names) {
        if ([string]::Equals([string]$name, [string]$RuleName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

# Handles Ensure-AzVmResourceGroupReady.
function Ensure-AzVmResourceGroupReady {
    param(
        [hashtable]$Context
    )

    $resourceGroup = [string]$Context.ResourceGroup
    if ([string]::IsNullOrWhiteSpace([string]$resourceGroup)) {
        throw "ResourceGroup is required for Ensure-AzVmResourceGroupReady."
    }

    $exists = Test-AzVmResourceGroupExists -ResourceGroup $resourceGroup
    if ($exists) {
        Set-AzVmManagedTagOnResourceGroup -ResourceGroup $resourceGroup
        return
    }

    Invoke-TrackedAction -Label ("az group create -n {0} -l {1}" -f $resourceGroup, [string]$Context.AzLocation) -Action {
        az group create -n $resourceGroup -l $Context.AzLocation --tags ("{0}={1}" -f [string]$script:ManagedByTagKey, [string]$script:ManagedByTagValue) -o none --only-show-errors
        Assert-LastExitCode "az group create (ensure)"
    } | Out-Null

    Set-AzVmManagedTagOnResourceGroup -ResourceGroup $resourceGroup
}

# Handles Assert-AzVmSingleActionDependencies.
function Assert-AzVmSingleActionDependencies {
    param(
        [ValidateSet('configure','group','network','vm-deploy','vm-init','vm-update','vm-summary')]
        [string]$ActionName,
        [hashtable]$Context
    )

    if ($ActionName -in @('configure', 'group')) {
        return
    }

    $resourceGroup = [string]$Context.ResourceGroup
    $vmName = [string]$Context.VmName

    if ($ActionName -eq 'network') {
        $groupExists = az group exists -n $resourceGroup
        Assert-LastExitCode "az group exists"
        $groupExistsBool = [string]::Equals([string]$groupExists, "true", [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $groupExistsBool) {
            Throw-FriendlyError `
                -Detail ("single-step '{0}' requires existing resource group '{1}', but it was not found." -f $ActionName, $resourceGroup) `
                -Code 63 `
                -Summary "Step dependency is missing." `
                -Hint "Run create/update with --single-step=group first, or run with --to-step=network."
        }
        return
    }

    if ($ActionName -eq 'vm-deploy') {
        $groupExists = az group exists -n $resourceGroup
        Assert-LastExitCode "az group exists"
        $groupExistsBool = [string]::Equals([string]$groupExists, "true", [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $groupExistsBool) {
            Throw-FriendlyError `
                -Detail ("single-step '{0}' requires existing resource group '{1}', but it was not found." -f $ActionName, $resourceGroup) `
                -Code 63 `
                -Summary "Step dependency is missing." `
                -Hint "Run create/update with --single-step=group first."
        }

        $nicExists = Test-AzVmAzResourceExists -AzArgs @("network", "nic", "show", "-g", $resourceGroup, "-n", [string]$Context.NIC)
        if (-not $nicExists) {
            Throw-FriendlyError `
                -Detail ("single-step '{0}' requires existing NIC '{1}', but it was not found." -f $ActionName, [string]$Context.NIC) `
                -Code 63 `
                -Summary "Step dependency is missing." `
                -Hint "Run create/update with --single-step=network first."
        }
        return
    }

    if ($ActionName -in @('vm-init', 'vm-update', 'vm-summary')) {
        $vmExists = Test-AzVmAzResourceExists -AzArgs @("vm", "show", "-g", $resourceGroup, "-n", $vmName)
        if (-not $vmExists) {
            Throw-FriendlyError `
                -Detail ("single-step '{0}' requires existing VM '{1}', but it was not found." -f $ActionName, $vmName) `
                -Code 63 `
                -Summary "Step dependency is missing." `
                -Hint "Run create/update with --single-step=vm-deploy first."
        }
        return
    }
}

# Handles Invoke-AzVmNetworkStep.
function Invoke-AzVmNetworkStep {
    param(
        [hashtable]$Context,
        [ValidateSet("default","update","destructive rebuild")]
        [string]$ExecutionMode = "default"
    )

    $effectiveMode = if ([string]::IsNullOrWhiteSpace([string]$ExecutionMode)) { "default" } else { [string]$ExecutionMode.Trim().ToLowerInvariant() }
    $alwaysCreate = ($effectiveMode -in @("update","destructive rebuild"))
    Show-AzVmStepFirstUseValues `
        -StepLabel "Step 3/7 - network provisioning" `
        -Context $Context `
        -Keys @("ResourceGroup", "VNET", "SUBNET", "NSG", "NsgRule", "IP", "NIC", "TcpPorts") `
        -ExtraValues @{
            NetworkExecutionMode = $effectiveMode
        }

    $resourceGroupName = [string]$Context.ResourceGroup
    $groupExistsBeforeNetwork = Test-AzVmResourceGroupExists -ResourceGroup $resourceGroupName
    if (-not $groupExistsBeforeNetwork) {
        Write-Host ("Resource group '{0}' was not found before network step; it will be created now." -f $resourceGroupName) -ForegroundColor Yellow
        Ensure-AzVmResourceGroupReady -Context $Context
    }

    $createVnet = $alwaysCreate
    if (-not $alwaysCreate) {
        $createVnet = -not (Test-AzVmAzResourceExistsByType -ResourceGroup ([string]$Context.ResourceGroup) -ResourceType "Microsoft.Network/virtualNetworks" -ResourceName ([string]$Context.VNET))
        if (-not $createVnet) {
            Write-Host ("Default mode: VNet '{0}' exists; create command is skipped." -f [string]$Context.VNET) -ForegroundColor Yellow
        }
    }
    if ($createVnet) {
        Invoke-TrackedAction -Label "az network vnet create -g $($Context.ResourceGroup) -n $($Context.VNET)" -Action {
            az network vnet create -g $Context.ResourceGroup -n $Context.VNET --address-prefix 10.20.0.0/16 `
                --subnet-name $Context.SUBNET --subnet-prefix 10.20.0.0/24 -o table
            Assert-LastExitCode "az network vnet create"
        } | Out-Null
    }

    $createNsg = $alwaysCreate
    if (-not $alwaysCreate) {
        $createNsg = -not (Test-AzVmAzResourceExistsByType -ResourceGroup ([string]$Context.ResourceGroup) -ResourceType "Microsoft.Network/networkSecurityGroups" -ResourceName ([string]$Context.NSG))
        if (-not $createNsg) {
            Write-Host ("Default mode: NSG '{0}' exists; create command is skipped." -f [string]$Context.NSG) -ForegroundColor Yellow
        }
    }
    if ($createNsg) {
        Invoke-TrackedAction -Label "az network nsg create -g $($Context.ResourceGroup) -n $($Context.NSG)" -Action {
            az network nsg create -g $Context.ResourceGroup -n $Context.NSG -o table
            Assert-LastExitCode "az network nsg create"
        } | Out-Null
    }

    $priority = 101
    $ports = @($Context.TcpPorts)
    $createNsgRule = $alwaysCreate
    if (-not $alwaysCreate) {
        $createNsgRule = -not (Test-AzVmNsgRuleExists -ResourceGroup ([string]$Context.ResourceGroup) -NsgName ([string]$Context.NSG) -RuleName ([string]$Context.NsgRule))
        if (-not $createNsgRule) {
            Write-Host ("Default mode: NSG rule '{0}' exists; create command is skipped." -f [string]$Context.NsgRule) -ForegroundColor Yellow
        }
    }
    if ($createNsgRule) {
        Invoke-TrackedAction -Label "az network nsg rule create -g $($Context.ResourceGroup) --nsg-name $($Context.NSG) --name $($Context.NsgRule)" -Action {
            $ruleArgs = @(
                "network", "nsg", "rule", "create",
                "-g", [string]$Context.ResourceGroup,
                "--nsg-name", [string]$Context.NSG,
                "--name", [string]$Context.NsgRule,
                "--priority", [string]$priority,
                "--direction", "Inbound",
                "--protocol", "Tcp",
                "--access", "Allow",
                "--destination-port-ranges"
            )
            $ruleArgs += @($ports | ForEach-Object { [string]$_ })
            $ruleArgs += @(
                "--source-address-prefixes", "*",
                "--source-port-ranges", "*",
                "-o", "table"
            )
            az @ruleArgs
            Assert-LastExitCode "az network nsg rule create"
        } | Out-Null
    }

    $createPublicIp = $alwaysCreate
    if (-not $alwaysCreate) {
        $createPublicIp = -not (Test-AzVmAzResourceExistsByType -ResourceGroup ([string]$Context.ResourceGroup) -ResourceType "Microsoft.Network/publicIPAddresses" -ResourceName ([string]$Context.IP))
        if (-not $createPublicIp) {
            Write-Host ("Default mode: public IP '{0}' exists; create command is skipped." -f [string]$Context.IP) -ForegroundColor Yellow
        }
    }
    if ($createPublicIp) {
        Write-Host "Creating public IP '$($Context.IP)'..."
        Invoke-TrackedAction -Label "az network public-ip create -g $($Context.ResourceGroup) -n $($Context.IP)" -Action {
            $publicIpCreateArgs = @(
                "network", "public-ip", "create",
                "-g", [string]$Context.ResourceGroup,
                "-n", [string]$Context.IP,
                "--allocation-method", "Static",
                "--sku", "Standard",
                "--dns-name", [string]$Context.VmName
            )
            $publicIpCreateArgs += @(Get-AzVmPublicIpZoneArgs -Location ([string]$Context.AzLocation))
            $publicIpCreateArgs += @("-o", "table")
            az @publicIpCreateArgs
            Assert-LastExitCode "az network public-ip create"
        } | Out-Null
    }

    $createNic = $alwaysCreate
    if (-not $alwaysCreate) {
        $createNic = -not (Test-AzVmAzResourceExistsByType -ResourceGroup ([string]$Context.ResourceGroup) -ResourceType "Microsoft.Network/networkInterfaces" -ResourceName ([string]$Context.NIC))
        if (-not $createNic) {
            Write-Host ("Default mode: NIC '{0}' exists; create command is skipped." -f [string]$Context.NIC) -ForegroundColor Yellow
        }
    }
    if ($createNic) {
        Write-Host "Creating network NIC '$($Context.NIC)'..."
        Invoke-TrackedAction -Label "az network nic create -g $($Context.ResourceGroup) -n $($Context.NIC)" -Action {
            az network nic create -g $Context.ResourceGroup -n $Context.NIC --vnet-name $Context.VNET --subnet $Context.SUBNET `
                --network-security-group $Context.NSG `
                --public-ip-address $Context.IP `
                -o table
            Assert-LastExitCode "az network nic create"
        } | Out-Null
    }
}

# Handles Invoke-AzVmVmCreateStep.
function Invoke-AzVmVmCreateStep {
    param(
        [hashtable]$Context,
        [switch]$AutoMode,
        [switch]$UpdateMode,
        [ValidateSet("default","update","destructive rebuild")]
        [string]$ExecutionMode = "default",
        [scriptblock]$CreateVmAction
    )

    if (-not $CreateVmAction) {
        throw "CreateVmAction is required."
    }

    $resourceGroup = [string]$Context.ResourceGroup
    $effectiveMode = if ([string]::IsNullOrWhiteSpace([string]$ExecutionMode)) { "default" } else { [string]$ExecutionMode.Trim().ToLowerInvariant() }
    $vmName = [string]$Context.VmName
    Show-AzVmStepFirstUseValues `
        -StepLabel "Step 4/7 - VM create" `
        -Context $Context `
        -Keys @("ResourceGroup", "VmName", "VmImage", "VmSize", "VmStorageSku", "VmSecurityType", "VmEnableSecureBoot", "VmEnableVtpm", "VmDiskName", "VmDiskSize", "VmUser", "VmPass", "VmAssistantUser", "VmAssistantPass", "NIC") `
        -ExtraValues @{
            VmExecutionMode = $effectiveMode
        }

    $existingVM = az vm list `
        --resource-group $resourceGroup `
        --query "[?name=='$vmName'].name | [0]" `
        -o tsv `
        --only-show-errors 2>$null
    Assert-LastExitCode "az vm list"

    $hasExistingVm = -not [string]::IsNullOrWhiteSpace([string]$existingVM)
    $shouldDeleteVm = $false
    $shouldCreateVm = $true
    $vmDeletedInThisRun = $false
    if ($hasExistingVm) {
        Write-Host "VM '$vmName' exists in resource group '$resourceGroup'."

        switch ($effectiveMode) {
            "default" {
                $shouldCreateVm = $false
                Write-Host "Default mode: existing VM '$vmName' will be kept; create step is skipped." -ForegroundColor Yellow
            }
            "update" {
                Write-Host "Update mode: existing VM will be kept; az vm create will run in create-or-update mode." -ForegroundColor Yellow
            }
            "destructive rebuild" {
                if ($AutoMode) {
                    $shouldDeleteVm = $true
                    Write-Host "Auto mode: VM deletion was confirmed automatically."
                }
                else {
                    $shouldDeleteVm = Confirm-YesNo -PromptText "Are you sure you want to delete VM '$vmName'?" -DefaultYes $false
                }
            }
        }

        if ($shouldDeleteVm) {
            Write-Host "VM '$vmName' will be deleted..."
            Invoke-TrackedAction -Label "az vm delete --name $vmName --resource-group $resourceGroup --yes" -Action {
                az vm delete --name $vmName --resource-group $resourceGroup --yes -o table
                Assert-LastExitCode "az vm delete"
            } | Out-Null
            Write-Host "VM '$vmName' was deleted from resource group '$resourceGroup'."
            $vmDeletedInThisRun = $true
        }
        elseif ($effectiveMode -eq "destructive rebuild") {
            Write-Host "destructive rebuild mode: VM '$vmName' was not deleted by user choice; az vm create will run on existing VM." -ForegroundColor Yellow
        }
        elseif ($effectiveMode -ne "default") {
            Write-Host "VM '$vmName' was not deleted by user choice; continuing with az vm create on existing VM." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "VM '$vmName' is not present in resource group '$resourceGroup'. Creating..."
    }

    if (-not $shouldCreateVm) {
        return [pscustomobject]@{
            VmExistsBefore = [bool]$hasExistingVm
            VmDeleted = [bool]$vmDeletedInThisRun
            VmCreateInvoked = $false
            VmCreatedThisRun = $false
            VmId = ""
        }
    }

    $vmCreatedThisRun = (-not $hasExistingVm) -or $vmDeletedInThisRun
    $vmCreateJson = Invoke-TrackedAction -Label "az vm create --resource-group $resourceGroup --name $vmName" -Action {
        $result = & $CreateVmAction
        if ($LASTEXITCODE -ne 0) {
            $createExitCode = [int]$LASTEXITCODE
            $vmExistsAfterCreate = ""
            $shouldUseLongPresenceProbe = (($effectiveMode -in @("update","destructive rebuild")) -and $hasExistingVm)
            if (-not $shouldUseLongPresenceProbe) {
                throw "az vm create failed with exit code $createExitCode."
            }

            Write-Warning "az vm create returned a non-zero code; checking VM existence."
            $presenceProbeAttempts = if ($shouldUseLongPresenceProbe) { 12 } else { 3 }
            for ($presenceAttempt = 1; $presenceAttempt -le $presenceProbeAttempts; $presenceAttempt++) {
                $vmExistsAfterCreate = if (Test-AzVmAzResourceExists -AzArgs @("vm", "show", "-g", $resourceGroup, "-n", $vmName)) {
                    az vm show -g $resourceGroup -n $vmName --query "id" -o tsv --only-show-errors 2>$null
                }
                else {
                    ""
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$vmExistsAfterCreate)) {
                    break
                }

                if ($presenceAttempt -lt $presenceProbeAttempts) {
                    Write-Host ("VM existence probe attempt {0}/{1} did not resolve yet. Retrying in 10s..." -f $presenceAttempt, $presenceProbeAttempts) -ForegroundColor Yellow
                    Start-Sleep -Seconds 10
                }
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$vmExistsAfterCreate)) {
                Write-Host "VM exists; details will be retrieved via az vm show -d."
                $result = az vm show -g $resourceGroup -n $vmName -d -o json --only-show-errors 2>$null
                Assert-LastExitCode "az vm show -d after vm create non-zero"
            }
            else {
                throw "az vm create failed with exit code $createExitCode."
            }
        }

        $result
    }

    $vmCreateObj = ConvertFrom-JsonCompat -InputObject $vmCreateJson
    if (-not $vmCreateObj.id) {
        throw "az vm create completed but VM id was not returned."
    }

    Write-Host "Printing az vm create output..."
    Write-Host $vmCreateJson

    $featureEnablementResult = Invoke-AzVmPostDeployFeatureEnablement -Context $Context -VmCreatedThisRun:$vmCreatedThisRun

    return [pscustomobject]@{
        VmExistsBefore = [bool]$hasExistingVm
        VmDeleted = [bool]$vmDeletedInThisRun
        VmCreateInvoked = $true
        VmCreatedThisRun = [bool]$vmCreatedThisRun
        VmId = [string]$vmCreateObj.id
        HibernationAttempted = [bool]$featureEnablementResult.HibernationAttempted
        HibernationEnabled = [bool]$featureEnablementResult.HibernationEnabled
        HibernationMessage = [string]$featureEnablementResult.HibernationMessage
        NestedAttempted = [bool]$featureEnablementResult.NestedAttempted
        NestedEnabled = [bool]$featureEnablementResult.NestedEnabled
        NestedMessage = [string]$featureEnablementResult.NestedMessage
    }
}

# Handles Get-AzVmVmDetails.
function Get-AzVmVmDetails {
    param(
        [hashtable]$Context
    )

    Show-AzVmStepFirstUseValues `
        -StepLabel "VM details lookup" `
        -Context $Context `
        -Keys @("ResourceGroup", "VmName", "AzLocation", "SshPort")

    $vmDetailsJson = Invoke-TrackedAction -Label "az vm show -g $($Context.ResourceGroup) -n $($Context.VmName) -d" -Action {
        $result = az vm show -g $Context.ResourceGroup -n $Context.VmName -d -o json --only-show-errors 2>$null
        Assert-LastExitCode "az vm show -d"
        $result
    }

    $vmDetails = ConvertFrom-JsonCompat -InputObject $vmDetailsJson
    if (-not $vmDetails) {
        throw "VM detail output could not be parsed."
    }

    $publicIP = $vmDetails.publicIps
    $vmFqdn = $vmDetails.fqdns
    $effectiveLocation = [string]$Context.AzLocation
    if ([string]::IsNullOrWhiteSpace([string]$effectiveLocation)) {
        $effectiveLocation = [string]$vmDetails.location
    }
    if ([string]::IsNullOrWhiteSpace($vmFqdn)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$effectiveLocation)) {
            $vmFqdn = "$($Context.VmName).$effectiveLocation.cloudapp.azure.com"
        }
    }

    return [ordered]@{
        VmDetails = $vmDetails
        PublicIP = $publicIP
        VmFqdn = $vmFqdn
    }
}

# Handles Resolve-AzVmFriendlyError.
function Resolve-AzVmFriendlyError {
    param(
        [object]$ErrorRecord,
        [string]$DefaultErrorSummary,
        [string]$DefaultErrorHint
    )

    $errorMessage = [string]$ErrorRecord.Exception.Message
    $summary = $DefaultErrorSummary
    $hint = $DefaultErrorHint
    $code = 99

    if ($ErrorRecord.Exception.Data -and $ErrorRecord.Exception.Data.Contains("ExitCode")) {
        $code = [int]$ErrorRecord.Exception.Data["ExitCode"]
        if ($ErrorRecord.Exception.Data.Contains("Summary")) {
            $summary = [string]$ErrorRecord.Exception.Data["Summary"]
        }
        if ($ErrorRecord.Exception.Data.Contains("Hint")) {
            $hint = [string]$ErrorRecord.Exception.Data["Hint"]
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
        $summary = "A VM task failed."
        $hint = "Review the task name in the error detail and fix the related command."
        $code = 51
    }
    elseif ($errorMessage -match "^VM task batch execution failed") {
        $summary = "One or more tasks failed in auto mode."
        $hint = "Review the related task in the log file and fix the command."
        $code = 52
    }

    return [ordered]@{
        ErrorMessage = $errorMessage
        Summary = $summary
        Hint = $hint
        Code = $code
    }
}

# Handles ConvertTo-AzVmDisplayValue.
function ConvertTo-AzVmDisplayValue {
    param(
        [object]$Value
    )

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [string]) {
        return [string]$Value
    }

    if ($Value -is [System.Array]) {
        return ((@($Value) | ForEach-Object { [string]$_ }) -join ", ")
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $pairs = @()
        foreach ($key in @($Value.Keys | Sort-Object)) {
            $pairs += ("{0}={1}" -f [string]$key, (ConvertTo-AzVmDisplayValue -Value $Value[$key]))
        }
        return ($pairs -join "; ")
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        return ((@($Value) | ForEach-Object { [string]$_ }) -join ", ")
    }

    return [string]$Value
}

# Handles Get-AzVmFirstUseTracker.
function Get-AzVmFirstUseTracker {
    if (-not $script:AzVmFirstUseTracker) {
        $script:AzVmFirstUseTracker = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    }

    # Return as a single object even when empty; otherwise PowerShell may enumerate
    # an empty HashSet into $null and break method calls like .Contains().
    return (, $script:AzVmFirstUseTracker)
}

# Handles Get-AzVmValueStateTracker.
function Get-AzVmValueStateTracker {
    if (-not $script:AzVmValueStateTracker) {
        $script:AzVmValueStateTracker = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    }

    return (, $script:AzVmValueStateTracker)
}

# Handles Register-AzVmValueObservation.
function Register-AzVmValueObservation {
    param(
        [string]$Key,
        [object]$Value
    )

    $normalizedKey = [string]$Key
    if ([string]::IsNullOrWhiteSpace($normalizedKey)) {
        return [pscustomobject]@{
            Key = ""
            DisplayValue = ""
            ShouldPrint = $false
            IsFirst = $false
        }
    }

    $displayValue = ConvertTo-AzVmDisplayValue -Value $Value
    $valueState = Get-AzVmValueStateTracker
    $firstUseTracker = Get-AzVmFirstUseTracker

    $hasPrevious = $valueState.ContainsKey($normalizedKey)
    $previousValue = ""
    if ($hasPrevious) {
        $previousValue = [string]$valueState[$normalizedKey]
    }

    $shouldPrint = (-not $hasPrevious) -or (-not [string]::Equals($previousValue, [string]$displayValue, [System.StringComparison]::Ordinal))
    if ($shouldPrint) {
        $valueState[$normalizedKey] = [string]$displayValue
    }

    [void]$firstUseTracker.Add($normalizedKey)

    return [pscustomobject]@{
        Key = $normalizedKey
        DisplayValue = [string]$displayValue
        ShouldPrint = [bool]$shouldPrint
        IsFirst = [bool](-not $hasPrevious)
    }
}

# Handles Show-AzVmStepFirstUseValues.
function Show-AzVmStepFirstUseValues {
    param(
        [string]$StepLabel,
        [hashtable]$Context,
        [string[]]$Keys,
        [hashtable]$ExtraValues
    )

    $rows = @()
    $processed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($key in @($Keys)) {
        if ([string]::IsNullOrWhiteSpace([string]$key)) {
            continue
        }

        $normalizedKey = [string]$key
        if (-not $processed.Add($normalizedKey)) {
            continue
        }

        $value = $null
        $hasValue = $false
        if ($Context -and $Context.ContainsKey($normalizedKey)) {
            $value = $Context[$normalizedKey]
            $hasValue = $true
        }
        elseif ($ExtraValues -and $ExtraValues.ContainsKey($normalizedKey)) {
            $value = $ExtraValues[$normalizedKey]
            $hasValue = $true
        }

        if (-not $hasValue) {
            continue
        }

        $observed = Register-AzVmValueObservation -Key $normalizedKey -Value $value
        if ($observed.ShouldPrint) {
            $rows += [pscustomobject]@{
                Key = $observed.Key
                Value = $observed.DisplayValue
                IsFirst = $observed.IsFirst
            }
        }
    }

    if ($ExtraValues) {
        foreach ($extraKey in @($ExtraValues.Keys | Sort-Object)) {
            $normalizedKey = [string]$extraKey
            if ([string]::IsNullOrWhiteSpace($normalizedKey)) {
                continue
            }
            if (-not $processed.Add($normalizedKey)) {
                continue
            }

            $observed = Register-AzVmValueObservation -Key $normalizedKey -Value $ExtraValues[$extraKey]
            if ($observed.ShouldPrint) {
                $rows += [pscustomobject]@{
                    Key = $observed.Key
                    Value = $observed.DisplayValue
                    IsFirst = $observed.IsFirst
                }
            }
        }
    }

    if ($rows.Count -eq 0) {
        return
    }

    foreach ($row in @($rows)) {
        Write-Host ("- {0} = {1}" -f [string]$row.Key, [string]$row.Value)
    }
}

# Handles Get-AzVmAzAccountSnapshot.
function Get-AzVmAzAccountSnapshot {
    $snapshot = [ordered]@{
        SubscriptionName = ""
        SubscriptionId = ""
        TenantName = ""
        TenantId = ""
        UserName = ""
    }

    $accountResult = Invoke-AzVmAzCommandWithTimeout `
        -AzArgs @("account", "show", "-o", "json", "--only-show-errors") `
        -TimeoutSeconds 15
    if ($accountResult.TimedOut -or $accountResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$accountResult.Output)) {
        return $snapshot
    }

    $accountObj = ConvertFrom-JsonCompat -InputObject $accountResult.Output
    if (-not $accountObj) {
        return $snapshot
    }

    $snapshot.SubscriptionName = [string]$accountObj.name
    $snapshot.SubscriptionId = [string]$accountObj.id
    $snapshot.TenantId = [string]$accountObj.tenantId
    $snapshot.UserName = [string]$accountObj.user.name

    $tenantName = ""
    if (-not [string]::IsNullOrWhiteSpace($snapshot.TenantId)) {
        $tenantResult = Invoke-AzVmAzCommandWithTimeout `
            -AzArgs @("account", "tenant", "list", "-o", "json", "--only-show-errors") `
            -TimeoutSeconds 20
        if (-not $tenantResult.TimedOut -and $tenantResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$tenantResult.Output)) {
            $tenantList = ConvertFrom-JsonArrayCompat -InputObject $tenantResult.Output
            foreach ($tenant in @($tenantList)) {
                if ([string]$tenant.tenantId -ne $snapshot.TenantId) {
                    continue
                }

                $tenantName = [string]$tenant.displayName
                if ([string]::IsNullOrWhiteSpace($tenantName)) {
                    $tenantName = [string]$tenant.defaultDomain
                }
                if ([string]::IsNullOrWhiteSpace($tenantName)) {
                    $tenantName = [string]$tenant.tenantId
                }
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($tenantName)) {
        $tenantName = [string]$snapshot.TenantId
    }
    $snapshot.TenantName = $tenantName
    return $snapshot
}

# Handles Invoke-AzVmAzCommandWithTimeout.
function Invoke-AzVmAzCommandWithTimeout {
    param(
        [string[]]$AzArgs,
        [int]$TimeoutSeconds = 15
    )

    if (-not $AzArgs -or $AzArgs.Count -eq 0) {
        throw "AzArgs is required."
    }

    if ($TimeoutSeconds -lt 1) {
        $TimeoutSeconds = 1
    }

    $job = Start-Job -ScriptBlock {
        param(
            [string[]]$InnerArgs
        )

        $outputLines = & az @InnerArgs 2>$null
        $outputText = ""
        if ($null -ne $outputLines) {
            $outputText = (@($outputLines) -join [Environment]::NewLine)
        }

        [pscustomobject]@{
            ExitCode = [int]$LASTEXITCODE
            Output = [string]$outputText
        }
    } -ArgumentList (,$AzArgs)

    try {
        $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if (-not $completed) {
            Stop-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
            return [pscustomobject]@{
                ExitCode = 124
                Output = ""
                TimedOut = $true
            }
        }

        $jobResult = Receive-Job -Job $job -ErrorAction SilentlyContinue
        if ($null -eq $jobResult) {
            return [pscustomobject]@{
                ExitCode = 1
                Output = ""
                TimedOut = $false
            }
        }

        return [pscustomobject]@{
            ExitCode = [int]$jobResult.ExitCode
            Output = [string]$jobResult.Output
            TimedOut = $false
        }
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

# Handles Show-AzVmRuntimeConfigurationSnapshot.
function Show-AzVmRuntimeConfigurationSnapshot {
    param(
        [string]$Platform,
        [string]$ScriptName,
        [string]$ScriptRoot,
        [switch]$AutoMode,
        [switch]$UpdateMode,
        [switch]$RenewMode,
        [hashtable]$ConfigMap,
        [hashtable]$ConfigOverrides,
        [hashtable]$Context
    )

    Write-Host ""
    Write-Host "Configuration Snapshot ($ScriptName / platform=$Platform):" -ForegroundColor DarkCyan

    $azAccount = Get-AzVmAzAccountSnapshot
    $accountRows = @()
    $accountFields = [ordered]@{
        SubscriptionName = "Subscription Name"
        SubscriptionId = "Subscription ID"
        TenantName = "Tenant Name"
        TenantId = "Tenant ID"
        UserName = "Account User"
    }
    foreach ($fieldKey in @($accountFields.Keys)) {
        $observed = Register-AzVmValueObservation -Key ([string]$fieldKey) -Value $azAccount[$fieldKey]
        if ($observed.ShouldPrint) {
            $accountRows += [pscustomobject]@{
                Label = [string]$accountFields[$fieldKey]
                Value = [string]$observed.DisplayValue
                IsFirst = [bool]$observed.IsFirst
            }
        }
    }
    if ($accountRows.Count -gt 0) {
        Write-Host "Azure account:"
        foreach ($row in @($accountRows)) {
            Write-Host ("- {0}: {1}" -f [string]$row.Label, [string]$row.Value)
        }
    }

    if ($Context) {
        $selectedRows = @()
        $selectedFields = [ordered]@{
            ResourceGroup = "Azure Resource Group"
            AzLocation = "Azure Region"
            VmSize = "Azure VM SKU"
            VmDiskSize = "VM Disk Size GB"
            VmImage = "VM OS Image"
            VmEnableHibernation = "VM Enable Hibernation"
            VmEnableNestedVirtualization = "VM Enable Nested Virtualization"
        }
        foreach ($fieldKey in @($selectedFields.Keys)) {
            $observed = Register-AzVmValueObservation -Key ([string]$fieldKey) -Value $Context[$fieldKey]
            if ($observed.ShouldPrint) {
                $selectedRows += [pscustomobject]@{
                    Label = [string]$selectedFields[$fieldKey]
                    Value = [string]$observed.DisplayValue
                    IsFirst = [bool]$observed.IsFirst
                }
            }
        }
        if ($selectedRows.Count -gt 0) {
            Write-Host "Selected deployment values:"
            foreach ($row in @($selectedRows)) {
                Write-Host ("- {0}: {1}" -f [string]$row.Label, [string]$row.Value)
            }
        }
    }

    $runtimeRows = @()
    $runtimeFields = [ordered]@{
        AutoMode = [bool]$AutoMode
        UpdateMode = [bool]$UpdateMode
        RenewMode = [bool]$RenewMode
        ScriptRoot = [string]$ScriptRoot
        ScriptName = [string]$ScriptName
    }
    $runtimeLabels = @{
        AutoMode = "Auto mode"
        UpdateMode = "Update mode"
        RenewMode = "destructive rebuild mode"
        ScriptRoot = "Script root"
        ScriptName = "Script name"
    }
    foreach ($fieldKey in @($runtimeFields.Keys)) {
        $observed = Register-AzVmValueObservation -Key ([string]$fieldKey) -Value $runtimeFields[$fieldKey]
        if ($observed.ShouldPrint) {
            $runtimeRows += [pscustomobject]@{
                Label = [string]$runtimeLabels[$fieldKey]
                Value = [string]$observed.DisplayValue
                IsFirst = [bool]$observed.IsFirst
            }
        }
    }
    if ($runtimeRows.Count -gt 0) {
        Write-Host "Runtime flags and app parameters:"
        foreach ($row in @($runtimeRows)) {
            Write-Host ("- {0}: {1}" -f [string]$row.Label, [string]$row.Value)
        }
    }

    $envRows = @()
    if ($ConfigMap -and $ConfigMap.Count -gt 0) {
        foreach ($key in @($ConfigMap.Keys | Sort-Object)) {
            $obsKey = "ENV::{0}" -f [string]$key
            $observed = Register-AzVmValueObservation -Key $obsKey -Value $ConfigMap[$key]
            if ($observed.ShouldPrint) {
                $envRows += [pscustomobject]@{
                    Label = [string]$key
                    Value = [string]$observed.DisplayValue
                    IsFirst = [bool]$observed.IsFirst
                }
            }
        }
    }
    if ($envRows.Count -gt 0) {
        Write-Host ".env loaded values:"
        foreach ($row in @($envRows)) {
            Write-Host ("- {0} = {1}" -f [string]$row.Label, [string]$row.Value)
        }
    }

    $overrideRows = @()
    if ($ConfigOverrides -and $ConfigOverrides.Count -gt 0) {
        foreach ($key in @($ConfigOverrides.Keys | Sort-Object)) {
            $obsKey = "OVERRIDE::{0}" -f [string]$key
            $observed = Register-AzVmValueObservation -Key $obsKey -Value $ConfigOverrides[$key]
            if ($observed.ShouldPrint) {
                $overrideRows += [pscustomobject]@{
                    Label = [string]$key
                    Value = [string]$observed.DisplayValue
                    IsFirst = [bool]$observed.IsFirst
                }
            }
        }
    }
    if ($overrideRows.Count -gt 0) {
        Write-Host "Runtime overrides:"
        foreach ($row in @($overrideRows)) {
            Write-Host ("- {0} = {1}" -f [string]$row.Label, [string]$row.Value)
        }
    }

    if ($Context) {
        $effectiveRows = @()
        foreach ($key in @($Context.Keys | Sort-Object)) {
            $observed = Register-AzVmValueObservation -Key ([string]$key -replace '^\s+|\s+$', '') -Value $Context[$key]
            if ($observed.ShouldPrint) {
                $effectiveRows += [pscustomobject]@{
                    Label = [string]$key
                    Value = [string]$observed.DisplayValue
                    IsFirst = [bool]$observed.IsFirst
                }
            }
        }
        if ($effectiveRows.Count -gt 0) {
            Write-Host "Resolved effective values:"
            foreach ($row in @($effectiveRows)) {
                Write-Host ("- {0} = {1}" -f [string]$row.Label, [string]$row.Value)
            }
        }
    }
}
