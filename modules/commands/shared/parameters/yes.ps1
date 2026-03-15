# Shared 'yes' command option specification.

function Get-AzVmSharedYesOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'yes' -ShortNames @('y'))
}
