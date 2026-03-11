# Create command runtime helpers.

function New-AzVmCreateCommandRuntime {
    param(
        [hashtable]$Options,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    $actionPlan = Resolve-AzVmActionPlan -CommandName 'create' -Options $Options
    $createOverrides = @{ RESOURCE_GROUP = '' }
    $createVmName = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-name')
    if (-not [string]::IsNullOrWhiteSpace([string]$createVmName)) {
        $createOverrides['VM_NAME'] = $createVmName.Trim()
    }

    return [pscustomobject]@{
        ActionPlan = $actionPlan
        InitialConfigOverrides = $createOverrides
        WindowsFlag = [bool]$WindowsFlag
        LinuxFlag = [bool]$LinuxFlag
    }
}
