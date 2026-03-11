# Shared 'single-step' command option specification.

function Get-AzVmSharedSingleStepOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'single-step')
}
