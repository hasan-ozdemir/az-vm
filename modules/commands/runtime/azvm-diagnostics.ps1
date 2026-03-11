# Diagnostics, first-use tracking, and runtime snapshot helpers.

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
