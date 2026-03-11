# Contract for the 'set' command.

function Get-AzVmSetOptionSpecifications {
    return @(
        (Get-AzVmSetPerfOptionSpecification),
        (Get-AzVmSetHelpOptionSpecification),
        (Get-AzVmSetGroupOptionSpecification),
        (Get-AzVmSetVmNameOptionSpecification),
        (Get-AzVmSetHibernationOptionSpecification),
        (Get-AzVmSetNestedVirtualizationOptionSpecification)
    )
}
