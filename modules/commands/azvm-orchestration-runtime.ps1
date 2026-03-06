# Imported runtime region: test-orchestration.

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

    $vmNameDefaultResolved = Get-ConfigValue -Config $ConfigMap -Key "VM_NAME" -DefaultValue $VmNameDefault
    $vmName = $vmNameDefaultResolved
    do {
        if ($AutoMode) {
            $userInput = $vmNameDefaultResolved
        }
        else {
            $userInput = Read-Host "Enter VM name (actual Azure VM name; default=$vmNameDefaultResolved)"
        }

        if ([string]::IsNullOrWhiteSpace($userInput)) {
            $userInput = $vmNameDefaultResolved
        }

        if ($userInput -match '^[a-zA-Z][a-zA-Z0-9\-]{2,15}$') {
            $isValid = $true
        }
        else {
            Write-Host "Invalid VM name. Try again." -ForegroundColor Red
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

    if ($resourceGroupGenerated -and $PersistGeneratedResourceGroup) {
        Set-DotEnvValue -Path $EnvFilePath -Key "RESOURCE_GROUP" -Value $resourceGroup
        if ($ConfigOverrides) {
            $ConfigOverrides["RESOURCE_GROUP"] = $resourceGroup
        }
    }

    $vnetRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "VNET_NAME" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($vnetRaw)) {
        $vnetRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "VNET_NAME_TEMPLATE" -DefaultValue "net-{VM_NAME}-{REGION_CODE}-n{N}")
    }
    $VNET = Resolve-AzVmTemplate -Template $vnetRaw -Tokens $nameTokens

    $subnetRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "SUBNET_NAME" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($subnetRaw)) {
        $subnetRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "SUBNET_NAME_TEMPLATE" -DefaultValue "subnet-{VM_NAME}-{REGION_CODE}-n{N}")
    }
    $SUBNET = Resolve-AzVmTemplate -Template $subnetRaw -Tokens $nameTokens

    $nsgRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "NSG_NAME" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($nsgRaw)) {
        $nsgRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "NSG_NAME_TEMPLATE" -DefaultValue "nsg-{VM_NAME}-{REGION_CODE}-n{N}")
    }
    $NSG = Resolve-AzVmTemplate -Template $nsgRaw -Tokens $nameTokens

    $nsgRuleRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "NSG_RULE_NAME" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($nsgRuleRaw)) {
        $nsgRuleRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "NSG_RULE_NAME_TEMPLATE" -DefaultValue "nsgrule-{VM_NAME}-{REGION_CODE}-n{N}")
    }
    $nsgRule = Resolve-AzVmTemplate -Template $nsgRuleRaw -Tokens $nameTokens

    $ipRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "PUBLIC_IP_NAME" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($ipRaw)) {
        $ipRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "PUBLIC_IP_NAME_TEMPLATE" -DefaultValue "ip-{VM_NAME}-{REGION_CODE}-n{N}")
    }
    $IP = Resolve-AzVmTemplate -Template $ipRaw -Tokens $nameTokens

    $nicRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "NIC_NAME" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($nicRaw)) {
        $nicRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "NIC_NAME_TEMPLATE" -DefaultValue "nic-{VM_NAME}-{REGION_CODE}-n{N}")
    }
    $NIC = Resolve-AzVmTemplate -Template $nicRaw -Tokens $nameTokens

    $vmDiskNameRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "VM_DISK_NAME" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($vmDiskNameRaw)) {
        $vmDiskNameRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "VM_DISK_NAME_TEMPLATE" -DefaultValue "disk-{VM_NAME}-{REGION_CODE}-n{N}")
    }
    $vmDiskName = Resolve-AzVmTemplate -Template $vmDiskNameRaw -Tokens $nameTokens

    $vmDiskSize = Resolve-AzVmTemplate -Template (Get-ConfigValue -Config $ConfigMap -Key $vmDiskSizeConfigKey -DefaultValue $VmDiskSizeDefault) -Tokens $baseTokens
    $vmUserRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "VM_ADMIN_USER" -DefaultValue "manager")
    $vmPassRaw = [string](Get-ConfigValue -Config $ConfigMap -Key "VM_ADMIN_PASS" -DefaultValue "<runtime-secret>")
    $vmUser = Resolve-AzVmTemplate -Template $vmUserRaw -Tokens $baseTokens
    $vmPass = Resolve-AzVmTemplate -Template $vmPassRaw -Tokens $baseTokens
    $vmAssistantUser = Resolve-AzVmTemplate -Template (Get-ConfigValue -Config $ConfigMap -Key "VM_ASSISTANT_USER" -DefaultValue "assistant") -Tokens $baseTokens
    $vmAssistantPass = Resolve-AzVmTemplate -Template (Get-ConfigValue -Config $ConfigMap -Key "VM_ASSISTANT_PASS" -DefaultValue "<runtime-secret>") -Tokens $baseTokens
    $sshPortValue = [string](Get-ConfigValue -Config $ConfigMap -Key "SSH_PORT" -DefaultValue "444")
    $sshPort = Resolve-AzVmTemplate -Template $sshPortValue -Tokens $baseTokens
    $vmInitTaskDirName = Resolve-AzVmTemplate -Template (Get-ConfigValue -Config $ConfigMap -Key $vmInitTaskDirConfigKey -DefaultValue ([string]$((Get-AzVmPlatformDefaults -Platform $Platform).VmInitTaskDirDefault))) -Tokens $baseTokens
    $vmUpdateTaskDirName = Resolve-AzVmTemplate -Template (Get-ConfigValue -Config $ConfigMap -Key $vmUpdateTaskDirConfigKey -DefaultValue ([string]$((Get-AzVmPlatformDefaults -Platform $Platform).VmUpdateTaskDirDefault))) -Tokens $baseTokens
    $vmInitTaskDir = Resolve-ConfigPath -PathValue $vmInitTaskDirName -RootPath $ScriptRoot
    $vmUpdateTaskDir = Resolve-ConfigPath -PathValue $vmUpdateTaskDirName -RootPath $ScriptRoot

    $defaultPortsCsv = "80,443,444,8444,3389,389,5173,3000,3001,8080,5432,3306,6837,4000,4001,5000,5001,6000,6001,6060,7000,7001,7070,8000,8001,9000,9001,9090,2222,3333,4444,5555,6666,7777,8888,9999,11434"
    $tcpPortsCsv = Get-ConfigValue -Config $ConfigMap -Key "TCP_PORTS" -DefaultValue $defaultPortsCsv
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

    return [ordered]@{
        RegionCode = $regionCode
        NamingTemplateActive = $namingProfile
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
        VmSize = $vmSize
        DefaultVmSize = $defaultVmSize
        VmDiskName = $vmDiskName
        VmDiskSize = $vmDiskSize
        VmUser = $vmUser
        VmPass = $vmPass
        VmAssistantUser = $vmAssistantUser
        VmAssistantPass = $vmAssistantPass
        SshPort = $sshPort
        TcpPorts = @($tcpPorts)
        VmInitTaskDir = $vmInitTaskDir
        VmUpdateTaskDir = $vmUpdateTaskDir
    }
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

    $null = az @AzArgs --only-show-errors -o none 2>$null
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
        [ValidateSet('config','group','network','vm-deploy','vm-init','vm-update','vm-summary')]
        [string]$ActionName,
        [hashtable]$Context
    )

    if ($ActionName -in @('config', 'group')) {
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
            az network public-ip create -g $Context.ResourceGroup -n $Context.IP --allocation-method Static --sku Standard --dns-name $Context.VmName -o table
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
        -Keys @("ResourceGroup", "VmName", "VmImage", "VmSize", "VmStorageSku", "VmDiskName", "VmDiskSize", "VmUser", "VmPass", "VmAssistantUser", "VmAssistantPass", "NIC") `
        -ExtraValues @{
            VmExecutionMode = $effectiveMode
        }

    $existingVM = az vm list `
        --resource-group $resourceGroup `
        --query "[?name=='$vmName'].name | [0]" `
        -o tsv
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
            Write-Warning "az vm create returned a non-zero code; checking VM existence."

            $vmExistsAfterCreate = ""
            $shouldUseLongPresenceProbe = (($effectiveMode -in @("update","destructive rebuild")) -and $hasExistingVm)
            $presenceProbeAttempts = if ($shouldUseLongPresenceProbe) { 12 } else { 3 }
            for ($presenceAttempt = 1; $presenceAttempt -le $presenceProbeAttempts; $presenceAttempt++) {
                $vmExistsAfterCreate = az vm show -g $resourceGroup -n $vmName --query "id" -o tsv 2>$null
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$vmExistsAfterCreate)) {
                    break
                }

                if ($presenceAttempt -lt $presenceProbeAttempts) {
                    Write-Host ("VM existence probe attempt {0}/{1} did not resolve yet. Retrying in 10s..." -f $presenceAttempt, $presenceProbeAttempts) -ForegroundColor Yellow
                    Start-Sleep -Seconds 10
                }
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$vmExistsAfterCreate)) {
                Write-Host "VM exists; details will be retrieved via az vm show -d."
                $result = az vm show -g $resourceGroup -n $vmName -d -o json
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

    return [pscustomobject]@{
        VmExistsBefore = [bool]$hasExistingVm
        VmDeleted = [bool]$vmDeletedInThisRun
        VmCreateInvoked = $true
        VmCreatedThisRun = [bool]$vmCreatedThisRun
        VmId = [string]$vmCreateObj.id
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
        $result = az vm show -g $Context.ResourceGroup -n $Context.VmName -d -o json
        Assert-LastExitCode "az vm show -d"
        $result
    }

    $vmDetails = ConvertFrom-JsonCompat -InputObject $vmDetailsJson
    if (-not $vmDetails) {
        throw "VM detail output could not be parsed."
    }

    $publicIP = $vmDetails.publicIps
    $vmFqdn = $vmDetails.fqdns
    if ([string]::IsNullOrWhiteSpace($vmFqdn)) {
        $vmFqdn = "$($Context.VmName).$($Context.AzLocation).cloudapp.azure.com"
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
