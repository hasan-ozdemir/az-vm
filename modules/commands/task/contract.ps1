# Contract for the 'task' command.

function Get-AzVmTaskOptionSpecifications {
    return @(
        (Get-AzVmTaskPerfOptionSpecification),
        (Get-AzVmTaskHelpOptionSpecification),
        (Get-AzVmTaskListOptionSpecification),
        (Get-AzVmTaskSaveAppStateOptionSpecification),
        (Get-AzVmTaskRestoreAppStateOptionSpecification),
        (Get-AzVmTaskRunVmInitOptionSpecification),
        (Get-AzVmTaskRunVmUpdateOptionSpecification),
        (Get-AzVmTaskVmInitOptionSpecification),
        (Get-AzVmTaskVmUpdateOptionSpecification),
        (Get-AzVmTaskVmInitTaskOptionSpecification),
        (Get-AzVmTaskVmUpdateTaskOptionSpecification),
        (Get-AzVmTaskDisabledOptionSpecification),
        (Get-AzVmTaskGroupOptionSpecification),
        (Get-AzVmTaskVmNameOptionSpecification),
        (Get-AzVmTaskSubscriptionIdOptionSpecification),
        (Get-AzVmTaskWindowsOptionSpecification),
        (Get-AzVmTaskLinuxOptionSpecification)
    )
}
