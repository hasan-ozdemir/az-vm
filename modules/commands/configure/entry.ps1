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
    $defaultResourceGroup = [string](Get-ConfigValue -Config $configBefore -Key 'RESOURCE_GROUP' -DefaultValue '')
    $vmName = [string](Get-ConfigValue -Config $configBefore -Key 'VM_NAME' -DefaultValue '')
    $selectedResourceGroup = Resolve-AzVmTargetResourceGroup `
        -Options $Options `
        -AutoMode:$AutoMode `
        -DefaultResourceGroup $defaultResourceGroup `
        -VmName $vmName `
        -OperationName 'configure'

    $runtime = $null
    $context = $null
    $platform = ''
    $step1Result = $null

    $step1Result = Invoke-Step 'Step 1/3 - configuration values will be resolved...' {
        $runtimeLocal = Initialize-AzVmCommandRuntimeContext `
            -AutoMode:$AutoMode `
            -WindowsFlag:$WindowsFlag `
            -LinuxFlag:$LinuxFlag `
            -ConfigMapOverrides @{ RESOURCE_GROUP = $selectedResourceGroup } `
            -PersistGeneratedResourceGroup
        [pscustomobject]@{
            Runtime = $runtimeLocal
            Context = $runtimeLocal.Context
            Platform = [string]$runtimeLocal.Platform
        }
    }
    if ($null -eq $step1Result -or @($step1Result).Count -eq 0) {
        Throw-FriendlyError `
            -Detail "Interactive configuration step did not produce runtime context." `
            -Code 64 `
            -Summary "Configure command could not continue after step 1." `
            -Hint "Rerun 'az-vm configure' and verify group selection."
    }
    if ($step1Result -is [System.Array]) {
        $step1Result = $step1Result[-1]
    }
    $runtime = $step1Result.Runtime
    $context = $step1Result.Context
    $platform = [string]$step1Result.Platform
    if ($null -eq $context) {
        Throw-FriendlyError `
            -Detail "Step 1 returned an empty context object." `
            -Code 64 `
            -Summary "Configure command could not continue after step 1." `
            -Hint "Rerun 'az-vm configure' and verify interactive selections."
    }
    if ([string]::IsNullOrWhiteSpace([string]$context.AzLocation)) {
        Throw-FriendlyError `
            -Detail "Step 1 returned empty AZ_LOCATION in context." `
            -Code 64 `
            -Summary "Configure command could not continue because region was not captured." `
            -Hint "Select a valid region in step 1 and retry."
    }

    Invoke-Step 'Step 2/3 - region, image, and VM size availability will be checked...' {
        Invoke-AzVmPrecheckStep -Context $context
    }

    Invoke-Step 'Step 3/3 - resource group preview will be displayed...' {
        $null = Invoke-AzVmResourceGroupPreviewStep -Context $context
    }

    $persistMap = Get-AzVmConfigPersistenceMap -Platform $platform -Context $context
    $changes = Save-AzVmConfigToDotEnv -EnvFilePath ([string]$runtime.EnvFilePath) -ConfigBefore $configBefore -PersistMap $persistMap
    $configAfter = Read-DotEnvFile -Path ([string]$runtime.EnvFilePath)

    Write-Host ""
    Show-AzVmKeyValueList -Title "Existing .env values (before configure):" -Values $configBefore
    Write-Host ""
    Show-AzVmKeyValueList -Title "Resolved configuration values:" -Values $context
    Write-Host ""
    Show-AzVmKeyValueList -Title ".env values after configure:" -Values $configAfter
    Write-Host ""
    if (@($changes).Count -gt 0) {
        Write-Host "Saved .env changes:" -ForegroundColor Green
        foreach ($change in @($changes)) {
            $oldValue = if ([string]::IsNullOrWhiteSpace([string]$change.OldValue)) { "(empty)" } else { [string]$change.OldValue }
            $newValue = if ([string]::IsNullOrWhiteSpace([string]$change.NewValue)) { "(empty)" } else { [string]$change.NewValue }
            Write-Host ("- {0}: {1} -> {2}" -f [string]$change.Key, $oldValue, $newValue)
        }
    }
    else {
        Write-Host "No .env value changes were needed; current values are already aligned." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Configure completed successfully. No Azure resources were created, updated, or deleted." -ForegroundColor Green
    Write-Host "Next actions:" -ForegroundColor Cyan
    Write-Host "- az-vm create --auto"
    Write-Host "- az-vm create --to-step=vm-deploy"
}
