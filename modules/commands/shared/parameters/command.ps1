# Shared 'command' command option specification.

function Get-AzVmSharedCommandOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'command' -ShortNames @('c') -TakesValue)
}
