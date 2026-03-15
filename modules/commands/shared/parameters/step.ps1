# Shared 'step' command option specification.

function Get-AzVmSharedStepOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'step' -TakesValue)
}
