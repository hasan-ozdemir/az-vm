# Shared 'vm-name' command option specification.

function Get-AzVmSharedVmNameOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'vm-name')
}
