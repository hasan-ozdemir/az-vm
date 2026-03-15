# Shared 'vm-size' command option specification.

function Get-AzVmSharedVmSizeOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'vm-size' -TakesValue)
}
