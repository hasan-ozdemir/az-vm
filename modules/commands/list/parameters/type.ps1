# 'type' option binding for 'list'.

function Get-AzVmListTypeOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'type' -TakesValue -Validate {
        param([hashtable]$Options)
        [void](Resolve-AzVmListRequestedTypes -Options $Options)
    })
}
