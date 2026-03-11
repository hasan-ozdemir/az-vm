# Contract for the 'create' command.

function Get-AzVmCreateOptionSpecifications {
    return @(
        (Get-AzVmCreateAutoOptionSpecification),
        (Get-AzVmCreatePerfOptionSpecification),
        (Get-AzVmCreateWindowsOptionSpecification),
        (Get-AzVmCreateLinuxOptionSpecification),
        (Get-AzVmCreateHelpOptionSpecification),
        (Get-AzVmCreateToStepOptionSpecification),
        (Get-AzVmCreateFromStepOptionSpecification),
        (Get-AzVmCreateSingleStepOptionSpecification),
        (Get-AzVmCreateVmNameOptionSpecification)
    )
}
