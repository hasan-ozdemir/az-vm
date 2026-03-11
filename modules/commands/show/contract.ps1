# Contract for the 'show' command.

function Get-AzVmShowOptionSpecifications {
    return @(
        (Get-AzVmShowPerfOptionSpecification),
        (Get-AzVmShowHelpOptionSpecification),
        (Get-AzVmShowGroupOptionSpecification)
    )
}
