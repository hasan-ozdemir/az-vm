# Contract for the 'do' command.

function Get-AzVmDoOptionSpecifications {
    return @(
        (Get-AzVmDoPerfOptionSpecification),
        (Get-AzVmDoHelpOptionSpecification),
        (Get-AzVmSharedSubscriptionIdOptionSpecification),
        (Get-AzVmDoGroupOptionSpecification),
        (Get-AzVmDoVmNameOptionSpecification),
        (Get-AzVmDoVmActionOptionSpecification)
    )
}
