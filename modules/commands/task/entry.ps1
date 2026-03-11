# Task command entry.

# Handles Invoke-AzVmTaskCommand.
function Invoke-AzVmTaskCommand {
    param(
        [hashtable]$Options,
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    if (-not (Test-AzVmCliOptionPresent -Options $Options -Name 'list')) {
        Show-AzVmCommandHelp -Topic 'task'
        Throw-FriendlyError `
            -Detail "Task command currently supports only the --list path." `
            -Code 2 `
            -Summary "Task command usage is incomplete." `
            -Hint "Run az-vm task --list [--vm-init] [--vm-update] [--disabled]."
    }

    $runtime = Initialize-AzVmTaskCommandRuntimeContext -AutoMode:$AutoMode -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag
    $includeInit = Test-AzVmCliOptionPresent -Options $Options -Name 'vm-init'
    $includeUpdate = Test-AzVmCliOptionPresent -Options $Options -Name 'vm-update'
    if (-not $includeInit -and -not $includeUpdate) {
        $includeInit = $true
        $includeUpdate = $true
    }

    $disabledOnly = Test-AzVmCliOptionPresent -Options $Options -Name 'disabled'
    $rows = @()

    if ($includeInit) {
        $initCatalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath ([string]$runtime.VmInitTaskDir) -Platform ([string]$runtime.Platform) -Stage 'init' -SuppressSkipMessages
        $rows += @(Get-AzVmTaskListRows -Stage 'init' -InventoryTasks @($initCatalog.InventoryTasks) -DisabledOnly:$disabledOnly)
    }
    if ($includeUpdate) {
        $updateCatalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath ([string]$runtime.VmUpdateTaskDir) -Platform ([string]$runtime.Platform) -Stage 'update' -SuppressSkipMessages
        $rows += @(Get-AzVmTaskListRows -Stage 'update' -InventoryTasks @($updateCatalog.InventoryTasks) -DisabledOnly:$disabledOnly)
    }

    $rows = @(
        $rows | Sort-Object `
            @{ Expression = { if ([string]::Equals([string]$_.Stage, 'vm-init', [System.StringComparison]::OrdinalIgnoreCase)) { 1 } else { 2 } } }, `
            @{ Expression = { [int]$_.Priority } }, `
            @{ Expression = { [int]$_.Number } }, `
            @{ Expression = { [string]$_.Name } }
    )

    $statusLabel = if ($disabledOnly) { 'disabled' } else { 'active' }
    Write-Host ("Discovered {0} {1} tasks for platform '{2}':" -f $statusLabel, ($(if ($includeInit -and $includeUpdate) { 'init/update' } elseif ($includeInit) { 'init' } else { 'update' })), [string]$runtime.Platform) -ForegroundColor Cyan
    if (@($rows).Count -eq 0) {
        Write-Host "- (none)"
        return [pscustomobject]@{
            Platform = [string]$runtime.Platform
            Rows = @()
            DisabledOnly = [bool]$disabledOnly
        }
    }

    @($rows) |
        Select-Object Stage, Number, Source, TaskType, Priority, TimeoutSeconds, Status, DisabledReason, Name, RelativePath |
        Format-Table -AutoSize |
        Out-Host

    return [pscustomobject]@{
        Platform = [string]$runtime.Platform
        Rows = @($rows)
        DisabledOnly = [bool]$disabledOnly
    }
}
