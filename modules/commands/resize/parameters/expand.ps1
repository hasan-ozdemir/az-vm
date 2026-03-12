# 'expand' option binding for 'resize'.

function Get-AzVmResizeExpandOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'expand')
}
