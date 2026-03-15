# Shared 'user' command option specification.

function Get-AzVmSharedUserOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'user' -TakesValue)
}
