# Task command entry.

# Handles Invoke-AzVmTaskCommand.
function Invoke-AzVmTaskCommand {
    param(
        [hashtable]$Options,
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    $mode = Resolve-AzVmTaskCommandMode -Options $Options
    Assert-AzVmTaskCommandOptionScope -Mode $mode -Options $Options
    if ([string]::Equals($mode, 'list', [System.StringComparison]::OrdinalIgnoreCase)) {
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

    $runtime = Initialize-AzVmTaskExecutionRuntimeContext -AutoMode:$AutoMode -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag
    if ([string]::Equals($mode, 'run-vm-init', [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($mode, 'run-vm-update', [System.StringComparison]::OrdinalIgnoreCase)) {
        $runSelection = Resolve-AzVmTaskRunSelection -Options $Options
        $runResult = Invoke-AzVmTaskExecutionWithTarget `
            -Runtime $runtime `
            -Options $Options `
            -OperationName 'task' `
            -Stage ([string]$runSelection.Stage) `
            -Requested ([string]$runSelection.Requested) `
            -AutoMode:$AutoMode
        Write-Host ("Task completed: {0} task '{1}'." -f [string]$runResult.Stage, [string]$runResult.Task.Name) -ForegroundColor Green
        return [pscustomobject]@{
            Mode = 'run'
            Stage = [string]$runResult.Stage
            Task = $runResult.Task
            Result = $runResult.Result
        }
    }

    $context = $runtime.Context
    $platform = [string]$runtime.Platform
    $target = Resolve-AzVmManagedVmTarget -Options $Options -ConfigMap $runtime.EffectiveConfigMap -OperationName 'task'
    $context.ResourceGroup = [string]$target.ResourceGroup
    $context.VmName = [string]$target.VmName
    $taskSelection = Resolve-AzVmTaskBlockForMaintenance -Runtime $runtime -Options $Options -AutoMode:$AutoMode
    $taskBlock = $taskSelection.TaskBlock
    $taskTimeoutSeconds = Get-AzVmTaskTimeoutSeconds -TaskBlock $taskBlock -DefaultTimeoutSeconds ([int]$runtime.SshTaskTimeoutSeconds)
    $appStateTimeoutSeconds = [Math]::Max([int]$taskTimeoutSeconds, 900)

    if ([string]::Equals($mode, 'restore-app-state', [System.StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$taskSelection.Stage, 'init', [System.StringComparison]::OrdinalIgnoreCase)) {
        $pluginInfo = Get-AzVmTaskAppStatePluginInfo -TaskBlock $taskBlock
        if ($pluginInfo.Status -eq 'missing-plugin') {
            Throw-FriendlyError `
                -Detail ("App-state plugin folder was not found for task '{0}'." -f [string]$taskBlock.Name) `
                -Code 61 `
                -Summary "Task app-state restore input is missing." `
                -Hint ("Save state first with 'az-vm task --save-app-state --vm-{0}-task={1}'." -f [string]$taskSelection.Stage, [string]$taskBlock.TaskNumber)
        }
        if ($pluginInfo.Status -eq 'missing-zip') {
            Throw-FriendlyError `
                -Detail ("app-state.zip was not found for task '{0}'." -f [string]$taskBlock.Name) `
                -Code 61 `
                -Summary "Task app-state restore input is missing." `
                -Hint ("Save state first with 'az-vm task --save-app-state --vm-{0}-task={1}'." -f [string]$taskSelection.Stage, [string]$taskBlock.TaskNumber)
        }
        if ($pluginInfo.Status -eq 'invalid') {
            Throw-FriendlyError `
                -Detail ("Task app-state payload for '{0}' is invalid: {1}" -f [string]$taskBlock.Name, [string]$pluginInfo.Message) `
                -Code 61 `
                -Summary "Task app-state restore input is invalid." `
                -Hint "Fix or re-save the task app-state payload, then retry the restore."
        }

        $restoreResult = Invoke-AzVmTaskAppStatePostProcess `
            -Platform $platform `
            -Transport 'run-command' `
            -RepoRoot (Get-AzVmRepoRoot) `
            -TaskBlock $taskBlock `
            -ResourceGroup ([string]$context.ResourceGroup) `
            -VmName ([string]$context.VmName) `
            -RunCommandId ([string]$runtime.PlatformDefaults.RunCommandId) `
            -TimeoutSeconds ([int]$appStateTimeoutSeconds) `
            -ManagerUser ([string]$context.VmUser) `
            -AssistantUser ([string]$context.VmAssistantUser)
        Write-Host ("Task completed: restore app-state for '{0}'." -f [string]$taskBlock.Name) -ForegroundColor Green
        return [pscustomobject]@{
            Mode = 'restore-app-state'
            Stage = [string]$taskSelection.Stage
            Task = $taskBlock
            Result = $restoreResult
        }
    }

    $vmRuntimeDetails = Get-AzVmVmDetails -Context $context
    $sshHost = [string]$vmRuntimeDetails.VmFqdn
    if ([string]::IsNullOrWhiteSpace([string]$sshHost)) {
        $sshHost = [string]$vmRuntimeDetails.PublicIP
    }
    if ([string]::IsNullOrWhiteSpace([string]$sshHost)) {
        throw "Task command could not resolve VM SSH host (FQDN/Public IP)."
    }

    $pySsh = Ensure-AzVmPySshTools -RepoRoot (Get-AzVmRepoRoot) -ConfiguredPySshClientPath ([string]$runtime.ConfiguredPySshClientPath)
    $bootstrap = Initialize-AzVmSshHostKey `
        -PySshPythonPath ([string]$pySsh.PythonPath) `
        -PySshClientPath ([string]$pySsh.ClientPath) `
        -HostName $sshHost `
        -UserName ([string]$context.VmUser) `
        -Password ([string]$context.VmPass) `
        -Port ([string]$context.SshPort) `
        -ConnectTimeoutSeconds ([int]$runtime.SshConnectTimeoutSeconds)
    if (-not [string]::IsNullOrWhiteSpace([string]$bootstrap.Output)) {
        Write-Host ([string]$bootstrap.Output)
    }

    $shell = if ($platform -eq 'linux') { 'bash' } else { 'powershell' }
    $session = $null
    try {
        try {
            $session = Start-AzVmPersistentSshSession `
                -PySshPythonPath ([string]$pySsh.PythonPath) `
                -PySshClientPath ([string]$pySsh.ClientPath) `
                -HostName $sshHost `
                -UserName ([string]$context.VmUser) `
                -Password ([string]$context.VmPass) `
                -Port ([string]$context.SshPort) `
                -Shell $shell `
                -ConnectTimeoutSeconds ([int]$runtime.SshConnectTimeoutSeconds) `
                -DefaultTaskTimeoutSeconds ([int]$taskTimeoutSeconds)
        }
        catch {
            $session = $null
            Write-Warning ("Persistent SSH session bootstrap failed for task app-state maintenance. Falling back to one-shot transport: {0}" -f $_.Exception.Message)
        }

        if ([string]::Equals($mode, 'save-app-state', [System.StringComparison]::OrdinalIgnoreCase)) {
            $saveResult = Save-AzVmTaskAppStateFromVm `
                -Platform $platform `
                -RepoRoot (Get-AzVmRepoRoot) `
                -TaskBlock $taskBlock `
                -Session $session `
                -PySshPythonPath ([string]$pySsh.PythonPath) `
                -PySshClientPath ([string]$pySsh.ClientPath) `
                -HostName $sshHost `
                -UserName ([string]$context.VmUser) `
                -Password ([string]$context.VmPass) `
                -Port ([string]$context.SshPort) `
                -ConnectTimeoutSeconds ([int]$runtime.SshConnectTimeoutSeconds) `
                -TimeoutSeconds ([int]$appStateTimeoutSeconds) `
                -ManagerUser ([string]$context.VmUser) `
                -AssistantUser ([string]$context.VmAssistantUser)
            Write-Host ("Task completed: save app-state for '{0}'." -f [string]$taskBlock.Name) -ForegroundColor Green
            return [pscustomobject]@{
                Mode = 'save-app-state'
                Stage = [string]$taskSelection.Stage
                Task = $taskBlock
                Result = $saveResult
            }
        }

        $pluginInfo = Get-AzVmTaskAppStatePluginInfo -TaskBlock $taskBlock
        if ($pluginInfo.Status -eq 'missing-plugin') {
            Throw-FriendlyError `
                -Detail ("App-state plugin folder was not found for task '{0}'." -f [string]$taskBlock.Name) `
                -Code 61 `
                -Summary "Task app-state restore input is missing." `
                -Hint ("Save state first with 'az-vm task --save-app-state --vm-{0}-task={1}'." -f [string]$taskSelection.Stage, [string]$taskBlock.TaskNumber)
        }
        if ($pluginInfo.Status -eq 'missing-zip') {
            Throw-FriendlyError `
                -Detail ("app-state.zip was not found for task '{0}'." -f [string]$taskBlock.Name) `
                -Code 61 `
                -Summary "Task app-state restore input is missing." `
                -Hint ("Save state first with 'az-vm task --save-app-state --vm-{0}-task={1}'." -f [string]$taskSelection.Stage, [string]$taskBlock.TaskNumber)
        }
        if ($pluginInfo.Status -eq 'invalid') {
            Throw-FriendlyError `
                -Detail ("Task app-state payload for '{0}' is invalid: {1}" -f [string]$taskBlock.Name, [string]$pluginInfo.Message) `
                -Code 61 `
                -Summary "Task app-state restore input is invalid." `
                -Hint "Fix or re-save the task app-state payload, then retry the restore."
        }

        $restoreResult = Invoke-AzVmTaskAppStatePostProcess `
            -Platform $platform `
            -RepoRoot (Get-AzVmRepoRoot) `
            -TaskBlock $taskBlock `
            -Session $session `
            -PySshPythonPath ([string]$pySsh.PythonPath) `
            -PySshClientPath ([string]$pySsh.ClientPath) `
            -HostName $sshHost `
            -UserName ([string]$context.VmUser) `
            -Password ([string]$context.VmPass) `
            -Port ([string]$context.SshPort) `
            -ConnectTimeoutSeconds ([int]$runtime.SshConnectTimeoutSeconds) `
            -TimeoutSeconds ([int]$appStateTimeoutSeconds) `
            -ManagerUser ([string]$context.VmUser) `
            -AssistantUser ([string]$context.VmAssistantUser)
        Write-Host ("Task completed: restore app-state for '{0}'." -f [string]$taskBlock.Name) -ForegroundColor Green
        return [pscustomobject]@{
            Mode = 'restore-app-state'
            Stage = [string]$taskSelection.Stage
            Task = $taskBlock
            Result = $restoreResult
        }
    }
    finally {
        if ($null -ne $session) {
            Stop-AzVmPersistentSshSession -Session $session
        }
    }
}
