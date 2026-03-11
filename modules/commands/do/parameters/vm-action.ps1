# 'vm-action' option binding for 'do'.

function Get-AzVmDoVmActionOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'vm-action' -Validate {
        param([hashtable]$Options)
        if (Test-AzVmCliOptionPresent -Options $Options -Name 'vm-action') {
            [void](Resolve-AzVmDoActionName -RawValue ([string](Get-AzVmCliOptionText -Options $Options -Name 'vm-action')) -AllowEmpty)
        }
    })
}
