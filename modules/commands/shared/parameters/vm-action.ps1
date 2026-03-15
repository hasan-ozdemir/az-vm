# Shared 'vm-action' command option specification.

function Get-AzVmSharedVmActionOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'vm-action' -TakesValue)
}
