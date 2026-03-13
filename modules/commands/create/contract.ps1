# Contract for the 'create' command.

function Get-AzVmCreateOptionSpecifications {
    return @(
        (Get-AzVmCreateAutoOptionSpecification),
        (Get-AzVmCreatePerfOptionSpecification),
        (Get-AzVmCreateWindowsOptionSpecification),
        (Get-AzVmCreateLinuxOptionSpecification),
        (Get-AzVmCreateHelpOptionSpecification),
        (Get-AzVmCreateStepToOptionSpecification),
        (Get-AzVmCreateStepFromOptionSpecification),
        (Get-AzVmCreateStepOptionSpecification),
        (Get-AzVmCreateRenewOptionSpecification),
        (Get-AzVmCreateVmNameOptionSpecification),
        (Get-AzVmCreateVmRegionOptionSpecification),
        (Get-AzVmCreateVmSizeOptionSpecification)
    )
}
