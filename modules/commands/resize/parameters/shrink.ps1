# 'shrink' option binding for 'resize'.

function Get-AzVmResizeShrinkOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'shrink')
}
