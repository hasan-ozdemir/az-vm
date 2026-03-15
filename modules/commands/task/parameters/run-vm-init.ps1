# 'run-vm-init' option binding for 'task'.

function Get-AzVmTaskRunVmInitOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'run-vm-init' -TakesValue)
}
