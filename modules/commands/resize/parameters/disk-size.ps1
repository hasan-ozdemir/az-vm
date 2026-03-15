# 'disk-size' option binding for 'resize'.

function Get-AzVmResizeDiskSizeOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'disk-size' -TakesValue)
}
