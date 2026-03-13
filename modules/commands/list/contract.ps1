# Contract for the 'list' command.

function Get-AzVmListOptionSpecifications {
    return @(
        (Get-AzVmListPerfOptionSpecification),
        (Get-AzVmListHelpOptionSpecification),
        (Get-AzVmSharedSubscriptionIdOptionSpecification),
        (Get-AzVmListGroupOptionSpecification),
        (Get-AzVmListTypeOptionSpecification)
    )
}
