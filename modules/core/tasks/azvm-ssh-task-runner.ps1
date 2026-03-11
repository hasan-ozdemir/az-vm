# Shared SSH task stage runner.

# Handles Invoke-AzVmSshTaskBlocks.
function Invoke-AzVmSshTaskBlocks {
    param(
        [ValidateSet('windows','linux')]
        [string]$Platform,
        [string]$RepoRoot,
        [string]$SshHost,
        [string]$SshUser,
        [string]$SshPassword,
        [string]$SshPort,
        [string]$ResourceGroup = '',
        [string]$VmName = '',
        [object[]]$TaskBlocks,
        [ValidateSet('continue','strict')]
        [string]$TaskOutcomeMode = 'continue',
        [ValidateSet('vm-update-task','exec-task')]
        [string]$PerfTaskCategory = 'vm-update-task',
        [int]$SshMaxRetries = 3,
        [int]$SshTaskTimeoutSeconds = 180,
        [int]$SshConnectTimeoutSeconds = 30,
        [string]$ConfiguredPySshClientPath = ''
    )

    if (-not $TaskBlocks -or @($TaskBlocks).Count -eq 0) {
        throw 'SSH task block list is empty.'
    }

    $SshMaxRetries = Resolve-AzVmSshRetryCount -RetryText ([string]$SshMaxRetries) -DefaultValue 3
    if ($SshTaskTimeoutSeconds -lt 30) { $SshTaskTimeoutSeconds = 30 }
    if ($SshTaskTimeoutSeconds -gt 7200) { $SshTaskTimeoutSeconds = 7200 }
    if ($SshConnectTimeoutSeconds -lt 5) { $SshConnectTimeoutSeconds = 5 }
    if ($SshConnectTimeoutSeconds -gt 300) { $SshConnectTimeoutSeconds = 300 }
    $pySsh = Ensure-AzVmPySshTools -RepoRoot $RepoRoot -ConfiguredPySshClientPath $ConfiguredPySshClientPath

    $bootstrap = Initialize-AzVmSshHostKey -PySshPythonPath ([string]$pySsh.PythonPath) -PySshClientPath ([string]$pySsh.ClientPath) -HostName $SshHost -UserName $SshUser -Password $SshPassword -Port $SshPort -ConnectTimeoutSeconds $SshConnectTimeoutSeconds
    if (-not [string]::IsNullOrWhiteSpace([string]$bootstrap.Output)) {
        Write-Host ([string]$bootstrap.Output)
    }
    Write-Host ("Resolved SSH host key for batch transport: {0}" -f [string]$bootstrap.HostKey)

    $shell = if ($Platform -eq 'windows') { 'powershell' } else { 'bash' }
    $session = $null
    $totalSuccess = 0
    $totalWarnings = 0
    $totalErrors = 0
    $rebootCount = 0
    $successfulTasks = @()
    $failedTasks = @()
    $rebootRequestedTasks = @()

    try {
        Write-Host 'VM update stage mode: tasks run one-by-one over a persistent SSH session.'
        Write-Host ("Task outcome policy: {0}" -f $TaskOutcomeMode)
        Write-Host ("SSH timeouts: task={0}s, connect={1}s" -f $SshTaskTimeoutSeconds, $SshConnectTimeoutSeconds) -ForegroundColor DarkCyan

        $session = Start-AzVmPersistentSshSession -PySshPythonPath ([string]$pySsh.PythonPath) -PySshClientPath ([string]$pySsh.ClientPath) -HostName $SshHost -UserName $SshUser -Password $SshPassword -Port $SshPort -Shell $shell -ConnectTimeoutSeconds $SshConnectTimeoutSeconds -DefaultTaskTimeoutSeconds $SshTaskTimeoutSeconds

        foreach ($task in @($TaskBlocks)) {
            $taskName = [string]$task.Name
            $taskScript = [string]$task.Script
            $taskTimeoutSeconds = Get-AzVmTaskTimeoutSeconds -TaskBlock $task -DefaultTimeoutSeconds $SshTaskTimeoutSeconds
            $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $taskResult = $null
            $taskInvocationError = $null

            Write-Host ("Task started: {0} (max {1}s)" -f $taskName, $taskTimeoutSeconds)

            $assetCopies = @()
            if ($task.PSObject.Properties.Match('AssetCopies').Count -gt 0 -and $null -ne $task.AssetCopies) {
                $assetCopies = @(ConvertTo-ObjectArrayCompat -InputObject $task.AssetCopies)
            }
            foreach ($asset in @($assetCopies)) {
                $assetLocalPath = [string]$asset.LocalPath
                $assetRemotePath = [string]$asset.RemotePath
                if ([string]::IsNullOrWhiteSpace([string]$assetLocalPath) -or [string]::IsNullOrWhiteSpace([string]$assetRemotePath)) {
                    continue
                }

                Write-Host ("Task asset copy started: {0} -> {1}" -f $assetLocalPath, $assetRemotePath)
                Copy-AzVmAssetToVm `
                    -PySshPythonPath ([string]$pySsh.PythonPath) `
                    -PySshClientPath ([string]$pySsh.ClientPath) `
                    -HostName $SshHost `
                    -UserName $SshUser `
                    -Password $SshPassword `
                    -Port $SshPort `
                    -LocalPath $assetLocalPath `
                    -RemotePath $assetRemotePath `
                    -ConnectTimeoutSeconds $SshConnectTimeoutSeconds
                Write-Host ("Task asset copy completed: {0}" -f $assetRemotePath)
            }

            for ($attempt = 1; $attempt -le $SshMaxRetries; $attempt++) {
                $taskInvocationError = $null
                try {
                    $taskResult = Invoke-AzVmPersistentSshTask -Session $session -TaskName $taskName -TaskScript $taskScript -TimeoutSeconds $taskTimeoutSeconds
                    break
                }
                catch {
                    $taskInvocationError = $_
                    if ($attempt -lt $SshMaxRetries) {
                        Write-Warning ("Persistent SSH task execution failed for '{0}' (attempt {1}/{2}): {3}" -f $taskName, $attempt, $SshMaxRetries, $_.Exception.Message)
                        Stop-AzVmPersistentSshSession -Session $session
                        $session = Start-AzVmPersistentSshSession -PySshPythonPath ([string]$pySsh.PythonPath) -PySshClientPath ([string]$pySsh.ClientPath) -HostName $SshHost -UserName $SshUser -Password $SshPassword -Port $SshPort -Shell $shell -ConnectTimeoutSeconds $SshConnectTimeoutSeconds -DefaultTaskTimeoutSeconds $SshTaskTimeoutSeconds
                    }
                }
            }

            if ($taskWatch.IsRunning) { $taskWatch.Stop() }
            $taskElapsedSeconds = $taskWatch.Elapsed.TotalSeconds
            if ($null -ne $taskResult) {
                $taskResult.DurationSeconds = [double]$taskElapsedSeconds
            }
            if ($script:PerfMode) {
                Write-AzVmPerfTiming -Category $PerfTaskCategory -Label $taskName -Seconds $taskElapsedSeconds
            }

            if ($null -ne $taskInvocationError) {
                $failedTasks += $taskName
                if ($TaskOutcomeMode -eq 'continue') {
                    $totalWarnings++
                    Write-Warning ("Task warning: {0} failed in persistent session => {1}" -f $taskName, $taskInvocationError.Exception.Message)
                    Write-Host ("Task completed: {0} ({1:N1}s) - warning" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
                    continue
                }

                $totalErrors++
                Write-Host ("Task failed: {0}" -f $taskName) -ForegroundColor Red
                throw ("VM update task failed in persistent session: {0} => {1}" -f $taskName, $taskInvocationError.Exception.Message)
            }

            if ([int]$taskResult.ExitCode -eq 0) {
                $totalSuccess++
                $successfulTasks += $taskName
                Write-Host ("Task completed: {0} ({1:N1}s) - success" -f $taskName, $taskElapsedSeconds)
            }
            else {
                $failedTasks += $taskName
                if ($TaskOutcomeMode -eq 'continue') {
                    $totalWarnings++
                    Write-Warning ("Task warning: {0} exited with code {1}" -f $taskName, $taskResult.ExitCode)
                    Write-Host ("Task completed: {0} ({1:N1}s) - warning" -f $taskName, $taskElapsedSeconds)
                }
                else {
                    $totalErrors++
                    Write-Host ("Task failed: {0}" -f $taskName) -ForegroundColor Red
                    throw ("VM update task failed: {0} (exit {1})" -f $taskName, $taskResult.ExitCode)
                }
            }

            $taskRequestedReboot = $false
            if ($taskResult -and $taskResult.PSObject.Properties.Match('Output').Count -gt 0) {
                $taskRequestedReboot = Test-AzVmOutputIndicatesRebootRequired -MessageText ([string]$taskResult.Output)
            }
            if ($taskRequestedReboot) {
                $rebootCount++
                $rebootRequestedTasks += $taskName
                Write-Host ("Task '{0}' requested a VM restart. The request was recorded and deferred until the vm-update stage completes." -f $taskName) -ForegroundColor Yellow
                if ($TaskOutcomeMode -eq 'continue' -and [int]$taskResult.ExitCode -eq 0) {
                    $totalWarnings++
                }
            }
        }

        $uniqueSuccessfulTasks = @($successfulTasks | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
        $uniqueFailedTasks = @($failedTasks | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

        Write-Host ("VM update stage summary: success={0}, failed={1}, warning={2}, error={3}, reboot={4}" -f @($uniqueSuccessfulTasks).Count, @($uniqueFailedTasks).Count, $totalWarnings, $totalErrors, $rebootCount)
        if (@($uniqueFailedTasks).Count -gt 0) {
            Write-Host 'Failed tasks:' -ForegroundColor Yellow
            foreach ($failedTaskName in @($uniqueFailedTasks)) {
                Write-Host ("- {0}" -f [string]$failedTaskName) -ForegroundColor Yellow
            }
        }
        if ($rebootCount -gt 0) {
            $rebootTaskList = @(
                $rebootRequestedTasks |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                    Select-Object -Unique
            )
            if (@($rebootTaskList).Count -eq 0) {
                $rebootTaskList = @('(task names unavailable)')
            }
            Write-Host 'VM restart requirement detected after vm-update.' -ForegroundColor Yellow
            Write-Host 'Tasks requesting restart:' -ForegroundColor Yellow
            foreach ($rebootTaskName in @($rebootTaskList)) {
                Write-Host ("- {0}" -f [string]$rebootTaskName) -ForegroundColor Yellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$ResourceGroup) -and -not [string]::IsNullOrWhiteSpace([string]$VmName)) {
                Write-Host ("Hint: restart the VM after step 6 finishes: az vm restart --resource-group {0} --name {1}" -f $ResourceGroup, $VmName) -ForegroundColor Cyan
            }
            else {
                Write-Host "Hint: restart the VM after step 6 finishes before relying on newly installed components." -ForegroundColor Cyan
            }
        }
        if ($TaskOutcomeMode -eq 'strict' -and ($totalWarnings -gt 0 -or $totalErrors -gt 0)) {
            throw ("VM update strict task outcome mode blocked continuation: warning={0}, error={1}" -f $totalWarnings, $totalErrors)
        }

        return [pscustomobject]@{
            SuccessCount = $totalSuccess
            SuccessTasks = @($uniqueSuccessfulTasks)
            FailedCount = @($uniqueFailedTasks).Count
            FailedTasks = @($uniqueFailedTasks)
            WarningCount = $totalWarnings
            ErrorCount = $totalErrors
            RebootCount = $rebootCount
            RebootRequired = ($rebootCount -gt 0)
            RebootRequestedTasks = @($rebootRequestedTasks | Select-Object -Unique)
        }
    }
    finally {
        if ($null -ne $session) {
            Stop-AzVmPersistentSshSession -Session $session
        }
    }
}
