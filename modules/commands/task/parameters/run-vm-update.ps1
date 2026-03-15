# 'run-vm-update' option binding for 'task'.

function Get-AzVmTaskRunVmUpdateOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'run-vm-update' -TakesValue)
}
