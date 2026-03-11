# UI VM lifecycle display helpers.

# Handles Resolve-AzVmVmLifecycleFieldText.
function Resolve-AzVmVmLifecycleFieldText {
    param(
        [string]$DisplayText,
        [string]$CodeText,
        [string]$DefaultText = '(none)'
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$DisplayText)) {
        return [string]$DisplayText
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$CodeText)) {
        return [string]$CodeText
    }

    return [string]$DefaultText
}

# Handles Resolve-AzVmVmLifecycleStateLabel.
function Resolve-AzVmVmLifecycleStateLabel {
    param(
        [string]$PowerStateDisplay,
        [string]$PowerStateCode,
        [string]$HibernationStateDisplay,
        [string]$HibernationStateCode
    )

    $powerText = ((@([string]$PowerStateDisplay, [string]$PowerStateCode) -join ' ').Trim()).ToLowerInvariant()
    $hibernationText = ((@([string]$HibernationStateDisplay, [string]$HibernationStateCode) -join ' ').Trim()).ToLowerInvariant()

    if ($hibernationText -match 'hibernat') {
        return 'hibernated'
    }
    if ($powerText -match 'running') {
        return 'started'
    }
    if (($powerText -match 'stopped') -and -not ($powerText -match 'deallocated')) {
        return 'stopped'
    }
    if ($powerText -match 'deallocated') {
        return 'deallocated'
    }

    return 'other'
}

# Handles ConvertTo-AzVmVmLifecycleSnapshot.
function ConvertTo-AzVmVmLifecycleSnapshot {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [object]$VmObject,
        [object]$InstanceViewObject
    )

    $powerStateCode = ''
    $powerStateDisplay = ''
    $provisioningStateCode = ''
    $provisioningStateDisplay = ''
    $hibernationStateCode = ''
    $hibernationStateDisplay = ''

    $statusEntries = @()
    if ($null -ne $InstanceViewObject -and $InstanceViewObject.PSObject.Properties.Match('instanceView').Count -gt 0 -and $null -ne $InstanceViewObject.instanceView) {
        $statusEntries = @(ConvertTo-ObjectArrayCompat -InputObject $InstanceViewObject.instanceView.statuses)
    }
    if ($statusEntries.Count -eq 0) {
        $statusEntries = @(ConvertTo-ObjectArrayCompat -InputObject $InstanceViewObject.statuses)
    }

    foreach ($status in @($statusEntries)) {
        $statusCode = [string]$status.code
        $statusDisplay = [string]$status.displayStatus
        if ([string]::IsNullOrWhiteSpace([string]$statusCode)) {
            continue
        }

        if ($statusCode.StartsWith('PowerState/', [System.StringComparison]::OrdinalIgnoreCase)) {
            $powerStateCode = $statusCode
            $powerStateDisplay = $statusDisplay
            continue
        }
        if ($statusCode.StartsWith('ProvisioningState/', [System.StringComparison]::OrdinalIgnoreCase)) {
            $provisioningStateCode = $statusCode
            $provisioningStateDisplay = $statusDisplay
            continue
        }
        if ($statusCode.StartsWith('HibernationState/', [System.StringComparison]::OrdinalIgnoreCase)) {
            $hibernationStateCode = $statusCode
            $hibernationStateDisplay = $statusDisplay
            continue
        }
    }

    $hibernationEnabled = $false
    if ($null -ne $VmObject -and $VmObject.PSObject.Properties.Match('hibernationEnabled').Count -gt 0 -and $null -ne $VmObject.hibernationEnabled) {
        $hibernationEnabled = [bool]$VmObject.hibernationEnabled
    }
    elseif ($null -ne $VmObject -and $VmObject.PSObject.Properties.Match('additionalCapabilities').Count -gt 0 -and $null -ne $VmObject.additionalCapabilities) {
        if ($VmObject.additionalCapabilities.PSObject.Properties.Match('hibernationEnabled').Count -gt 0 -and $null -ne $VmObject.additionalCapabilities.hibernationEnabled) {
            $hibernationEnabled = [bool]$VmObject.additionalCapabilities.hibernationEnabled
        }
    }

    $normalizedState = Resolve-AzVmVmLifecycleStateLabel `
        -PowerStateDisplay $powerStateDisplay `
        -PowerStateCode $powerStateCode `
        -HibernationStateDisplay $hibernationStateDisplay `
        -HibernationStateCode $hibernationStateCode

    return [pscustomobject]@{
        ResourceGroup = [string]$ResourceGroup
        VmName = [string]$VmName
        OsType = [string]$VmObject.osType
        Location = [string]$VmObject.location
        HibernationEnabled = [bool]$hibernationEnabled
        ProvisioningStateCode = [string]$provisioningStateCode
        ProvisioningStateDisplay = [string]$provisioningStateDisplay
        PowerStateCode = [string]$powerStateCode
        PowerStateDisplay = [string]$powerStateDisplay
        HibernationStateCode = [string]$hibernationStateCode
        HibernationStateDisplay = [string]$hibernationStateDisplay
        NormalizedState = [string]$normalizedState
    }
}

# Handles Get-AzVmVmLifecycleSnapshot.
function Get-AzVmVmLifecycleSnapshot {
    param(
        [string]$ResourceGroup,
        [string]$VmName
    )

    $vmJson = az vm show `
        -g $ResourceGroup `
        -n $VmName `
        --query "{location:location,osType:storageProfile.osDisk.osType,hibernationEnabled:additionalCapabilities.hibernationEnabled}" `
        -o json `
        --only-show-errors
    Assert-LastExitCode "az vm show (do lifecycle)"
    $vmObject = ConvertFrom-JsonCompat -InputObject $vmJson
    if ($null -eq $vmObject) {
        throw "VM lifecycle metadata could not be parsed."
    }

    $instanceViewJson = az vm get-instance-view -g $ResourceGroup -n $VmName -o json --only-show-errors
    Assert-LastExitCode "az vm get-instance-view (do lifecycle)"
    $instanceViewObject = ConvertFrom-JsonCompat -InputObject $instanceViewJson
    if ($null -eq $instanceViewObject) {
        throw "VM instance view could not be parsed."
    }

    return (ConvertTo-AzVmVmLifecycleSnapshot -ResourceGroup $ResourceGroup -VmName $VmName -VmObject $vmObject -InstanceViewObject $instanceViewObject)
}

# Handles Format-AzVmVmLifecycleSummaryText.
function Format-AzVmVmLifecycleSummaryText {
    param(
        [psobject]$Snapshot
    )

    $powerStateText = Resolve-AzVmVmLifecycleFieldText -DisplayText ([string]$Snapshot.PowerStateDisplay) -CodeText ([string]$Snapshot.PowerStateCode)
    $hibernationStateText = Resolve-AzVmVmLifecycleFieldText -DisplayText ([string]$Snapshot.HibernationStateDisplay) -CodeText ([string]$Snapshot.HibernationStateCode)
    $provisioningStateText = Resolve-AzVmVmLifecycleFieldText -DisplayText ([string]$Snapshot.ProvisioningStateDisplay) -CodeText ([string]$Snapshot.ProvisioningStateCode) -DefaultText '(unknown)'
    $hibernationEnabledText = if ([bool]$Snapshot.HibernationEnabled) { 'true' } else { 'false' }

    return ("lifecycle={0}; power={1}; hibernation={2}; provisioning={3}; hibernationEnabled={4}" -f [string]$Snapshot.NormalizedState, $powerStateText, $hibernationStateText, $provisioningStateText, $hibernationEnabledText)
}
