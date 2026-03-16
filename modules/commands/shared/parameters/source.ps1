# Shared 'source' command option specification.

function Get-AzVmSharedSourceOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'source' -TakesValue)
}
