# Contract for the 'list' command.

function Get-AzVmListOptionSpecifications {
    return @(
        (Get-AzVmListPerfOptionSpecification),
        (Get-AzVmListHelpOptionSpecification),
        (Get-AzVmListGroupOptionSpecification),
        (Get-AzVmListTypeOptionSpecification)
    )
}
