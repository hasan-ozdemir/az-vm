# Shared 'list' command option specification.

function Get-AzVmSharedListOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'list')
}
