# Contract for the 'group' command.

function Get-AzVmGroupOptionSpecifications {
    return @(
        (Get-AzVmGroupHelpOptionSpecification),
        (Get-AzVmGroupListOptionSpecification),
        (Get-AzVmGroupSelectOptionSpecification)
    )
}
