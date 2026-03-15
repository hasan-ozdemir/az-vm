# Shared 'nested-virtualization' command option specification.

function Get-AzVmSharedNestedVirtualizationOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'nested-virtualization' -TakesValue)
}
