# Contract for the 'update' command.

function Get-AzVmUpdateOptionSpecifications {
    return @(
        (Get-AzVmUpdateAutoOptionSpecification),
        (Get-AzVmUpdatePerfOptionSpecification),
        (Get-AzVmUpdateWindowsOptionSpecification),
        (Get-AzVmUpdateLinuxOptionSpecification),
        (Get-AzVmUpdateHelpOptionSpecification),
        (Get-AzVmUpdateStepToOptionSpecification),
        (Get-AzVmUpdateStepFromOptionSpecification),
        (Get-AzVmUpdateStepOptionSpecification),
        (Get-AzVmSharedSubscriptionIdOptionSpecification),
        (Get-AzVmUpdateGroupOptionSpecification),
        (Get-AzVmUpdateVmNameOptionSpecification)
    )
}
