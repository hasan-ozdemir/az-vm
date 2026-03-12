# Update command runtime helpers.

function New-AzVmUpdateCommandRuntime {
    param(
        [hashtable]$Options,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag,
        [switch]$AutoMode
    )

    $actionPlan = Resolve-AzVmActionPlan -CommandName 'update' -Options $Options
    $envFilePath = Join-Path (Get-AzVmRepoRoot) '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $defaultResourceGroup = [string](Get-ConfigValue -Config $configMap -Key 'RESOURCE_GROUP' -DefaultValue '')
    $vmNameOverride = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-name')
    $vmName = if (-not [string]::IsNullOrWhiteSpace([string]$vmNameOverride)) { $vmNameOverride.Trim() } else { [string](Get-ConfigValue -Config $configMap -Key 'VM_NAME' -DefaultValue '') }
    $targetResourceGroup = Resolve-AzVmTargetResourceGroup -Options $Options -AutoMode:$AutoMode -DefaultResourceGroup $defaultResourceGroup -VmName $vmName -OperationName 'update'
    $resolvedVmName = [string](Resolve-AzVmTargetVmName -ResourceGroup $targetResourceGroup -DefaultVmName $vmName -AutoMode:$AutoMode -OperationName 'update')
    if (-not (Test-AzVmAzResourceExists -AzArgs @('vm', 'show', '-g', $targetResourceGroup, '-n', $resolvedVmName))) {
        Throw-FriendlyError `
            -Detail ("VM '{0}' was not found in managed resource group '{1}'." -f $resolvedVmName, $targetResourceGroup) `
            -Code 66 `
            -Summary "Update command cannot continue because the target VM does not exist." `
            -Hint "Run create first, or choose an existing managed VM."
    }

    $updateOverrides = @{
        RESOURCE_GROUP = $targetResourceGroup
        VM_NAME = $resolvedVmName
    }

    return [pscustomobject]@{
        ActionPlan = $actionPlan
        InitialConfigOverrides = $updateOverrides
        WindowsFlag = [bool]$WindowsFlag
        LinuxFlag = [bool]$LinuxFlag
    }
}
