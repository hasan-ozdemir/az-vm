# Shared Step-1 context builders and security-value helpers.

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
