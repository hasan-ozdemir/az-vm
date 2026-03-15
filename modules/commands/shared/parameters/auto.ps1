# Shared 'auto' command option specification.

function Get-AzVmSharedAutoOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'auto' -ShortNames @('a'))
}
