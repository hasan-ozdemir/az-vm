# Contract for the 'set' command.

function Get-AzVmSetOptionSpecifications {
    return @(
        (Get-AzVmSetPerfOptionSpecification),
        (Get-AzVmSetHelpOptionSpecification),
        (Get-AzVmSharedSubscriptionIdOptionSpecification),
        (Get-AzVmSetGroupOptionSpecification),
        (Get-AzVmSetVmNameOptionSpecification),
        (Get-AzVmSetHibernationOptionSpecification),
        (Get-AzVmSetNestedVirtualizationOptionSpecification)
    )
}
