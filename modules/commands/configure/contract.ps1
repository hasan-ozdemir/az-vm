# Contract for the 'configure' command.

function Get-AzVmConfigureOptionSpecifications {
    return @(
        (Get-AzVmConfigurePerfOptionSpecification),
        (Get-AzVmConfigureHelpOptionSpecification)
    )
}
