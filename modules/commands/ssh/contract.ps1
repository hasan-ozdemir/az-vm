# Contract for the 'ssh' command.

function Get-AzVmSshOptionSpecifications {
    return @(
        (Get-AzVmSshPerfOptionSpecification),
        (Get-AzVmSshHelpOptionSpecification),
        (Get-AzVmSshGroupOptionSpecification),
        (Get-AzVmSshVmNameOptionSpecification),
        (Get-AzVmSshUserOptionSpecification),
        (Get-AzVmSshTestOptionSpecification)
    )
}
