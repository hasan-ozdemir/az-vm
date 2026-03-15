# 'vm-init-task' option binding for 'task'.

function Get-AzVmTaskVmInitTaskOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'vm-init-task' -TakesValue)
}
