# Contract for the 'exec' command.

function Get-AzVmExecOptionSpecifications {
    return @(
        (Get-AzVmExecPerfOptionSpecification),
        (Get-AzVmExecHelpOptionSpecification),
        (Get-AzVmSharedSubscriptionIdOptionSpecification),
        (Get-AzVmExecGroupOptionSpecification),
        (Get-AzVmExecVmNameOptionSpecification),
        (Get-AzVmExecCommandContentOptionSpecification),
        (Get-AzVmExecQuietOptionSpecification)
    )
}
