# Exec command entry.

# Handles Invoke-AzVmExecCommand.
function Invoke-AzVmExecCommand {
    param(
        [hashtable]$Options,
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag,
        [ValidateSet('continue','strict')]
        [string]$TaskOutcomeModeOverride = ''
    )

    $runtime = Initialize-AzVmExecCommandRuntimeContext -AutoMode:$AutoMode -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag
    $context = $runtime.Context
    $platform = [string]$runtime.Platform
    $platformDefaults = $runtime.PlatformDefaults
    $effectiveTaskOutcomeMode = [string]$runtime.TaskOutcomeMode
    if (-not [string]::IsNullOrWhiteSpace([string]$TaskOutcomeModeOverride)) {
        $effectiveTaskOutcomeMode = [string]$TaskOutcomeModeOverride
    }

    $hasInitTask = Test-AzVmCliOptionPresent -Options $Options -Name 'init-task'
    $hasUpdateTask = Test-AzVmCliOptionPresent -Options $Options -Name 'update-task'
    if ($hasInitTask -and $hasUpdateTask) {
        Throw-FriendlyError `
            -Detail "Both --init-task and --update-task were provided." `
            -Code 61 `
            -Summary "Only one task selector can be used at a time." `
            -Hint "Use either --init-task=<task-number> or --update-task=<task-number>."
    }

    $hasTaskSelector = ($hasInitTask -or $hasUpdateTask)
    if ($hasTaskSelector) {
        $stage = if ($hasInitTask) { 'init' } else { 'update' }
        $target = Resolve-AzVmManagedVmTarget -Options $Options -ConfigMap $runtime.EffectiveConfigMap -OperationName 'exec'
        $context.ResourceGroup = [string]$target.ResourceGroup
        $context.VmName = [string]$target.VmName

        if ($stage -eq 'init') {
            $catalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath ([string]$context.VmInitTaskDir) -Platform $platform -Stage 'init'
            $tasks = Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks @($catalog.ActiveTasks) -Context $context
            $requested = Get-AzVmCliOptionText -Options $Options -Name 'init-task'
            $selectedTask = Resolve-AzVmTaskSelection -TaskBlocks $tasks -TaskNumberOrName $requested -Stage 'init' -AutoMode:$AutoMode
            $combinedShell = if ($platform -eq 'linux') { 'bash' } else { 'powershell' }
            $runCommandResult = Invoke-VmRunCommandBlocks -ResourceGroup ([string]$context.ResourceGroup) -VmName ([string]$context.VmName) -CommandId ([string]$platformDefaults.RunCommandId) -TaskBlocks @($selectedTask) -CombinedShell $combinedShell -TaskOutcomeMode $effectiveTaskOutcomeMode -PerfTaskCategory "exec-task"
            Write-Host ("Exec completed: init task '{0}'." -f [string]$selectedTask.Name) -ForegroundColor Green
            return [pscustomobject]@{
                Stage = 'init'
                Task = $selectedTask
                TaskOutcomeMode = $effectiveTaskOutcomeMode
                Result = $runCommandResult
            }
        }

        $catalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath ([string]$context.VmUpdateTaskDir) -Platform $platform -Stage 'update'
        $tasks = Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks @($catalog.ActiveTasks) -Context $context
        $requested = Get-AzVmCliOptionText -Options $Options -Name 'update-task'
        $selectedTask = Resolve-AzVmTaskSelection -TaskBlocks $tasks -TaskNumberOrName $requested -Stage 'update' -AutoMode:$AutoMode

        $vmRuntimeDetails = Get-AzVmVmDetails -Context $context
        $sshHost = [string]$vmRuntimeDetails.VmFqdn
        if ([string]::IsNullOrWhiteSpace($sshHost)) {
            $sshHost = [string]$vmRuntimeDetails.PublicIP
        }
        if ([string]::IsNullOrWhiteSpace($sshHost)) {
            throw "Exec could not resolve VM SSH host (FQDN/Public IP)."
        }

        $sshTaskResult = Invoke-AzVmSshTaskBlocks `
            -Platform $platform `
            -RepoRoot (Get-AzVmRepoRoot) `
            -SshHost $sshHost `
            -SshUser ([string]$context.VmUser) `
            -SshPassword ([string]$context.VmPass) `
            -SshPort ([string]$context.SshPort) `
            -AssistantUser ([string]$context.VmAssistantUser) `
            -ResourceGroup ([string]$context.ResourceGroup) `
            -VmName ([string]$context.VmName) `
            -TaskBlocks @($selectedTask) `
            -TaskOutcomeMode $effectiveTaskOutcomeMode `
            -PerfTaskCategory 'exec-task' `
            -SshMaxRetries 1 `
            -SshTaskTimeoutSeconds ([int]$runtime.SshTaskTimeoutSeconds) `
            -SshConnectTimeoutSeconds ([int]$runtime.SshConnectTimeoutSeconds) `
            -ConfiguredPySshClientPath ([string]$runtime.ConfiguredPySshClientPath)

        Write-Host ("Exec completed: update task '{0}'." -f [string]$selectedTask.Name) -ForegroundColor Green
        return [pscustomobject]@{
            Stage = 'update'
            Task = $selectedTask
            TaskOutcomeMode = $effectiveTaskOutcomeMode
            Result = $sshTaskResult
        }
    }

    $target = Resolve-AzVmManagedVmTarget -Options $Options -ConfigMap $runtime.EffectiveConfigMap -OperationName 'exec'
    $selectedResourceGroup = [string]$target.ResourceGroup
    $selectedVmName = [string]$target.VmName
    $vmDetailContext = [ordered]@{
        ResourceGroup = $selectedResourceGroup
        VmName = $selectedVmName
        AzLocation = [string]$context.AzLocation
        SshPort = [string]$context.SshPort
    }

    $vmRuntimeDetails = Get-AzVmVmDetails -Context $vmDetailContext
    $sshHost = [string]$vmRuntimeDetails.VmFqdn
    if ([string]::IsNullOrWhiteSpace($sshHost)) {
        $sshHost = [string]$vmRuntimeDetails.PublicIP
    }
    if ([string]::IsNullOrWhiteSpace($sshHost)) {
        throw "Exec REPL could not resolve VM SSH host (FQDN/Public IP)."
    }

    $vmJson = az vm show -g $selectedResourceGroup -n $selectedVmName -o json --only-show-errors
    Assert-LastExitCode "az vm show (exec repl)"
    $vmObject = ConvertFrom-JsonCompat -InputObject $vmJson
    $osType = [string]$vmObject.storageProfile.osDisk.osType
    $replPlatform = if ([string]::Equals($osType, 'Linux', [System.StringComparison]::OrdinalIgnoreCase)) { 'linux' } else { 'windows' }
    $shell = if ($replPlatform -eq 'linux') { 'bash' } else { 'powershell' }

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

    Write-Host ("Interactive exec shell connected: {0}@{1}:{2} ({3})" -f [string]$context.VmUser, $sshHost, [string]$context.SshPort, $shell) -ForegroundColor Green
    Write-Host "Type 'exit' in the remote shell to close the session." -ForegroundColor Cyan

    $shellWatch = $null
    if ($script:PerfMode) {
        $shellWatch = [System.Diagnostics.Stopwatch]::StartNew()
    }

    $shellArgs = @(
        [string]$pySsh.ClientPath,
        "shell",
        "--host", [string]$sshHost,
        "--port", [string]$context.SshPort,
        "--user", [string]$context.VmUser,
        "--password", [string]$context.VmPass,
        "--timeout", [string]$runtime.SshConnectTimeoutSeconds,
        "--reconnect-retries", "3",
        "--keepalive-seconds", "15",
        "--shell", [string]$shell
    )

    & ([string]$pySsh.PythonPath) @shellArgs
    $shellExitCode = [int]$LASTEXITCODE

    if ($null -ne $shellWatch -and $shellWatch.IsRunning) {
        $shellWatch.Stop()
        Write-AzVmPerfTiming -Category "exec-task" -Label "interactive shell session" -Seconds $shellWatch.Elapsed.TotalSeconds
    }

    if ($shellExitCode -ne 0) {
        Throw-FriendlyError `
            -Detail ("Interactive exec shell ended with exit code {0}." -f $shellExitCode) `
            -Code 61 `
            -Summary "Interactive exec shell failed." `
            -Hint "Review remote shell output and retry. Ensure SSH service remains available on the VM."
    }

    Write-Host "Exec REPL session closed." -ForegroundColor Green
}
