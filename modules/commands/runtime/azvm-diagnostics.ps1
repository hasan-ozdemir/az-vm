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

function Get-AzVmConfigValueSourceTracker {
    if (-not $script:AzVmConfigValueSources) {
        $script:AzVmConfigValueSources = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    }

    return (, $script:AzVmConfigValueSources)
}

function Set-AzVmConfigValueSource {
    param(
        [string]$Key,
        [string]$Source
    )

    $normalizedKey = [string]$Key
    $normalizedSource = [string]$Source
    if ([string]::IsNullOrWhiteSpace([string]$normalizedKey) -or [string]::IsNullOrWhiteSpace([string]$normalizedSource)) {
        return
    }

    $tracker = Get-AzVmConfigValueSourceTracker
    $tracker[[string]$normalizedKey] = [string]$normalizedSource.Trim()
}

function Get-AzVmConfigValueSource {
    param([string]$Key)

    $normalizedKey = [string]$Key
    if ([string]::IsNullOrWhiteSpace([string]$normalizedKey)) {
        return ''
    }

    $tracker = Get-AzVmConfigValueSourceTracker
    if ($tracker.ContainsKey([string]$normalizedKey)) {
        return [string]$tracker[[string]$normalizedKey]
    }

    return ''
}

function Test-AzVmDictionaryHasNonBlankValue {
    param(
        [System.Collections.IDictionary]$Dictionary,
        [string]$Key
    )

    if ($null -eq $Dictionary -or [string]::IsNullOrWhiteSpace([string]$Key)) {
        return $false
    }

    if ($Dictionary.PSObject.Methods.Match('ContainsKey').Count -gt 0 -and $Dictionary.ContainsKey([string]$Key)) {
        return (-not [string]::IsNullOrWhiteSpace([string]$Dictionary[[string]$Key]))
    }

    if ($Dictionary.PSObject.Methods.Match('Contains').Count -gt 0 -and $Dictionary.Contains([string]$Key)) {
        return (-not [string]::IsNullOrWhiteSpace([string]$Dictionary[[string]$Key]))
    }

    foreach ($candidateKey in @($Dictionary.Keys)) {
        if (-not [string]::Equals([string]$candidateKey, [string]$Key, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        return (-not [string]::IsNullOrWhiteSpace([string]$Dictionary[$candidateKey]))
    }

    return $false
}

function Resolve-AzVmConfigValueSourceLabel {
    param(
        [string]$Key,
        [System.Collections.IDictionary]$ConfigMap,
        [System.Collections.IDictionary]$ConfigOverrides,
        [string]$FallbackSource = 'derived value'
    )

    $trackedSource = [string](Get-AzVmConfigValueSource -Key $Key)
    if (-not [string]::IsNullOrWhiteSpace([string]$trackedSource)) {
        return $trackedSource
    }

    if (Test-AzVmDictionaryHasNonBlankValue -Dictionary $ConfigOverrides -Key $Key) {
        return 'runtime value'
    }

    if (Test-AzVmDictionaryHasNonBlankValue -Dictionary $ConfigMap -Key $Key) {
        return '.env value'
    }

    return [string]$FallbackSource
}

function New-AzVmRuntimeConfigurationRows {
    param(
        [string]$Platform,
        [System.Collections.IDictionary]$ConfigMap,
        [System.Collections.IDictionary]$ConfigOverrides,
        [hashtable]$Context
    )

    $platformImageKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey 'VM_IMAGE'
    $platformSizeKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey 'VM_SIZE'
    $platformDiskSizeKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey 'VM_DISK_SIZE_GB'
    $platformInitDirKey = Get-AzVmPlatformTaskCatalogConfigKey -Platform $Platform -Stage 'init'
    $platformUpdateDirKey = Get-AzVmPlatformTaskCatalogConfigKey -Platform $Platform -Stage 'update'

    $specs = @(
        @{ Key = 'SELECTED_VM_OS'; Value = [string]$Context.VmOsType; FallbackSource = 'derived value' },
        @{ Key = 'SELECTED_AZURE_SUBSCRIPTION_ID'; Value = [string]$Context.AzureSubscriptionId; FallbackSource = 'azure value' },
        @{ Key = 'SELECTED_AZURE_REGION'; Value = [string]$Context.AzLocation; FallbackSource = 'derived value' },
        @{ Key = 'SELECTED_RESOURCE_GROUP'; Value = [string]$Context.ResourceGroup; FallbackSource = 'derived value' },
        @{ Key = 'SELECTED_VM_NAME'; Value = [string]$Context.VmName; FallbackSource = 'derived value' },
        @{ Key = [string]$platformImageKey; Value = [string]$Context.VmImage; FallbackSource = 'default value' },
        @{ Key = [string]$platformSizeKey; Value = [string]$Context.VmSize; FallbackSource = 'default value' },
        @{ Key = [string]$platformDiskSizeKey; Value = [string]$Context.VmDiskSize; FallbackSource = 'default value' },
        @{ Key = 'VM_STORAGE_SKU'; Value = [string]$Context.VmStorageSku; FallbackSource = 'default value' },
        @{ Key = 'VM_SECURITY_TYPE'; Value = [string]$Context.VmSecurityType; FallbackSource = 'default value' },
        @{ Key = 'VM_ENABLE_SECURE_BOOT'; Value = [string]$Context.VmEnableSecureBoot; FallbackSource = 'default value' },
        @{ Key = 'VM_ENABLE_VTPM'; Value = [string]$Context.VmEnableVtpm; FallbackSource = 'default value' },
        @{ Key = 'VM_ENABLE_HIBERNATION'; Value = [string]$Context.VmEnableHibernation; FallbackSource = 'default value' },
        @{ Key = 'VM_ENABLE_NESTED_VIRTUALIZATION'; Value = [string]$Context.VmEnableNestedVirtualization; FallbackSource = 'default value' },
        @{ Key = 'VM_SSH_PORT'; Value = [string]$Context.SshPort; FallbackSource = 'default value' },
        @{ Key = 'VM_RDP_PORT'; Value = [string]$Context.RdpPort; FallbackSource = 'default value' },
        @{ Key = 'TCP_PORTS'; Value = [string]$Context.TcpPortsConfiguredCsv; FallbackSource = 'default value' },
        @{ Key = 'SELECTED_COMPANY_NAME'; Value = [string]$Context.CompanyName; FallbackSource = '.env value' },
        @{ Key = 'SELECTED_COMPANY_WEB_ADDRESS'; Value = [string]$Context.CompanyWebAddress; FallbackSource = '.env value' },
        @{ Key = 'SELECTED_COMPANY_EMAIL_ADDRESS'; Value = [string]$Context.CompanyEmailAddress; FallbackSource = '.env value' },
        @{ Key = 'SELECTED_EMPLOYEE_EMAIL_ADDRESS'; Value = [string]$Context.EmployeeEmailAddress; FallbackSource = '.env value' },
        @{ Key = 'SELECTED_EMPLOYEE_FULL_NAME'; Value = [string]$Context.EmployeeFullName; FallbackSource = '.env value' },
        @{ Key = [string]$platformInitDirKey; Value = [string]$Context.VmInitTaskDir; FallbackSource = 'default value' },
        @{ Key = [string]$platformUpdateDirKey; Value = [string]$Context.VmUpdateTaskDir; FallbackSource = 'default value' },
        @{ Key = 'AZURE_COMMAND_TIMEOUT_SECONDS'; Value = [string]$Context.AzCommandTimeoutSeconds; FallbackSource = 'default value' },
        @{ Key = 'SSH_TASK_TIMEOUT_SECONDS'; Value = [string]$Context.SshTaskTimeoutSeconds; FallbackSource = 'default value' },
        @{ Key = 'SSH_CONNECT_TIMEOUT_SECONDS'; Value = [string]$Context.SshConnectTimeoutSeconds; FallbackSource = 'default value' },
        @{ Key = 'VM_TASK_OUTCOME_MODE'; Value = [string]$Context.TaskOutcomeMode; FallbackSource = 'default value' },
        @{ Key = 'PYSSH_CLIENT_PATH'; Value = [string]$Context.ConfiguredPySshClientPath; FallbackSource = 'default value' },
        @{ Key = 'REGION_CODE'; Value = [string]$Context.RegionCode; FallbackSource = 'derived value' },
        @{ Key = 'VNET_NAME'; Value = [string]$Context.VNET; FallbackSource = 'derived value' },
        @{ Key = 'SUBNET_NAME'; Value = [string]$Context.SUBNET; FallbackSource = 'derived value' },
        @{ Key = 'NSG_NAME'; Value = [string]$Context.NSG; FallbackSource = 'derived value' },
        @{ Key = 'NSG_RULE_NAME'; Value = [string]$Context.NsgRule; FallbackSource = 'derived value' },
        @{ Key = 'PUBLIC_IP_NAME'; Value = [string]$Context.IP; FallbackSource = 'derived value' },
        @{ Key = 'NIC_NAME'; Value = [string]$Context.NIC; FallbackSource = 'derived value' },
        @{ Key = 'VM_DISK_NAME'; Value = [string]$Context.VmDiskName; FallbackSource = 'derived value' }
    )

    $rows = @()
    foreach ($spec in @($specs)) {
        $key = [string]$spec.Key
        $value = ConvertTo-AzVmDisplayValue -Value $spec.Value
        if ([string]::IsNullOrWhiteSpace([string]$key) -or [string]::IsNullOrWhiteSpace([string]$value)) {
            continue
        }

        $rows += [pscustomobject]@{
            Key = [string]$key
            Value = [string]$value
            Source = [string](Resolve-AzVmConfigValueSourceLabel -Key $key -ConfigMap $ConfigMap -ConfigOverrides $ConfigOverrides -FallbackSource ([string]$spec.FallbackSource))
        }
    }

    return @($rows)
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
        SubscriptionSource = ""
        TenantName = ""
        TenantId = ""
        UserName = ""
    }

    $resolvedSubscription = Get-AzVmResolvedSubscriptionContext
    if ($null -ne $resolvedSubscription) {
        $snapshot.SubscriptionId = [string]$resolvedSubscription.SubscriptionId
        $snapshot.SubscriptionName = [string]$resolvedSubscription.SubscriptionName
        $snapshot.TenantId = [string]$resolvedSubscription.TenantId
        $snapshot.SubscriptionSource = [string]$resolvedSubscription.ResolutionSource
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
            -TimeoutSeconds 20 `
            -BypassForcedSubscription
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
        [int]$TimeoutSeconds = 15,
        [switch]$BypassForcedSubscription
    )

    if (-not $AzArgs -or $AzArgs.Count -eq 0) {
        throw "AzArgs is required."
    }

    if ($TimeoutSeconds -lt 1) {
        $TimeoutSeconds = 1
    }

    $azExecutable = Get-AzVmAzCliExecutable
    $resolvedSubscription = Get-AzVmResolvedSubscriptionContext
    $subscriptionId = ''
    if (-not $BypassForcedSubscription -and $null -ne $resolvedSubscription -and -not [string]::IsNullOrWhiteSpace([string]$resolvedSubscription.SubscriptionId)) {
        $subscriptionId = [string]$resolvedSubscription.SubscriptionId
    }

    $job = Start-Job -ScriptBlock {
        param(
            [string]$AzExecutablePath,
            [string]$SubscriptionId,
            [bool]$BypassSubscription,
            [string[]]$InnerArgs
        )

        $argList = @($InnerArgs | ForEach-Object { [string]$_ })
        if (-not $BypassSubscription -and -not [string]::IsNullOrWhiteSpace([string]$SubscriptionId)) {
            $hasSubscriptionArg = $false
            foreach ($argValue in @($argList)) {
                if ([string]::Equals([string]$argValue, '--subscription', [System.StringComparison]::OrdinalIgnoreCase) -or
                    ([string]$argValue).StartsWith('--subscription=', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $hasSubscriptionArg = $true
                    break
                }
            }
            if (-not $hasSubscriptionArg) {
                $argList += @('--subscription', [string]$SubscriptionId)
            }
        }

        $outputLines = & $AzExecutablePath @argList 2>$null
        $outputText = ""
        if ($null -ne $outputLines) {
            $outputText = (@($outputLines) -join [Environment]::NewLine)
        }

        [pscustomobject]@{
            ExitCode = [int]$LASTEXITCODE
            Output = [string]$outputText
        }
    } -ArgumentList $azExecutable, $subscriptionId, ([bool]$BypassForcedSubscription), (,$AzArgs)

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
        SubscriptionSource = "Subscription Source"
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
        $effectiveRows = @(New-AzVmRuntimeConfigurationRows -Platform $Platform -ConfigMap $ConfigMap -ConfigOverrides $ConfigOverrides -Context $Context)
        if ($effectiveRows.Count -gt 0) {
            Write-Host "Effective configuration:"
            foreach ($row in @($effectiveRows)) {
                $observed = Register-AzVmValueObservation -Key ([string]$row.Key) -Value $row.Value
                if (-not [bool]$observed.ShouldPrint) {
                    continue
                }

                Write-Host ("- {0}={1} ({2})" -f [string]$row.Key, [string]$row.Value, [string]$row.Source)
            }
        }
    }
}
