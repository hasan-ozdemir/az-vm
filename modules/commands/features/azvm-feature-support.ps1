# Feature-support, hibernation, and nested-virtualization helpers.

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

    return (Wait-AzVmProvisioningReadyOrRepair -ResourceGroup $ResourceGroup -VmName $VmName -MaxAttempts $MaxAttempts -DelaySeconds $DelaySeconds)
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
