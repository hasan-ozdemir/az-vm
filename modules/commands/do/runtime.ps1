# Do command runtime helpers.

# Handles Resolve-AzVmDoActionName.
function Resolve-AzVmDoActionName {
    param(
        [string]$RawValue,
        [switch]$AllowEmpty
    )

    $action = if ($null -eq $RawValue) { '' } else { [string]$RawValue }
    $normalized = $action.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace([string]$normalized)) {
        if ($AllowEmpty) {
            return ''
        }

        Throw-FriendlyError `
            -Detail "Option '--vm-action' requires a value." `
            -Code 2 `
            -Summary "VM action is missing." `
            -Hint "Use --vm-action=status|start|restart|stop|deallocate|hibernate."
    }

    if ($normalized -eq 'release') {
        Throw-FriendlyError `
            -Detail "Option '--vm-action=release' is no longer supported." `
            -Code 2 `
            -Summary "VM action is invalid." `
            -Hint "Use --vm-action=deallocate."
    }

    if ($normalized -notin @('status','start','restart','stop','deallocate','hibernate')) {
        Throw-FriendlyError `
            -Detail ("Invalid --vm-action value '{0}'." -f $RawValue) `
            -Code 2 `
            -Summary "VM action is invalid." `
            -Hint "Use --vm-action=status|start|restart|stop|deallocate|hibernate."
    }

    return $normalized
}

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

# Handles Get-AzVmDoAllowedSourceStates.
function Get-AzVmDoAllowedSourceStates {
    param(
        [string]$ActionName
    )

    switch ($ActionName) {
        'start' { return @('stopped','deallocated','hibernated') }
        'restart' { return @('started') }
        'stop' { return @('started') }
        'deallocate' { return @('started','stopped','hibernated') }
        'hibernate' { return @('started') }
        default { return @() }
    }
}

# Handles Assert-AzVmDoActionAllowed.
function Assert-AzVmDoActionAllowed {
    param(
        [string]$ActionName,
        [psobject]$Snapshot
    )

    if ($ActionName -eq 'status') {
        return
    }

    $provisioningSucceeded = $false
    if ([string]::Equals([string]$Snapshot.ProvisioningStateCode, 'ProvisioningState/succeeded', [System.StringComparison]::OrdinalIgnoreCase)) {
        $provisioningSucceeded = $true
    }
    elseif ([string]::Equals([string]$Snapshot.ProvisioningStateDisplay, 'Provisioning succeeded', [System.StringComparison]::OrdinalIgnoreCase)) {
        $provisioningSucceeded = $true
    }

    if (-not $provisioningSucceeded) {
        Throw-FriendlyError `
            -Detail ("Requested action '{0}' cannot continue for VM '{1}' in resource group '{2}' because provisioning is not ready. {3}" -f $ActionName, [string]$Snapshot.VmName, [string]$Snapshot.ResourceGroup, (Format-AzVmVmLifecycleSummaryText -Snapshot $Snapshot)) `
            -Code 66 `
            -Summary "VM action cannot continue because provisioning is not in succeeded state." `
            -Hint "Wait until provisioning succeeds, run '--vm-action=status', then retry."
    }

    if ($ActionName -eq 'hibernate' -and -not [bool]$Snapshot.HibernationEnabled) {
        Throw-FriendlyError `
            -Detail ("Requested action '{0}' cannot continue for VM '{1}' in resource group '{2}' because hibernation is not enabled. {3}" -f $ActionName, [string]$Snapshot.VmName, [string]$Snapshot.ResourceGroup, (Format-AzVmVmLifecycleSummaryText -Snapshot $Snapshot)) `
            -Code 66 `
            -Summary "Hibernate action is not available for this VM." `
            -Hint "Enable hibernation support first, or use stop/deallocate instead."
    }

    $allowedStates = @(Get-AzVmDoAllowedSourceStates -ActionName $ActionName)
    if ($allowedStates.Count -eq 0) {
        return
    }

    if ($allowedStates -notcontains [string]$Snapshot.NormalizedState) {
        Throw-FriendlyError `
            -Detail ("Requested action '{0}' cannot run for VM '{1}' in resource group '{2}'. {3}. Allowed source states: {4}." -f $ActionName, [string]$Snapshot.VmName, [string]$Snapshot.ResourceGroup, (Format-AzVmVmLifecycleSummaryText -Snapshot $Snapshot), ($allowedStates -join ', ')) `
            -Code 66 `
            -Summary ("VM action '{0}' is not valid for the current VM state." -f $ActionName) `
            -Hint ("Run '--vm-action=status' for current state details and retry only from: {0}." -f ($allowedStates -join ', '))
    }
}

# Handles Write-AzVmDoStatusReport.
function Write-AzVmDoStatusReport {
    param(
        [psobject]$Snapshot
    )

    $hibernationEnabledText = if ([bool]$Snapshot.HibernationEnabled) { 'true' } else { 'false' }
    Write-Host ("VM lifecycle status for '{0}' in group '{1}':" -f [string]$Snapshot.VmName, [string]$Snapshot.ResourceGroup) -ForegroundColor Cyan
    Write-Host ("- lifecycle = {0}" -f [string]$Snapshot.NormalizedState)
    Write-Host ("- power-state = {0}" -f (Resolve-AzVmVmLifecycleFieldText -DisplayText ([string]$Snapshot.PowerStateDisplay) -CodeText ([string]$Snapshot.PowerStateCode)))
    Write-Host ("- hibernation-state = {0}" -f (Resolve-AzVmVmLifecycleFieldText -DisplayText ([string]$Snapshot.HibernationStateDisplay) -CodeText ([string]$Snapshot.HibernationStateCode)))
    Write-Host ("- provisioning-state = {0}" -f (Resolve-AzVmVmLifecycleFieldText -DisplayText ([string]$Snapshot.ProvisioningStateDisplay) -CodeText ([string]$Snapshot.ProvisioningStateCode) -DefaultText '(unknown)'))
    Write-Host ("- hibernation-enabled = {0}" -f $hibernationEnabledText)
}

# Handles Assert-AzVmConnectionVmRunning.
function Assert-AzVmConnectionVmRunning {
    param(
        [string]$OperationName,
        [psobject]$Snapshot
    )

    if ([string]::Equals([string]$Snapshot.NormalizedState, 'started', [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    $commandLabel = ([string]$OperationName).ToUpperInvariant()
    Throw-FriendlyError `
        -Detail ("The {0} command cannot launch because VM '{1}' in resource group '{2}' is not running. {3}" -f $OperationName, [string]$Snapshot.VmName, [string]$Snapshot.ResourceGroup, (Format-AzVmVmLifecycleSummaryText -Snapshot $Snapshot)) `
        -Code 66 `
        -Summary ("{0} requires the VM to be running." -f $commandLabel) `
        -Hint ("Start the VM with 'az-vm do --vm-action=start --group={0} --vm-name={1}' and retry." -f [string]$Snapshot.ResourceGroup, [string]$Snapshot.VmName)
}

# Handles Read-AzVmDoActionInteractive.
function Read-AzVmDoActionInteractive {
    param(
        [psobject]$Snapshot
    )

    Write-Host ""
    Write-AzVmDoStatusReport -Snapshot $Snapshot
    Write-Host ""
    Write-Host "Available VM actions (select by number, default=status):" -ForegroundColor Cyan
    $choices = @(
        [pscustomobject]@{ Number = 1; Action = 'status'; Label = 'status (read-only)' },
        [pscustomobject]@{ Number = 2; Action = 'start'; Label = 'start' },
        [pscustomobject]@{ Number = 3; Action = 'restart'; Label = 'restart' },
        [pscustomobject]@{ Number = 4; Action = 'stop'; Label = 'stop' },
        [pscustomobject]@{ Number = 5; Action = 'deallocate'; Label = 'deallocate' },
        [pscustomobject]@{ Number = 6; Action = 'hibernate'; Label = 'hibernate' }
    )

    foreach ($choice in @($choices)) {
        Write-Host ("{0}. {1}" -f [int]$choice.Number, [string]$choice.Label)
    }

    while ($true) {
        $raw = Read-Host "Enter VM action number or name (default=status)"
        if ([string]::IsNullOrWhiteSpace([string]$raw)) {
            return 'status'
        }

        $text = [string]$raw
        $trimmed = $text.Trim()
        if ($trimmed -match '^\d+$') {
            $picked = @($choices | Where-Object { [int]$_.Number -eq [int]$trimmed } | Select-Object -First 1)
            if (@($picked).Count -gt 0) {
                return [string]$picked[0].Action
            }
        }

        try {
            return (Resolve-AzVmDoActionName -RawValue $trimmed)
        }
        catch {
            Write-Host "Invalid VM action selection. Please enter a valid number or action name." -ForegroundColor Yellow
        }
    }
}

# Handles Wait-AzVmDoLifecycleState.
function Wait-AzVmDoLifecycleState {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$DesiredState,
        [int]$MaxAttempts = 18,
        [int]$DelaySeconds = 10
    )

    if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
    if ($MaxAttempts -gt 120) { $MaxAttempts = 120 }
    if ($DelaySeconds -lt 1) { $DelaySeconds = 1 }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $snapshot = Get-AzVmVmLifecycleSnapshot -ResourceGroup $ResourceGroup -VmName $VmName
        $powerText = Resolve-AzVmVmLifecycleFieldText -DisplayText ([string]$snapshot.PowerStateDisplay) -CodeText ([string]$snapshot.PowerStateCode)
        $hibernationText = Resolve-AzVmVmLifecycleFieldText -DisplayText ([string]$snapshot.HibernationStateDisplay) -CodeText ([string]$snapshot.HibernationStateCode)
        Write-Host ("VM lifecycle state: {0}; power: {1}; hibernation: {2} (attempt {3}/{4})" -f [string]$snapshot.NormalizedState, $powerText, $hibernationText, $attempt, $MaxAttempts)

        if ([string]::Equals([string]$snapshot.NormalizedState, [string]$DesiredState, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $snapshot
        }

        Start-Sleep -Seconds $DelaySeconds
    }

    return $null
}

# Handles Invoke-AzVmDoAzureAction.
function Invoke-AzVmDoAzureAction {
    param(
        [string]$ActionName,
        [string]$ResourceGroup,
        [string]$VmName,
        [string[]]$AzArguments,
        [string]$AzContext
    )

    try {
        Invoke-TrackedAction -Label ("az " + (@($AzArguments) -join ' ')) -Action {
            az @AzArguments
            Assert-LastExitCode $AzContext
        } | Out-Null
    }
    catch {
        Throw-FriendlyError `
            -Detail ("Azure CLI rejected VM action '{0}' for VM '{1}' in resource group '{2}': {3}" -f $ActionName, $VmName, $ResourceGroup, $_.Exception.Message) `
            -Code 66 `
            -Summary ("VM action '{0}' failed." -f $ActionName) `
            -Hint "Review the Azure CLI error text above, correct the blocking condition, then retry."
    }
}

