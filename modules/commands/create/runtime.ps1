# Create command runtime helpers.

function Resolve-AzVmCreateInitialResourceGroupOverride {
    param(
        [hashtable]$ConfigMap,
        [string]$VmName
    )

    $configuredResourceGroup = [string](Get-ConfigValue -Config $ConfigMap -Key 'RESOURCE_GROUP' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace([string]$configuredResourceGroup)) {
        return ''
    }

    $resolvedVmName = [string]$VmName
    if ([string]::IsNullOrWhiteSpace([string]$resolvedVmName)) {
        return ''
    }

    $matches = @(Get-AzVmManagedVmMatchRows -VmName $resolvedVmName)
    if (@($matches).Count -ne 1) {
        return ''
    }

    return [string]$matches[0].ResourceGroup
}

function New-AzVmCreateCommandRuntime {
    param(
        [hashtable]$Options,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    $actionPlan = Resolve-AzVmActionPlan -CommandName 'create' -Options $Options
    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $createOverrides = @{}
    $createVmName = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-name')
    $effectiveVmName = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$createVmName)) {
        $effectiveVmName = $createVmName.Trim()
        $createOverrides['VM_NAME'] = $effectiveVmName
    }
    else {
        $effectiveVmName = [string](Get-ConfigValue -Config $configMap -Key 'VM_NAME' -DefaultValue '')
    }

    $reuseResourceGroup = Resolve-AzVmCreateInitialResourceGroupOverride -ConfigMap $configMap -VmName $effectiveVmName
    if (-not [string]::IsNullOrWhiteSpace([string]$reuseResourceGroup)) {
        $createOverrides['RESOURCE_GROUP'] = $reuseResourceGroup
    }

    return [pscustomobject]@{
        ActionPlan = $actionPlan
        InitialConfigOverrides = $createOverrides
        RenewMode = (Get-AzVmCliOptionBool -Options $Options -Name 'destructive rebuild' -DefaultValue $false)
        WindowsFlag = [bool]$WindowsFlag
        LinuxFlag = [bool]$LinuxFlag
    }
}
