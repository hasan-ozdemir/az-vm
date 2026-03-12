# 'destructive rebuild' option binding for 'create'.

function Get-AzVmCreateRenewOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'destructive rebuild')
}
