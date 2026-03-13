# Contract for the 'delete' command.

function Get-AzVmDeleteOptionSpecifications {
    return @(
        (Get-AzVmDeleteAutoOptionSpecification),
        (Get-AzVmDeletePerfOptionSpecification),
        (Get-AzVmDeleteHelpOptionSpecification),
        (Get-AzVmSharedSubscriptionIdOptionSpecification),
        (Get-AzVmDeleteTargetOptionSpecification),
        (Get-AzVmDeleteGroupOptionSpecification),
        (Get-AzVmDeleteYesOptionSpecification)
    )
}
