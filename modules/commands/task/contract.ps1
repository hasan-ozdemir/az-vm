# Contract for the 'task' command.

function Get-AzVmTaskOptionSpecifications {
    return @(
        (Get-AzVmTaskPerfOptionSpecification),
        (Get-AzVmTaskHelpOptionSpecification),
        (Get-AzVmTaskListOptionSpecification),
        (Get-AzVmTaskVmInitOptionSpecification),
        (Get-AzVmTaskVmUpdateOptionSpecification),
        (Get-AzVmTaskDisabledOptionSpecification),
        (Get-AzVmTaskWindowsOptionSpecification),
        (Get-AzVmTaskLinuxOptionSpecification)
    )
}
