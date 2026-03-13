# Contract for the 'exec' command.

function Get-AzVmExecOptionSpecifications {
    return @(
        (Get-AzVmExecPerfOptionSpecification),
        (Get-AzVmExecWindowsOptionSpecification),
        (Get-AzVmExecLinuxOptionSpecification),
        (Get-AzVmExecHelpOptionSpecification),
        (Get-AzVmSharedSubscriptionIdOptionSpecification),
        (Get-AzVmExecGroupOptionSpecification),
        (Get-AzVmExecVmNameOptionSpecification),
        (Get-AzVmExecInitTaskOptionSpecification),
        (Get-AzVmExecUpdateTaskOptionSpecification)
    )
}
