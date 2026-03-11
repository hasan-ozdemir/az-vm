# Resize command entry.

function Invoke-AzVmResizeCommand {
    param(
        [hashtable]$Options,
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    if (Test-AzVmCliOptionPresent -Options $Options -Name 'vm-region') {
        Throw-FriendlyError `
            -Detail "Option '--vm-region' is not supported with resize command." `
            -Code 62 `
            -Summary "Unsupported option for resize command." `
            -Hint "Use move command for region changes."
    }

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $target = Resolve-AzVmManagedVmTarget -Options $Options -ConfigMap $configMap -OperationName 'resize'
    $resourceGroup = [string]$target.ResourceGroup
    $vmName = [string]$target.VmName
    $isDirectRequest = Test-AzVmResizeDirectRequest -Options $Options

    $vmJson = az vm show -g $resourceGroup -n $vmName -o json --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$vmJson)) {
        Throw-FriendlyError `
            -Detail ("VM '{0}' was not found in resource group '{1}'." -f $vmName, $resourceGroup) `
            -Code 62 `
            -Summary "Resize command cannot continue because VM does not exist." `
            -Hint "Select an existing VM or run create first."
    }

    $vmObject = ConvertFrom-JsonCompat -InputObject $vmJson
    $currentRegion = [string]$vmObject.location
    $currentSize = [string]$vmObject.hardwareProfile.vmSize
    $actualPlatform = Get-AzVmPlatformNameFromOsType -OsType ([string]$vmObject.storageProfile.osDisk.osType)
    $vmSizeConfigKey = if ([string]::IsNullOrWhiteSpace([string]$actualPlatform)) { 'VM_SIZE' } else { Get-AzVmPlatformVmConfigKey -Platform $actualPlatform -BaseKey 'VM_SIZE' }

    Assert-AzVmResizePlatformExpectation `
        -ActualPlatform $actualPlatform `
        -WindowsFlag:$WindowsFlag `
        -LinuxFlag:$LinuxFlag `
        -VmName $vmName `
        -ResourceGroup $resourceGroup

    if ([string]::IsNullOrWhiteSpace([string]$currentRegion)) {
        Throw-FriendlyError `
            -Detail ("Resize command could not resolve the Azure region for VM '{0}'." -f $vmName) `
            -Code 62 `
            -Summary "Resize command cannot continue because VM region is unknown." `
            -Hint "Check the VM metadata in Azure, then retry."
    }
    if ([string]::IsNullOrWhiteSpace([string]$currentSize)) {
        Throw-FriendlyError `
            -Detail ("Resize command could not resolve the current VM size for '{0}'." -f $vmName) `
            -Code 62 `
            -Summary "Resize command cannot continue because current VM size is unknown." `
            -Hint "Check the VM metadata in Azure, then retry."
    }

    $targetSize = Resolve-AzVmResizeTargetSize -Options $Options -CurrentRegion $currentRegion -CurrentSize $currentSize -ConfigMap $configMap
    Assert-LocationExists -Location $currentRegion
    Assert-VmSkuAvailableViaRest -Location $currentRegion -VmSize $targetSize

    if ([string]::Equals([string]$targetSize, [string]$currentSize, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host ("No effective resize operation is required. VM size is already '{0}'." -f $targetSize) -ForegroundColor Yellow
        return
    }

    if (-not $isDirectRequest) {
        $approveResize = Confirm-YesNo -PromptText "Continue with VM size change?" -DefaultYes $false
        if (-not $approveResize) {
            Write-Host "Resize command canceled by user." -ForegroundColor Yellow
            return
        }
    }

    Write-Host ("Applying VM size update for '{0}' in '{1}': {2} -> {3}" -f $vmName, $resourceGroup, $currentSize, $targetSize)

    Invoke-TrackedAction -Label ("az vm deallocate -g {0} -n {1}" -f $resourceGroup, $vmName) -Action {
        az vm deallocate -g $resourceGroup -n $vmName -o none --only-show-errors
        Assert-LastExitCode "az vm deallocate"
    } | Out-Null
    $deallocated = Wait-AzVmVmPowerState -ResourceGroup $resourceGroup -VmName $vmName -DesiredPowerState "VM deallocated" -MaxAttempts 18 -DelaySeconds 10
    if (-not $deallocated) {
        Throw-FriendlyError `
            -Detail ("VM '{0}' did not reach deallocated state in expected time." -f $vmName) `
            -Code 62 `
            -Summary "Resize command stopped because VM deallocation was not confirmed." `
            -Hint "Check VM power state in Azure and retry resize."
    }

    Invoke-TrackedAction -Label ("az vm resize -g {0} -n {1} --size {2}" -f $resourceGroup, $vmName, $targetSize) -Action {
        az vm resize -g $resourceGroup -n $vmName --size $targetSize -o none --only-show-errors
        Assert-LastExitCode "az vm resize"
    } | Out-Null

    Invoke-TrackedAction -Label ("az vm start -g {0} -n {1}" -f $resourceGroup, $vmName) -Action {
        az vm start -g $resourceGroup -n $vmName -o none --only-show-errors
        Assert-LastExitCode "az vm start"
    } | Out-Null

    $running = Wait-AzVmVmRunningState -ResourceGroup $resourceGroup -VmName $vmName -MaxAttempts 3 -DelaySeconds 10
    if (-not $running) {
        Throw-FriendlyError `
            -Detail "VM did not return to running state after resize operation." `
            -Code 62 `
            -Summary "Resize command completed with unhealthy VM power state." `
            -Hint "Check VM power state in Azure Portal and start VM manually if needed."
    }

    Set-DotEnvValue -Path $envFilePath -Key $vmSizeConfigKey -Value $targetSize
    $script:ConfigOverrides[$vmSizeConfigKey] = $targetSize

    Write-Host ("Resize completed successfully. VM size is now '{0}'." -f $targetSize) -ForegroundColor Green
}
