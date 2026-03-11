# Contract for the 'update' command.

function Get-AzVmUpdateOptionSpecifications {
    return @(
        (Get-AzVmUpdateAutoOptionSpecification),
        (Get-AzVmUpdatePerfOptionSpecification),
        (Get-AzVmUpdateWindowsOptionSpecification),
        (Get-AzVmUpdateLinuxOptionSpecification),
        (Get-AzVmUpdateHelpOptionSpecification),
        (Get-AzVmUpdateToStepOptionSpecification),
        (Get-AzVmUpdateFromStepOptionSpecification),
        (Get-AzVmUpdateSingleStepOptionSpecification),
        (Get-AzVmUpdateGroupOptionSpecification),
        (Get-AzVmUpdateVmNameOptionSpecification)
    )
}
