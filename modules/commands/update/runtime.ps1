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
    $updateOverrides = @{ RESOURCE_GROUP = $targetResourceGroup }
    if (-not [string]::IsNullOrWhiteSpace([string]$vmNameOverride)) {
        $updateOverrides['VM_NAME'] = $vmNameOverride.Trim()
    }

    return [pscustomobject]@{
        ActionPlan = $actionPlan
        InitialConfigOverrides = $updateOverrides
        WindowsFlag = [bool]$WindowsFlag
        LinuxFlag = [bool]$LinuxFlag
    }
}
