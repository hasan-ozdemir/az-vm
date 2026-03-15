# 'rdp' option binding for 'connect'.

function Get-AzVmConnectRdpOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'rdp')
}
