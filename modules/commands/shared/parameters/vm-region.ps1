# Shared 'vm-region' command option specification.

function Get-AzVmSharedVmRegionOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'vm-region' -TakesValue)
}
