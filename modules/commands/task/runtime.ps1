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

function Resolve-AzVmTaskCommandMode {
    param([hashtable]$Options)

    $actions = @(
        @{ Name = 'list'; Present = (Test-AzVmCliOptionPresent -Options $Options -Name 'list') }
        @{ Name = 'save-app-state'; Present = (Test-AzVmCliOptionPresent -Options $Options -Name 'save-app-state') }
        @{ Name = 'restore-app-state'; Present = (Test-AzVmCliOptionPresent -Options $Options -Name 'restore-app-state') }
    )

    $presentActions = @($actions | Where-Object { [bool]$_.Present })
    if (@($presentActions).Count -lt 1) {
        Throw-FriendlyError `
            -Detail "Task command requires one action path." `
            -Code 2 `
            -Summary "Task command usage is incomplete." `
            -Hint "Use az-vm task --list, az-vm task --save-app-state ..., or az-vm task --restore-app-state ...."
    }
    if (@($presentActions).Count -gt 1) {
        Throw-FriendlyError `
            -Detail "Task command received conflicting action options." `
            -Code 2 `
            -Summary "Only one task action can run at a time." `
            -Hint "Use exactly one of --list, --save-app-state, or --restore-app-state."
    }

    return [string]$presentActions[0].Name
}

function Resolve-AzVmTaskStageSelection {
    param(
        [hashtable]$Options,
        [switch]$AutoMode
    )

    $hasVmInit = Test-AzVmCliOptionPresent -Options $Options -Name 'vm-init'
    $hasVmUpdate = Test-AzVmCliOptionPresent -Options $Options -Name 'vm-update'
    $hasInitTask = (Test-AzVmCliOptionPresent -Options $Options -Name 'vm-init-task')
    $hasUpdateTask = (Test-AzVmCliOptionPresent -Options $Options -Name 'vm-update-task')

    if (($hasVmInit -and $hasVmUpdate) -or ($hasInitTask -and $hasUpdateTask)) {
        Throw-FriendlyError `
            -Detail "Task stage selectors are conflicting." `
            -Code 2 `
            -Summary "Only one task stage can be selected." `
            -Hint "Use one init selector or one update selector, not both."
    }

    if ($hasVmInit -or $hasVmUpdate) {
        Throw-FriendlyError `
            -Detail "Task save/restore must use task selectors, not inventory stage selectors." `
            -Code 2 `
            -Summary "Task stage selection is invalid." `
            -Hint "Use --vm-init-task=<task-number|task-name> or --vm-update-task=<task-number|task-name>."
    }

    if ($hasInitTask) {
        $requested = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-init-task')
        return [pscustomobject]@{ Stage = 'init'; Requested = $requested }
    }
    if ($hasUpdateTask) {
        $requested = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-update-task')
        return [pscustomobject]@{ Stage = 'update'; Requested = $requested }
    }

    Throw-FriendlyError `
        -Detail "Task save/restore requires one stage selector." `
        -Code 2 `
        -Summary "Task stage selector is missing." `
        -Hint "Use --vm-init-task=<task-number|task-name> or --vm-update-task=<task-number|task-name>."
}

function Assert-AzVmTaskCommandOptionScope {
    param(
        [string]$Mode,
        [hashtable]$Options
    )

    if ([string]::Equals($Mode, 'list', [System.StringComparison]::OrdinalIgnoreCase)) {
        foreach ($optionName in @('group', 'vm-name', 'subscription-id', 'vm-init-task', 'vm-update-task')) {
            if (Test-AzVmCliOptionPresent -Options $Options -Name $optionName) {
                Throw-FriendlyError `
                    -Detail ("Task list mode does not support --{0}." -f [string]$optionName) `
                    -Code 2 `
                    -Summary "Task list received an unsupported option." `
                    -Hint "Use only --list with --vm-init/--vm-update/--disabled plus optional --windows/--linux."
            }
        }

        return
    }

    foreach ($optionName in @('disabled', 'vm-init', 'vm-update')) {
        if (Test-AzVmCliOptionPresent -Options $Options -Name $optionName) {
            Throw-FriendlyError `
                -Detail ("Task app-state maintenance does not support --{0}." -f [string]$optionName) `
                -Code 2 `
                -Summary "Task app-state mode received an unsupported option." `
                -Hint "Use --save-app-state or --restore-app-state with --vm-init-task/--vm-update-task plus optional target selectors."
        }
    }
}

function Resolve-AzVmTaskBlockForMaintenance {
    param(
        [pscustomobject]$Runtime,
        [hashtable]$Options,
        [switch]$AutoMode
    )

    $selection = Resolve-AzVmTaskStageSelection -Options $Options -AutoMode:$AutoMode
    $stage = [string]$selection.Stage
    $requested = [string]$selection.Requested

    if ($stage -eq 'init') {
        $catalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath ([string]$Runtime.Context.VmInitTaskDir) -Platform ([string]$Runtime.Platform) -Stage 'init'
        $tasks = Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks @($catalog.ActiveTasks) -Context $Runtime.Context
        $selectedTask = Resolve-AzVmTaskSelection -TaskBlocks $tasks -TaskNumberOrName $requested -Stage 'init' -AutoMode:$AutoMode
        return [pscustomobject]@{ Stage = 'init'; TaskBlock = $selectedTask }
    }

    $catalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath ([string]$Runtime.Context.VmUpdateTaskDir) -Platform ([string]$Runtime.Platform) -Stage 'update'
    $tasks = Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks @($catalog.ActiveTasks) -Context $Runtime.Context
    $selectedTask = Resolve-AzVmTaskSelection -TaskBlocks $tasks -TaskNumberOrName $requested -Stage 'update' -AutoMode:$AutoMode
    return [pscustomobject]@{ Stage = 'update'; TaskBlock = $selectedTask }
}
