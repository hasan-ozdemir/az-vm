# Contract for the 'configure' command.

function Get-AzVmConfigureOptionSpecifications {
    return @(
        (Get-AzVmConfigurePerfOptionSpecification),
        (Get-AzVmConfigureWindowsOptionSpecification),
        (Get-AzVmConfigureLinuxOptionSpecification),
        (Get-AzVmConfigureHelpOptionSpecification),
        (Get-AzVmConfigureGroupOptionSpecification)
    )
}
