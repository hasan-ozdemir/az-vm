# Contract for the 'ssh' command.

function Get-AzVmSshOptionSpecifications {
    return @(
        (Get-AzVmSshPerfOptionSpecification),
        (Get-AzVmSshHelpOptionSpecification),
        (Get-AzVmSharedSubscriptionIdOptionSpecification),
        (Get-AzVmSshGroupOptionSpecification),
        (Get-AzVmSshVmNameOptionSpecification),
        (Get-AzVmSshUserOptionSpecification),
        (Get-AzVmSshTestOptionSpecification)
    )
}
