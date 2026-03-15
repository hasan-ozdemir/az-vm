# Shared 'step-from' command option specification.

function Get-AzVmSharedStepFromOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'step-from' -TakesValue)
}
