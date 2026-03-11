# Task command runtime helpers.

# Handles Get-AzVmTaskListRows.
function Get-AzVmTaskListRows {
    param(
        [string]$Stage,
        [object[]]$InventoryTasks,
        [switch]$DisabledOnly
    )

    $rows = @()
    foreach ($task in @($InventoryTasks)) {
        if ($null -eq $task) {
            continue
        }

        $enabled = $true
        if ($task.PSObject.Properties.Match('Enabled').Count -gt 0) {
            $enabled = [bool]$task.Enabled
        }

        if ($DisabledOnly) {
            if ($enabled) {
                continue
            }
        }
        elseif (-not $enabled) {
            continue
        }

        $rows += [pscustomobject]@{
            Stage = ("vm-{0}" -f [string]$Stage)
            Number = [int]$task.TaskNumber
            Source = $(if ([string]::Equals([string]$task.Source, 'local', [System.StringComparison]::OrdinalIgnoreCase)) { 'local' } else { 'builtin' })
            TaskType = [string]$task.TaskType
            Priority = [int]$task.Priority
            TimeoutSeconds = [int]$task.TimeoutSeconds
            Status = $(if ($enabled) { 'enabled' } else { 'disabled' })
            DisabledReason = [string]$task.DisabledReason
            Name = [string]$task.Name
            RelativePath = [string]$task.RelativePath
        }
    }

    return @($rows)
}
