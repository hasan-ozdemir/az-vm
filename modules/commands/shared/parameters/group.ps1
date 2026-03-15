# Shared 'group' command option specification.

function Get-AzVmSharedGroupOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'group' -ShortNames @('g') -TakesValue)
}
