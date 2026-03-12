# Contract for the 'resize' command.

function Get-AzVmResizeOptionSpecifications {
    return @(
        (Get-AzVmResizePerfOptionSpecification),
        (Get-AzVmResizeHelpOptionSpecification),
        (Get-AzVmResizeGroupOptionSpecification),
        (Get-AzVmResizeVmNameOptionSpecification),
        (Get-AzVmResizeVmSizeOptionSpecification),
        (Get-AzVmResizeDiskSizeOptionSpecification),
        (Get-AzVmResizeExpandOptionSpecification),
        (Get-AzVmResizeShrinkOptionSpecification),
        (Get-AzVmResizeWindowsOptionSpecification),
        (Get-AzVmResizeLinuxOptionSpecification)
    )
}
