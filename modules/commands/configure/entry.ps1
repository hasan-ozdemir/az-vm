# Configure command entry.

# Handles Invoke-AzVmConfigureCommand.
function Invoke-AzVmConfigureCommand {
    param(
        [hashtable]$Options,
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configBefore = Read-DotEnvFile -Path $envFilePath
    $target = Resolve-AzVmManagedVmTarget `
        -Options $Options `
        -ConfigMap $configBefore `
        -OperationName 'configure' `
        -AutoSelectSingleVm `
        -FailIfMultipleWithoutExplicitVmForExplicitGroup
    $resourceGroup = [string]$target.ResourceGroup
    $vmName = [string]$target.VmName
    $flagPlatform = Get-AzVmConfigureFlagPlatform -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag
    $targetState = Get-AzVmConfigureTargetState -ResourceGroup $resourceGroup -VmName $vmName -ConfigBefore $configBefore
    $actualPlatform = [string]$targetState.Platform

    if (-not [string]::IsNullOrWhiteSpace([string]$flagPlatform) -and -not [string]::Equals([string]$flagPlatform, [string]$actualPlatform, [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-FriendlyError `
            -Detail ("Configure target VM '{0}' in resource group '{1}' is '{2}', but flag '{3}' was requested." -f $vmName, $resourceGroup, $actualPlatform, $flagPlatform) `
            -Code 66 `
            -Summary 'Configure command platform validation failed.' `
            -Hint 'Use the correct platform flag for the selected VM, or omit the flag and let configure read the actual platform.'
    }

    $changes = @(Save-AzVmConfigToDotEnv `
        -EnvFilePath $envFilePath `
        -ConfigBefore $configBefore `
        -PersistMap $targetState.PersistMap `
        -ClearReasonMap $targetState.ClearReasonMap)

    Write-Host ""
    Show-AzVmKeyValueList -Title "Configure target summary:" -Values $targetState.SummaryMap
    Write-Host ""
    if (@($changes).Count -gt 0) {
        Write-Host ".env changes:" -ForegroundColor Green
        foreach ($change in @($changes)) {
            $oldValue = if ([string]::IsNullOrWhiteSpace([string]$change.OldValue)) { "(empty)" } else { [string]$change.OldValue }
            $newValue = if ([string]::IsNullOrWhiteSpace([string]$change.NewValue)) { "(empty)" } else { [string]$change.NewValue }
            $suffix = ''
            if ([string]::Equals([string]$change.ChangeKind, 'cleared', [System.StringComparison]::OrdinalIgnoreCase) -and -not [string]::IsNullOrWhiteSpace([string]$change.Reason)) {
                $suffix = (" [{0}]" -f [string]$change.Reason)
            }
            Write-Host ("- {0}: {1} -> {2}{3}" -f [string]$change.Key, $oldValue, $newValue, $suffix)
        }
    }
    else {
        Write-Host "No .env changes were needed; selected target is already aligned." -ForegroundColor Yellow
    }

    if (@($targetState.SkippedFeatureKeys).Count -gt 0) {
        Write-Host ""
        Write-Host "Feature sync skipped for unreadable keys:" -ForegroundColor Yellow
        foreach ($key in @($targetState.SkippedFeatureKeys)) {
            Write-Host ("- {0}" -f [string]$key)
        }
    }

    Write-Host ""
    Write-Host ("Configure completed successfully for VM '{0}' in resource group '{1}'. No Azure resources were created, updated, or deleted." -f $vmName, $resourceGroup) -ForegroundColor Green
}
