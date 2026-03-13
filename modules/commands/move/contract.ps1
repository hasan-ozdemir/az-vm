# Contract for the 'move' command.

function Get-AzVmMoveOptionSpecifications {
    return @(
        (Get-AzVmMovePerfOptionSpecification),
        (Get-AzVmMoveHelpOptionSpecification),
        (Get-AzVmSharedSubscriptionIdOptionSpecification),
        (Get-AzVmMoveGroupOptionSpecification),
        (Get-AzVmMoveVmNameOptionSpecification),
        (Get-AzVmMoveVmRegionOptionSpecification)
    )
}
