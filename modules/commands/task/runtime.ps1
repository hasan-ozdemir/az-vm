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

# Handles Resolve-AzVmTaskSelection.
function Resolve-AzVmTaskSelection {
    param(
        [object[]]$TaskBlocks,
        [string]$TaskNumberOrName,
        [string]$Stage,
        [switch]$AutoMode
    )

    $allTasks = @($TaskBlocks)
    if ($allTasks.Count -eq 0) {
        Throw-FriendlyError `
            -Detail ("No active {0} tasks were found." -f $Stage) `
            -Code 60 `
            -Summary "Task list is empty." `
            -Hint ("Add files under the '{0}' task directory." -f $Stage)
    }

    $selectedToken = if ($null -eq $TaskNumberOrName) { '' } else { [string]$TaskNumberOrName }
    $selectedToken = $selectedToken.Trim()
    if ([string]::IsNullOrWhiteSpace($selectedToken)) {
        if ($AutoMode) {
            Throw-FriendlyError `
                -Detail ("Option '--run-vm-{0}' requires a value in auto mode." -f $Stage) `
                -Code 60 `
                -Summary "Task selection is required in auto mode." `
                -Hint ("Provide --run-vm-{0} <task-number>." -f $Stage)
        }

        Write-Host ("Available {0} tasks:" -f $Stage) -ForegroundColor Cyan
        for ($i = 0; $i -lt $allTasks.Count; $i++) {
            Write-Host ("{0}. {1}" -f ($i + 1), [string]$allTasks[$i].Name)
        }
        while ($true) {
            $pickRaw = Read-Host ("Enter {0} task number" -f $Stage)
            if ($pickRaw -match '^\d+$') {
                $pickNumber = [int]$pickRaw
                if ($pickNumber -ge 1 -and $pickNumber -le $allTasks.Count) {
                    return $allTasks[$pickNumber - 1]
                }
            }
            Write-Host "Invalid task selection. Please enter a valid number." -ForegroundColor Yellow
        }
    }

    $selectedTask = $null
    if ($selectedToken -match '^\d+$') {
        $requestedTaskNumber = [int]$selectedToken
        $selectedTask = @(
            $allTasks |
                Where-Object {
                    $candidateTaskNumber = -1
                    if ($_.PSObject.Properties.Match('TaskNumber').Count -gt 0 -and $null -ne $_.TaskNumber) {
                        $candidateTaskNumber = [int]$_.TaskNumber
                    }
                    elseif (([string]$_.Name) -match '^(?<n>\d{2,5})-') {
                        $candidateTaskNumber = [int]$Matches.n
                    }

                    $candidateTaskNumber -eq $requestedTaskNumber
                } |
                Select-Object -First 1
        )
    }
    else {
        $selectedTask = @($allTasks | Where-Object { [string]::Equals([string]$_.Name, $selectedToken, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
    }

    if ($null -eq $selectedTask -or @($selectedTask).Count -eq 0) {
        Throw-FriendlyError `
            -Detail ("Task '{0}' was not found in {1} catalog." -f $selectedToken, $Stage) `
            -Code 60 `
            -Summary "Task selection is invalid." `
            -Hint ("List valid {0} task numbers with 'az-vm task --list --vm-{0}'." -f $Stage)
    }

    return $selectedTask[0]
}

function Resolve-AzVmTaskCommandMode {
    param([hashtable]$Options)

    $actions = @(
        @{ Name = 'list'; Present = (Test-AzVmCliOptionPresent -Options $Options -Name 'list') }
        @{ Name = 'save-app-state'; Present = (Test-AzVmCliOptionPresent -Options $Options -Name 'save-app-state') }
        @{ Name = 'restore-app-state'; Present = (Test-AzVmCliOptionPresent -Options $Options -Name 'restore-app-state') }
        @{ Name = 'run-vm-init'; Present = (Test-AzVmCliOptionPresent -Options $Options -Name 'run-vm-init') }
        @{ Name = 'run-vm-update'; Present = (Test-AzVmCliOptionPresent -Options $Options -Name 'run-vm-update') }
    )

    $presentActions = @($actions | Where-Object { [bool]$_.Present })
    if (@($presentActions).Count -lt 1) {
        Throw-FriendlyError `
            -Detail "Task command requires one action path." `
            -Code 2 `
            -Summary "Task command usage is incomplete." `
            -Hint "Use az-vm task --list, az-vm task --run-vm-init ..., az-vm task --run-vm-update ..., az-vm task --save-app-state ..., or az-vm task --restore-app-state ...."
    }
    if (@($presentActions).Count -gt 1) {
        Throw-FriendlyError `
            -Detail "Task command received conflicting action options." `
            -Code 2 `
            -Summary "Only one task action can run at a time." `
            -Hint "Use exactly one of --list, --run-vm-init, --run-vm-update, --save-app-state, or --restore-app-state."
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
        foreach ($optionName in @('group', 'vm-name', 'subscription-id', 'vm-init-task', 'vm-update-task', 'run-vm-init', 'run-vm-update')) {
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

    if ([string]::Equals($Mode, 'save-app-state', [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($Mode, 'restore-app-state', [System.StringComparison]::OrdinalIgnoreCase)) {
        foreach ($optionName in @('disabled', 'vm-init', 'vm-update', 'run-vm-init', 'run-vm-update')) {
            if (Test-AzVmCliOptionPresent -Options $Options -Name $optionName) {
                Throw-FriendlyError `
                    -Detail ("Task app-state maintenance does not support --{0}." -f [string]$optionName) `
                    -Code 2 `
                    -Summary "Task app-state mode received an unsupported option." `
                    -Hint "Use --save-app-state or --restore-app-state with --vm-init-task/--vm-update-task plus optional target selectors."
            }
        }

        return
    }

    foreach ($optionName in @('disabled', 'vm-init', 'vm-update', 'vm-init-task', 'vm-update-task', 'save-app-state', 'restore-app-state')) {
        if (Test-AzVmCliOptionPresent -Options $Options -Name $optionName) {
            Throw-FriendlyError `
                -Detail ("Task run mode does not support --{0}." -f [string]$optionName) `
                -Code 2 `
                -Summary "Task run mode received an unsupported option." `
                -Hint "Use --run-vm-init or --run-vm-update with optional target selectors."
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

function Resolve-AzVmTaskRunSelection {
    param(
        [hashtable]$Options
    )

    $hasRunInit = Test-AzVmCliOptionPresent -Options $Options -Name 'run-vm-init'
    $hasRunUpdate = Test-AzVmCliOptionPresent -Options $Options -Name 'run-vm-update'

    if ($hasRunInit -and $hasRunUpdate) {
        Throw-FriendlyError `
            -Detail "Both --run-vm-init and --run-vm-update were provided." `
            -Code 2 `
            -Summary "Only one task stage can be selected." `
            -Hint "Use either --run-vm-init or --run-vm-update."
    }

    if ($hasRunInit) {
        return [pscustomobject]@{
            Stage = 'init'
            Requested = [string](Get-AzVmCliOptionText -Options $Options -Name 'run-vm-init')
        }
    }
    if ($hasRunUpdate) {
        return [pscustomobject]@{
            Stage = 'update'
            Requested = [string](Get-AzVmCliOptionText -Options $Options -Name 'run-vm-update')
        }
    }

    Throw-FriendlyError `
        -Detail "Task run requires one stage selector." `
        -Code 2 `
        -Summary "Task run selector is missing." `
        -Hint "Use --run-vm-init <task-number|task-name> or --run-vm-update <task-number|task-name>."
}

function Resolve-AzVmTaskBlockForStage {
    param(
        [pscustomobject]$Runtime,
        [string]$Stage,
        [string]$Requested,
        [switch]$AutoMode
    )

    if ([string]::Equals([string]$Stage, 'init', [System.StringComparison]::OrdinalIgnoreCase)) {
        $catalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath ([string]$Runtime.Context.VmInitTaskDir) -Platform ([string]$Runtime.Platform) -Stage 'init'
        $tasks = Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks @($catalog.ActiveTasks) -Context $Runtime.Context
        return (Resolve-AzVmTaskSelection -TaskBlocks $tasks -TaskNumberOrName $Requested -Stage 'init' -AutoMode:$AutoMode)
    }

    $catalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath ([string]$Runtime.Context.VmUpdateTaskDir) -Platform ([string]$Runtime.Platform) -Stage 'update'
    $tasks = Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks @($catalog.ActiveTasks) -Context $Runtime.Context
    return (Resolve-AzVmTaskSelection -TaskBlocks $tasks -TaskNumberOrName $Requested -Stage 'update' -AutoMode:$AutoMode)
}

function Invoke-AzVmTaskExecutionWithTarget {
    param(
        [pscustomobject]$Runtime,
        [hashtable]$Options,
        [string]$OperationName = 'task',
        [string]$Stage,
        [string]$Requested,
        [switch]$AutoMode,
        [ValidateSet('continue','strict')]
        [string]$TaskOutcomeModeOverride = ''
    )

    $effectiveTaskOutcomeMode = [string]$Runtime.TaskOutcomeMode
    if (-not [string]::IsNullOrWhiteSpace([string]$TaskOutcomeModeOverride)) {
        $effectiveTaskOutcomeMode = [string]$TaskOutcomeModeOverride
    }

    $target = Resolve-AzVmManagedVmTarget -Options $Options -ConfigMap $Runtime.EffectiveConfigMap -OperationName $OperationName
    $Runtime.Context.ResourceGroup = [string]$target.ResourceGroup
    $Runtime.Context.VmName = [string]$target.VmName
    $taskBlock = Resolve-AzVmTaskBlockForStage -Runtime $Runtime -Stage $Stage -Requested $Requested -AutoMode:$AutoMode

    if ([string]::Equals([string]$Stage, 'init', [System.StringComparison]::OrdinalIgnoreCase)) {
        $combinedShell = if ([string]::Equals([string]$Runtime.Platform, 'linux', [System.StringComparison]::OrdinalIgnoreCase)) { 'bash' } else { 'powershell' }
        $runCommandResult = Invoke-VmRunCommandBlocks -ResourceGroup ([string]$Runtime.Context.ResourceGroup) -VmName ([string]$Runtime.Context.VmName) -CommandId ([string]$Runtime.PlatformDefaults.RunCommandId) -TaskBlocks @($taskBlock) -CombinedShell $combinedShell -TaskOutcomeMode $effectiveTaskOutcomeMode -PerfTaskCategory "task-run" -Platform ([string]$Runtime.Platform) -RepoRoot (Get-AzVmRepoRoot) -ManagerUser ([string]$Runtime.Context.VmUser) -AssistantUser ([string]$Runtime.Context.VmAssistantUser)
        return [pscustomobject]@{
            Stage = 'init'
            Task = $taskBlock
            TaskOutcomeMode = $effectiveTaskOutcomeMode
            Result = $runCommandResult
        }
    }

    $vmRuntimeDetails = Get-AzVmVmDetails -Context $Runtime.Context
    $sshHost = [string]$vmRuntimeDetails.VmFqdn
    if ([string]::IsNullOrWhiteSpace($sshHost)) {
        $sshHost = [string]$vmRuntimeDetails.PublicIP
    }
    if ([string]::IsNullOrWhiteSpace($sshHost)) {
        throw "Task execution could not resolve VM SSH host (FQDN/Public IP)."
    }

    $sshTaskResult = Invoke-AzVmSshTaskBlocks `
        -Platform ([string]$Runtime.Platform) `
        -RepoRoot (Get-AzVmRepoRoot) `
        -SshHost $sshHost `
        -SshUser ([string]$Runtime.Context.VmUser) `
        -SshPassword ([string]$Runtime.Context.VmPass) `
        -SshPort ([string]$Runtime.Context.SshPort) `
        -AssistantUser ([string]$Runtime.Context.VmAssistantUser) `
        -ResourceGroup ([string]$Runtime.Context.ResourceGroup) `
        -VmName ([string]$Runtime.Context.VmName) `
        -TaskBlocks @($taskBlock) `
        -TaskOutcomeMode $effectiveTaskOutcomeMode `
        -PerfTaskCategory 'task-run' `
        -SshMaxRetries 1 `
        -SshTaskTimeoutSeconds ([int]$Runtime.SshTaskTimeoutSeconds) `
        -SshConnectTimeoutSeconds ([int]$Runtime.SshConnectTimeoutSeconds) `
        -ConfiguredPySshClientPath ([string]$Runtime.ConfiguredPySshClientPath)

    return [pscustomobject]@{
        Stage = 'update'
        Task = $taskBlock
        TaskOutcomeMode = $effectiveTaskOutcomeMode
        Result = $sshTaskResult
    }
}
