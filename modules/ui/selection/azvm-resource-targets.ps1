# UI resource-group and VM target selection helpers.

# Handles Get-AzVmResourceGroupsForSelection.
function Get-AzVmResourceGroupsForSelection {
    param(
        [string]$VmName
    )

    $rows = @()
    try {
        $rows = @(Get-AzVmManagedResourceGroupRows)
    }
    catch {
        Throw-FriendlyError `
            -Detail "az group list failed while loading managed resource groups." `
            -Code 64 `
            -Summary "Resource group list could not be loaded." `
            -Hint "Run az login and verify subscription access."
    }

    $names = @(
        ConvertTo-ObjectArrayCompat -InputObject $rows |
            ForEach-Object { [string]$_.name } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Sort-Object -Unique
    )
    if ($names.Count -eq 0) {
        Throw-FriendlyError `
            -Detail ("No managed resource groups were found with tag {0}={1}." -f [string]$script:ManagedByTagKey, [string]$script:ManagedByTagValue) `
            -Code 64 `
            -Summary "Resource group list is empty." `
            -Hint "Run create to provision a managed resource group, then retry."
    }

    $filtered = @($names)

    if (-not [string]::IsNullOrWhiteSpace([string]$VmName)) {
        $needle = [string]$VmName.Trim().ToLowerInvariant()
        $vmMatches = @(
            $filtered | Where-Object {
                $candidate = ([string]$_).ToLowerInvariant()
                $candidate.Contains($needle)
            }
        )
        if ($vmMatches.Count -gt 0) {
            $filtered = @($vmMatches)
        }
    }

    return @($filtered | Sort-Object -Unique)
}

# Handles Select-AzVmResourceGroupInteractive.
function Select-AzVmResourceGroupInteractive {
    param(
        [string]$DefaultResourceGroup,
        [string]$VmName
    )

    $groups = @(Get-AzVmResourceGroupsForSelection -VmName $VmName)
    if ($groups.Count -eq 0) {
        Throw-FriendlyError `
            -Detail "No selectable resource group was found." `
            -Code 64 `
            -Summary "Resource group selection cannot continue." `
            -Hint "Create a resource group first, then retry."
    }

    $defaultIndex = 1
    for ($i = 0; $i -lt $groups.Count; $i++) {
        if ([string]::Equals([string]$groups[$i], [string]$DefaultResourceGroup, [System.StringComparison]::OrdinalIgnoreCase)) {
            $defaultIndex = $i + 1
            break
        }
    }

    Write-Host ""
    Write-Host "Available resource groups (select by number):" -ForegroundColor Cyan
    for ($i = 0; $i -lt $groups.Count; $i++) {
        $label = if (($i + 1) -eq $defaultIndex) { "*{0}-{1}." -f ($i + 1), [string]$groups[$i] } else { "{0}-{1}." -f ($i + 1), [string]$groups[$i] }
        Write-Host $label
    }

    while ($true) {
        $raw = Read-Host ("Enter resource group number (default={0})" -f $defaultIndex)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [string]$groups[$defaultIndex - 1]
        }
        if ($raw -match '^\d+$') {
            $index = [int]$raw
            if ($index -ge 1 -and $index -le $groups.Count) {
                return [string]$groups[$index - 1]
            }
        }
        Write-Host "Invalid resource group selection. Please enter a valid number." -ForegroundColor Yellow
    }
}

# Handles Resolve-AzVmTargetResourceGroup.
function Resolve-AzVmTargetResourceGroup {
    param(
        [hashtable]$Options,
        [switch]$AutoMode,
        [string]$DefaultResourceGroup,
        [string]$VmName,
        [string]$OperationName = 'operation'
    )

    $groupOption = [string](Get-AzVmCliOptionText -Options $Options -Name 'group')
    $resourceGroup = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$groupOption)) {
        $resourceGroup = $groupOption.Trim()
    }
    elseif ($AutoMode) {
        $resourceGroup = [string]$DefaultResourceGroup
        if ([string]::IsNullOrWhiteSpace([string]$resourceGroup)) {
            Throw-FriendlyError `
                -Detail ("No active resource group is configured for auto mode in {0} command." -f $OperationName) `
                -Code 66 `
                -Summary ("{0} command cannot resolve target resource group." -f $OperationName) `
                -Hint "Set RESOURCE_GROUP in .env or provide --group=<name>."
        }
    }
    else {
        $resourceGroup = Select-AzVmResourceGroupInteractive -DefaultResourceGroup $DefaultResourceGroup -VmName $VmName
    }

    $groupExists = az group exists -n $resourceGroup --only-show-errors
    Assert-LastExitCode ("az group exists ({0})" -f $OperationName)
    if (-not [string]::Equals([string]$groupExists, "true", [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-FriendlyError `
            -Detail ("Resource group '{0}' was not found." -f $resourceGroup) `
            -Code 66 `
            -Summary ("{0} command cannot continue because resource group was not found." -f $OperationName) `
            -Hint "Provide a valid --group value or select an existing managed resource group."
    }

    Assert-AzVmManagedResourceGroup -ResourceGroup $resourceGroup -OperationName $OperationName
    return $resourceGroup
}

# Handles Get-AzVmVmNamesForResourceGroup.
function Get-AzVmVmNamesForResourceGroup {
    param(
        [string]$ResourceGroup
    )

    $raw = az vm list -g $ResourceGroup --query "[].name" -o json --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$raw)) {
        Throw-FriendlyError `
            -Detail ("az vm list failed for resource group '{0}'." -f $ResourceGroup) `
            -Code 65 `
            -Summary "VM list could not be loaded." `
            -Hint "Verify the resource group name and Azure access."
    }

    $vmNames = @(
        ConvertFrom-JsonArrayCompat -InputObject $raw |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Sort-Object -Unique
    )
    return @($vmNames)
}

# Handles Select-AzVmVmInteractive.
function Select-AzVmVmInteractive {
    param(
        [string]$ResourceGroup,
        [string]$DefaultVmName
    )

    $vmNames = @(Get-AzVmVmNamesForResourceGroup -ResourceGroup $ResourceGroup)
    if ($vmNames.Count -eq 0) {
        Throw-FriendlyError `
            -Detail ("Resource group '{0}' does not contain any VM." -f $ResourceGroup) `
            -Code 65 `
            -Summary "VM selection cannot continue because the VM list is empty." `
            -Hint "Create a VM first or choose another resource group."
    }

    $defaultIndex = 1
    for ($i = 0; $i -lt $vmNames.Count; $i++) {
        if ([string]::Equals([string]$vmNames[$i], [string]$DefaultVmName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $defaultIndex = $i + 1
            break
        }
    }

    Write-Host ""
    Write-Host ("Available VM names in '{0}' (select by number):" -f $ResourceGroup) -ForegroundColor Cyan
    for ($i = 0; $i -lt $vmNames.Count; $i++) {
        $label = if (($i + 1) -eq $defaultIndex) { "*{0}-{1}." -f ($i + 1), [string]$vmNames[$i] } else { "{0}-{1}." -f ($i + 1), [string]$vmNames[$i] }
        Write-Host $label
    }

    while ($true) {
        $raw = Read-Host ("Enter VM number (default={0})" -f $defaultIndex)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [string]$vmNames[$defaultIndex - 1]
        }
        if ($raw -match '^\d+$') {
            $index = [int]$raw
            if ($index -ge 1 -and $index -le $vmNames.Count) {
                return [string]$vmNames[$index - 1]
            }
        }
        Write-Host "Invalid VM selection. Please enter a valid number." -ForegroundColor Yellow
    }
}

# Handles Resolve-AzVmTargetVmName.
function Resolve-AzVmTargetVmName {
    param(
        [string]$ResourceGroup,
        [string]$DefaultVmName,
        [switch]$AutoMode,
        [string]$OperationName = 'operation'
    )

    $vmNames = @(Get-AzVmVmNamesForResourceGroup -ResourceGroup $ResourceGroup)
    if ($vmNames.Count -eq 0) {
        Throw-FriendlyError `
            -Detail ("No VM found in resource group '{0}'." -f $ResourceGroup) `
            -Code 65 `
            -Summary ("{0} command cannot continue because VM list is empty." -f $OperationName) `
            -Hint "Create a VM first or choose another resource group."
    }

    if ($AutoMode) {
        if (-not [string]::IsNullOrWhiteSpace([string]$DefaultVmName)) {
            foreach ($candidate in @($vmNames)) {
                if ([string]::Equals([string]$candidate, [string]$DefaultVmName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return [string]$candidate
                }
            }
        }

        if ($vmNames.Count -eq 1) {
            return [string]$vmNames[0]
        }

        Throw-FriendlyError `
            -Detail ("Auto mode could not resolve one VM in resource group '{0}'." -f $ResourceGroup) `
            -Code 65 `
            -Summary ("{0} command cannot resolve target VM in auto mode." -f $OperationName) `
            -Hint "Set VM_NAME in .env to the exact Azure VM name, provide a command-specific VM parameter, or use interactive mode."
    }

    return (Select-AzVmVmInteractive -ResourceGroup $ResourceGroup -DefaultVmName $DefaultVmName)
}

# Handles Get-AzVmVmNetworkDescriptor.
function Get-AzVmVmNetworkDescriptor {
    param(
        [string]$ResourceGroup,
        [string]$VmName
    )

    $vmJson = az vm show -g $ResourceGroup -n $VmName -o json --only-show-errors
    Assert-LastExitCode "az vm show (network descriptor)"
    $vmObject = ConvertFrom-JsonCompat -InputObject $vmJson
    if (-not $vmObject) {
        throw "VM metadata could not be parsed while collecting network resources."
    }

    $osDiskName = [string]$vmObject.storageProfile.osDisk.name
    $nicName = ""
    $nicEntries = @($vmObject.networkProfile.networkInterfaces)
    if ($nicEntries.Count -gt 0) {
        $primaryNic = @($nicEntries | Where-Object { $_.primary -eq $true } | Select-Object -First 1)
        if ($null -eq $primaryNic -or @($primaryNic).Count -eq 0) {
            $primaryNic = @($nicEntries | Select-Object -First 1)
        }
        if ($primaryNic -is [System.Array]) { $primaryNic = [object]$primaryNic[0] }
        $nicId = [string]$primaryNic.id
        if (-not [string]::IsNullOrWhiteSpace([string]$nicId)) {
            $nicParts = @($nicId -split '/')
            $nicName = [string]$nicParts[$nicParts.Count - 1]
        }
    }

    $publicIpName = ""
    $nsgName = ""
    $vnetName = ""
    if (-not [string]::IsNullOrWhiteSpace($nicName)) {
        $nicJson = az network nic show -g $ResourceGroup -n $nicName -o json --only-show-errors
        Assert-LastExitCode "az network nic show (network descriptor)"
        $nicObject = ConvertFrom-JsonCompat -InputObject $nicJson
        if ($nicObject) {
            $publicIpId = [string]$nicObject.ipConfigurations[0].publicIPAddress.id
            if (-not [string]::IsNullOrWhiteSpace([string]$publicIpId)) {
                $publicIpParts = @($publicIpId -split '/')
                $publicIpName = [string]$publicIpParts[$publicIpParts.Count - 1]
            }

            $nsgId = [string]$nicObject.networkSecurityGroup.id
            if (-not [string]::IsNullOrWhiteSpace([string]$nsgId)) {
                $nsgParts = @($nsgId -split '/')
                $nsgName = [string]$nsgParts[$nsgParts.Count - 1]
            }

            $subnetId = [string]$nicObject.ipConfigurations[0].subnet.id
            if (-not [string]::IsNullOrWhiteSpace([string]$subnetId)) {
                $subnetParts = @($subnetId -split '/')
                for ($i = 0; $i -lt $subnetParts.Count - 1; $i++) {
                    if ([string]::Equals([string]$subnetParts[$i], 'virtualNetworks', [System.StringComparison]::OrdinalIgnoreCase)) {
                        $vnetName = [string]$subnetParts[$i + 1]
                        break
                    }
                }
            }
        }
    }

    return [pscustomobject]@{
        OsDiskName = $osDiskName
        NicName = $nicName
        PublicIpName = $publicIpName
        NsgName = $nsgName
        VnetName = $vnetName
    }
}

# Handles Get-AzVmManagedVmMatchRows.
function Get-AzVmManagedVmMatchRows {
    param(
        [string]$VmName
    )

    $needle = [string]$VmName
    if ([string]::IsNullOrWhiteSpace([string]$needle)) {
        return @()
    }

    $matches = @()
    $groups = @(Get-AzVmManagedResourceGroupRows)
    foreach ($groupRow in @($groups)) {
        $resourceGroup = [string]$groupRow.name
        if ([string]::IsNullOrWhiteSpace([string]$resourceGroup)) {
            continue
        }

        $vmNames = @(Get-AzVmVmNamesForResourceGroup -ResourceGroup $resourceGroup)
        foreach ($candidateVmName in @($vmNames)) {
            if ([string]::Equals([string]$candidateVmName, $needle, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matches += [pscustomobject]@{
                    ResourceGroup = $resourceGroup
                    VmName = [string]$candidateVmName
                }
            }
        }
    }

    return @($matches)
}

# Handles Resolve-AzVmManagedVmTarget.
function Resolve-AzVmManagedVmTarget {
    param(
        [hashtable]$Options,
        [hashtable]$ConfigMap,
        [string]$OperationName
    )

    $defaultResourceGroup = [string](Get-ConfigValue -Config $ConfigMap -Key 'RESOURCE_GROUP' -DefaultValue '')
    $defaultVmName = [string](Get-ConfigValue -Config $ConfigMap -Key 'VM_NAME' -DefaultValue '')
    $groupOption = [string](Get-AzVmCliOptionText -Options $Options -Name 'group')
    $vmNameOption = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-name')
    $requestedResourceGroup = $groupOption.Trim()
    $requestedVmName = $vmNameOption.Trim()

    if (-not [string]::IsNullOrWhiteSpace([string]$requestedResourceGroup)) {
        $resourceGroup = Resolve-AzVmTargetResourceGroup `
            -Options $Options `
            -AutoMode:$false `
            -DefaultResourceGroup $defaultResourceGroup `
            -VmName $requestedVmName `
            -OperationName $OperationName

        if ([string]::IsNullOrWhiteSpace([string]$requestedVmName)) {
            $vmName = Select-AzVmVmInteractive -ResourceGroup $resourceGroup -DefaultVmName $defaultVmName
        }
        else {
            $vmNames = @(Get-AzVmVmNamesForResourceGroup -ResourceGroup $resourceGroup)
            $resolvedVmName = @($vmNames | Where-Object { [string]::Equals([string]$_, $requestedVmName, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
            if (@($resolvedVmName).Count -eq 0) {
                Throw-FriendlyError `
                    -Detail ("VM '{0}' was not found in resource group '{1}'." -f $requestedVmName, $resourceGroup) `
                    -Code 66 `
                    -Summary ("{0} command could not resolve the target VM." -f $OperationName) `
                    -Hint "Provide an exact VM name in the selected resource group, or omit --vm-name to select interactively."
            }
            $vmName = [string]$resolvedVmName[0]
        }

        return [pscustomobject]@{
            ResourceGroup = $resourceGroup
            VmName = $vmName
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$requestedVmName)) {
        $activeGroupMatches = $false
        if (-not [string]::IsNullOrWhiteSpace([string]$defaultResourceGroup) -and (Test-AzVmResourceGroupManaged -ResourceGroup $defaultResourceGroup)) {
            $activeVmNames = @(Get-AzVmVmNamesForResourceGroup -ResourceGroup $defaultResourceGroup)
            foreach ($candidateVmName in @($activeVmNames)) {
                if ([string]::Equals([string]$candidateVmName, $requestedVmName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return [pscustomobject]@{
                        ResourceGroup = $defaultResourceGroup
                        VmName = [string]$candidateVmName
                    }
                }
            }
            $activeGroupMatches = $true
        }

        $matches = @(Get-AzVmManagedVmMatchRows -VmName $requestedVmName)
        if (@($matches).Count -eq 1) {
            return [pscustomobject]@{
                ResourceGroup = [string]$matches[0].ResourceGroup
                VmName = [string]$matches[0].VmName
            }
        }

        if (@($matches).Count -gt 1) {
            $matchGroups = @($matches | ForEach-Object { [string]$_.ResourceGroup } | Sort-Object -Unique)
            Throw-FriendlyError `
                -Detail ("VM name '{0}' was found in multiple managed resource groups: {1}." -f $requestedVmName, ($matchGroups -join ', ')) `
                -Code 66 `
                -Summary ("{0} command needs an explicit resource group." -f $OperationName) `
                -Hint "Provide --group=<resource-group> together with --vm-name=<name>."
        }

        $notFoundHint = if ($activeGroupMatches) {
            "Provide --group=<resource-group> or select another exact VM name."
        }
        else {
            "Select a managed resource group interactively or provide both --group and --vm-name."
        }

        Throw-FriendlyError `
            -Detail ("VM '{0}' was not found in az-vm managed resource groups." -f $requestedVmName) `
            -Code 66 `
            -Summary ("{0} command could not find the target VM." -f $OperationName) `
            -Hint $notFoundHint
    }

    $resourceGroup = Select-AzVmResourceGroupInteractive -DefaultResourceGroup $defaultResourceGroup -VmName $defaultVmName
    $vmName = Select-AzVmVmInteractive -ResourceGroup $resourceGroup -DefaultVmName $defaultVmName
    return [pscustomobject]@{
        ResourceGroup = $resourceGroup
        VmName = $vmName
    }
}

# Handles Resolve-AzVmConnectionTarget.
function Resolve-AzVmConnectionTarget {
    param(
        [hashtable]$Options,
        [hashtable]$ConfigMap,
        [string]$OperationName
    )

    return (Resolve-AzVmManagedVmTarget -Options $Options -ConfigMap $ConfigMap -OperationName $OperationName)
}
