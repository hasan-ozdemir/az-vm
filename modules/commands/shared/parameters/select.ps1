# Shared 'select' command option specification.

function Get-AzVmSharedSelectOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'select')
}
