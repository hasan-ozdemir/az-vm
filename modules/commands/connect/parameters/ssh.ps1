# 'ssh' option binding for 'connect'.

function Get-AzVmConnectSshOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'ssh')
}
