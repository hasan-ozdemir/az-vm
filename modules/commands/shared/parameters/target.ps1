# Shared 'target' command option specification.

function Get-AzVmSharedTargetOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'target')
}
