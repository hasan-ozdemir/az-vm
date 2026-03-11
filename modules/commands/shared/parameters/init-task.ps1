# Shared 'init-task' command option specification.

function Get-AzVmSharedInitTaskOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'init-task')
}
