# Shared 'update-task' command option specification.

function Get-AzVmSharedUpdateTaskOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'update-task')
}
