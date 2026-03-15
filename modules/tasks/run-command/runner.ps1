# Run-command task runner.

function New-AzVmRunCommandTaskWrapperScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName,
        [Parameter(Mandatory = $true)]
        [string]$TaskScript,
        [int]$TimeoutSeconds = 180,
        [ValidateSet('bash','powershell')]
        [string]$CombinedShell = 'powershell'
    )

    if ($TimeoutSeconds -lt 5) {
        $TimeoutSeconds = 5
    }

    if ([string]::Equals([string]$CombinedShell, 'bash', [System.StringComparison]::OrdinalIgnoreCase)) {
        $taskNameBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$TaskName)
        $taskNameBase64 = [System.Convert]::ToBase64String($taskNameBytes)
        $taskBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$TaskScript)
        $taskBase64 = [System.Convert]::ToBase64String($taskBytes)

        $builder = New-Object System.Text.StringBuilder
        [void]$builder.AppendLine('set -uo pipefail')
        [void]$builder.AppendLine('success_count=0')
        [void]$builder.AppendLine('warning_count=0')
        [void]$builder.AppendLine('error_count=0')
        [void]$builder.AppendLine('reboot_count=0')
        [void]$builder.AppendLine('invoke_task() {')
        [void]$builder.AppendLine('  local task_name_base64="$1"')
        [void]$builder.AppendLine('  local script_base64="$2"')
        [void]$builder.AppendLine('  local task_timeout="$3"')
        [void]$builder.AppendLine('  local task_name')
        [void]$builder.AppendLine('  task_name=$(printf ''%s'' "$task_name_base64" | base64 -d)')
        [void]$builder.AppendLine('  echo "TASK started: ${task_name} (max ${task_timeout}s)"')
        [void]$builder.AppendLine('  local start_ts')
        [void]$builder.AppendLine('  start_ts=$(date +%s)')
        [void]$builder.AppendLine('  local task_script')
        [void]$builder.AppendLine('  task_script=$(printf ''%s'' "$script_base64" | base64 -d)')
        [void]$builder.AppendLine('  local task_output=""')
        [void]$builder.AppendLine('  if task_output=$(timeout --signal=TERM --kill-after=15 "${task_timeout}" bash -lc "$task_script" 2>&1); then')
        [void]$builder.AppendLine('    local end_ts')
        [void]$builder.AppendLine('    end_ts=$(date +%s)')
        [void]$builder.AppendLine('    local elapsed=$(( end_ts - start_ts ))')
        [void]$builder.AppendLine('    if [ -n "$task_output" ]; then')
        [void]$builder.AppendLine('      printf ''%s\n'' "$task_output"')
        [void]$builder.AppendLine('    fi')
        [void]$builder.AppendLine('    echo "TASK completed: ${task_name} (${elapsed}s)"')
        [void]$builder.AppendLine('    echo "TASK result: success"')
        [void]$builder.AppendLine('    echo "TASK_STATUS:${task_name}:success"')
        [void]$builder.AppendLine('    success_count=$(( success_count + 1 ))')
        [void]$builder.AppendLine('  else')
        [void]$builder.AppendLine('    local exit_code=$?')
        [void]$builder.AppendLine('    local end_ts')
        [void]$builder.AppendLine('    end_ts=$(date +%s)')
        [void]$builder.AppendLine('    local elapsed=$(( end_ts - start_ts ))')
        [void]$builder.AppendLine('    if [ -n "$task_output" ]; then')
        [void]$builder.AppendLine('      printf ''%s\n'' "$task_output"')
        [void]$builder.AppendLine('    fi')
        [void]$builder.AppendLine('    echo "TASK completed: ${task_name} (${elapsed}s)"')
        [void]$builder.AppendLine('    if [ "$exit_code" -eq 124 ] || [ "$exit_code" -eq 137 ]; then')
        [void]$builder.AppendLine('      echo "TASK result: timeout (${task_name})"')
        [void]$builder.AppendLine('    else')
        [void]$builder.AppendLine('      echo "TASK result: failure (${task_name})"')
        [void]$builder.AppendLine('    fi')
        [void]$builder.AppendLine('    echo "TASK_STATUS:${task_name}:error"')
        [void]$builder.AppendLine('    error_count=$(( error_count + 1 ))')
        [void]$builder.AppendLine('  fi')
        [void]$builder.AppendLine('}')
        [void]$builder.AppendLine(("invoke_task '{0}' '{1}' '{2}'" -f $taskNameBase64, $taskBase64, [int]$TimeoutSeconds))
        [void]$builder.AppendLine('echo "RUN_COMMAND_SUMMARY:success=${success_count};warning=${warning_count};error=${error_count};reboot=${reboot_count}"')
        return $builder.ToString()
    }

    $taskNameSafe = [string]$TaskName.Replace("'", "''")
    $taskBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$TaskScript)
    $taskBase64 = [System.Convert]::ToBase64String($taskBytes)

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('$ErrorActionPreference = "Stop"')
    [void]$builder.AppendLine('$ProgressPreference = "SilentlyContinue"')
    [void]$builder.AppendLine('$script:SuccessCount = 0')
    [void]$builder.AppendLine('$script:WarningCount = 0')
    [void]$builder.AppendLine('$script:ErrorCount = 0')
    [void]$builder.AppendLine('$script:RebootCount = 0')
    [void]$builder.AppendLine('function Invoke-RunCommandTaskBlock {')
    [void]$builder.AppendLine('    param([string]$TaskName,[string]$ScriptBase64,[int]$TimeoutSeconds)')
    [void]$builder.AppendLine('    if ($TimeoutSeconds -lt 5) { $TimeoutSeconds = 5 }')
    [void]$builder.AppendLine('    Write-Host ("TASK started: {0} (max {1}s)" -f $TaskName, $TimeoutSeconds)')
    [void]$builder.AppendLine('    $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()')
    [void]$builder.AppendLine('    $completionWritten = $false')
    [void]$builder.AppendLine('    $job = $null')
    [void]$builder.AppendLine('    $tempPath = $null')
    [void]$builder.AppendLine('    try {')
    [void]$builder.AppendLine('        $decodedScript = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($ScriptBase64))')
    [void]$builder.AppendLine('        $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("az-vm-init-task-{0}.ps1" -f [System.Guid]::NewGuid().ToString("N"))')
    [void]$builder.AppendLine('        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)')
    [void]$builder.AppendLine('        [System.IO.File]::WriteAllText($tempPath, $decodedScript, $utf8NoBom)')
    [void]$builder.AppendLine('        $job = Start-Job -ArgumentList $tempPath -ScriptBlock {')
    [void]$builder.AppendLine('            param($TaskPath)')
    [void]$builder.AppendLine('            $commandOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TaskPath 2>&1')
    [void]$builder.AppendLine('            [pscustomobject]@{ ExitCode = [int]$LASTEXITCODE; Lines = @($commandOutput | ForEach-Object { [string]$_ }) }')
    [void]$builder.AppendLine('        }')
    [void]$builder.AppendLine('        $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds')
    [void]$builder.AppendLine('        if ($null -eq $completed) {')
    [void]$builder.AppendLine('            Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null')
    [void]$builder.AppendLine('            throw "Task timed out."')
    [void]$builder.AppendLine('        }')
    [void]$builder.AppendLine('        $jobResult = Receive-Job -Job $job -ErrorAction Stop')
    [void]$builder.AppendLine('        if ($jobResult -is [System.Array] -and $jobResult.Count -gt 0) {')
    [void]$builder.AppendLine('            $jobResult = $jobResult[-1]')
    [void]$builder.AppendLine('        }')
    [void]$builder.AppendLine('        $jobOutputLines = @()')
    [void]$builder.AppendLine('        $jobExitCode = 0')
    [void]$builder.AppendLine('        if ($null -ne $jobResult) {')
    [void]$builder.AppendLine('            if ($jobResult.PSObject.Properties.Match("Lines").Count -gt 0 -and $null -ne $jobResult.Lines) {')
    [void]$builder.AppendLine('                $jobOutputLines = @($jobResult.Lines | ForEach-Object { [string]$_ })')
    [void]$builder.AppendLine('            }')
    [void]$builder.AppendLine('            if ($jobResult.PSObject.Properties.Match("ExitCode").Count -gt 0) {')
    [void]$builder.AppendLine('                $jobExitCode = [int]$jobResult.ExitCode')
    [void]$builder.AppendLine('            }')
    [void]$builder.AppendLine('        }')
    [void]$builder.AppendLine('        foreach ($line in @($jobOutputLines)) {')
    [void]$builder.AppendLine('            if (-not [string]::IsNullOrWhiteSpace([string]$line)) {')
    [void]$builder.AppendLine('                Write-Host ([string]$line)')
    [void]$builder.AppendLine('            }')
    [void]$builder.AppendLine('        }')
    [void]$builder.AppendLine('        if ($taskWatch.IsRunning) { $taskWatch.Stop() }')
    [void]$builder.AppendLine('        Write-Host ("TASK completed: {0} ({1:N1}s)" -f $TaskName, $taskWatch.Elapsed.TotalSeconds)')
    [void]$builder.AppendLine('        $completionWritten = $true')
    [void]$builder.AppendLine('        if ($jobExitCode -ne 0) { throw ("Task exited with code {0}." -f $jobExitCode) }')
    [void]$builder.AppendLine('        Write-Host "TASK result: success"')
    [void]$builder.AppendLine('        Write-Host ("TASK_STATUS:{0}:success" -f $TaskName)')
    [void]$builder.AppendLine('        $script:SuccessCount++')
    [void]$builder.AppendLine('    }')
    [void]$builder.AppendLine('    catch {')
    [void]$builder.AppendLine('        if ($taskWatch.IsRunning) { $taskWatch.Stop() }')
    [void]$builder.AppendLine('        if (-not $completionWritten) {')
    [void]$builder.AppendLine('            Write-Host ("TASK completed: {0} ({1:N1}s)" -f $TaskName, $taskWatch.Elapsed.TotalSeconds)')
    [void]$builder.AppendLine('        }')
    [void]$builder.AppendLine('        Write-Host ("TASK result: failure ({0})" -f $TaskName)')
    [void]$builder.AppendLine('        Write-Host ("TASK_STATUS:{0}:error" -f $TaskName)')
    [void]$builder.AppendLine('        $script:ErrorCount++')
    [void]$builder.AppendLine('    }')
    [void]$builder.AppendLine('    finally {')
    [void]$builder.AppendLine('        if ($null -ne $job) {')
    [void]$builder.AppendLine('            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null')
    [void]$builder.AppendLine('        }')
    [void]$builder.AppendLine('        if ($null -ne $tempPath) {')
    [void]$builder.AppendLine('            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue')
    [void]$builder.AppendLine('        }')
    [void]$builder.AppendLine('    }')
    [void]$builder.AppendLine('}')
    [void]$builder.AppendLine(("Invoke-RunCommandTaskBlock -TaskName '{0}' -ScriptBase64 '{1}' -TimeoutSeconds {2}" -f $taskNameSafe, $taskBase64, [int]$TimeoutSeconds))
    [void]$builder.AppendLine('Write-Host ("RUN_COMMAND_SUMMARY:success={0};warning={1};error={2};reboot={3}" -f $script:SuccessCount, $script:WarningCount, $script:ErrorCount, $script:RebootCount)')
    return $builder.ToString()
}

function Invoke-AzVmSingleRunCommandTask {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup,
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        [Parameter(Mandatory = $true)]
        [string]$CommandId,
        [Parameter(Mandatory = $true)]
        [psobject]$TaskBlock,
        [ValidateSet('bash','powershell')]
        [string]$CombinedShell = 'powershell',
        [ValidateSet('continue','strict')]
        [string]$TaskOutcomeMode = 'continue',
        [ValidateSet('vm-init-task','task-run')]
        [string]$PerfTaskCategory = 'vm-init-task'
    )

    $taskName = [string]$TaskBlock.Name
    $taskScript = Resolve-AzVmRunCommandScriptText -ScriptText ([string]$TaskBlock.Script)
    $taskTimeoutSeconds = Get-AzVmTaskTimeoutSeconds -TaskBlock $TaskBlock -DefaultTimeoutSeconds 180
    $wrappedScript = New-AzVmRunCommandTaskWrapperScript -TaskName $taskName -TaskScript $taskScript -TimeoutSeconds $taskTimeoutSeconds -CombinedShell $CombinedShell
    $scriptArgs = Get-AzVmRunCommandScriptArgs -ScriptText $wrappedScript -CommandId $CommandId
    $azArgs = @(
        'vm', 'run-command', 'invoke',
        '--resource-group', $ResourceGroup,
        '--name', $VmName,
        '--command-id', $CommandId,
        '--scripts'
    )
    $azArgs += $scriptArgs
    $azArgs += @('-o', 'json')
    $invokeLabel = ("az vm run-command invoke ({0})" -f [string]$taskName)
    $rawJson = Invoke-TrackedAction -Label $invokeLabel -Action {
        $invokeResult = az @azArgs
        Assert-LastExitCode $invokeLabel
        $invokeResult
    }

    $messageText = Get-AzVmRunCommandResultMessage -TaskName $taskName -RawJson $rawJson -ModeLabel 'task-run'
    if (-not [string]::IsNullOrWhiteSpace([string]$messageText)) {
        Write-Host ([string]$messageText)
    }

    $marker = Parse-AzVmRunCommandBatchMarkers -MessageText $messageText
    $taskDurations = @(Get-AzVmTaskDurationsFromMessageText -MessageText $messageText)
    if ($script:PerfMode -and $taskDurations.Count -gt 0) {
        foreach ($taskDuration in $taskDurations) {
            Write-AzVmPerfTiming -Category $PerfTaskCategory -Label ([string]$taskDuration.Name) -Seconds ([double]$taskDuration.Seconds)
        }
    }

    return [pscustomobject]@{
        TaskName = [string]$taskName
        MessageText = [string]$messageText
        SuccessCount = [int]$marker.SuccessCount
        WarningCount = [int]$marker.WarningCount
        ErrorCount = [int]$marker.ErrorCount
        RebootRequired = ([bool]$marker.RebootRequired -or (Test-AzVmOutputIndicatesRebootRequired -MessageText $messageText))
        TaskDurations = @($taskDurations)
    }
}

# Handles Invoke-VmRunCommandBlocks.
function Invoke-VmRunCommandBlocks {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$CommandId,
        [object[]]$TaskBlocks,
        [ValidateSet('bash','powershell')]
        [string]$CombinedShell = 'powershell',
        [ValidateSet('continue','strict')]
        [string]$TaskOutcomeMode = 'continue',
        [ValidateSet('vm-init-task','task-run')]
        [string]$PerfTaskCategory = 'vm-init-task',
        [ValidateSet('windows','linux')]
        [string]$Platform = 'windows',
        [string]$RepoRoot = '',
        [string]$ManagerUser = '',
        [string]$AssistantUser = ''
    )

    if (-not $TaskBlocks -or $TaskBlocks.Count -eq 0) {
        throw 'VM run-command task list is empty.'
    }

    Write-Host 'VM init stage mode: tasks run one-by-one over Azure Run Command.'
    Write-Host ("Task outcome policy: {0}" -f $TaskOutcomeMode)

    $totalSuccess = 0
    $totalWarnings = 0
    $totalErrors = 0
    $rebootCount = 0
    $successfulTasks = @()
    $failedTasks = @()
    $warningTasks = @()
    $rebootRequestedTasks = @()
    $processedTaskCount = 0

    foreach ($taskBlock in @($TaskBlocks)) {
        $processedTaskCount++
        $taskName = [string]$taskBlock.Name
        $taskResult = $null

        try {
            $taskResult = Invoke-AzVmSingleRunCommandTask -ResourceGroup $ResourceGroup -VmName $VmName -CommandId $CommandId -TaskBlock $taskBlock -CombinedShell $CombinedShell -TaskOutcomeMode $TaskOutcomeMode -PerfTaskCategory $PerfTaskCategory
        }
        catch {
            $failedTasks += $taskName
            if ([string]::Equals([string]$TaskOutcomeMode, 'continue', [System.StringComparison]::OrdinalIgnoreCase)) {
                $totalWarnings++
                $warningTasks += ("{0} => invocation" -f [string]$taskName)
                Write-Warning ("Task warning: {0} failed in Azure Run Command => {1}" -f [string]$taskName, $_.Exception.Message)
                continue
            }

            $totalErrors++
            throw ("VM init task failed in Azure Run Command: {0} => {1}" -f [string]$taskName, $_.Exception.Message)
        }

        if ([int]$taskResult.SuccessCount -gt 0 -and [int]$taskResult.ErrorCount -eq 0) {
            $totalSuccess += [int]$taskResult.SuccessCount
            $successfulTasks += $taskName

            $appStateResult = Invoke-AzVmTaskAppStatePostProcess `
                -Platform $Platform `
                -Transport 'run-command' `
                -RepoRoot $RepoRoot `
                -TaskBlock $taskBlock `
                -ResourceGroup $ResourceGroup `
                -VmName $VmName `
                -RunCommandId $CommandId `
                -TimeoutSeconds (Get-AzVmTaskTimeoutSeconds -TaskBlock $taskBlock -DefaultTimeoutSeconds 180) `
                -ManagerUser ([string]$ManagerUser) `
                -AssistantUser ([string]$AssistantUser)
            if ($null -ne $appStateResult -and $appStateResult.PSObject.Properties.Match('Warning').Count -gt 0 -and [bool]$appStateResult.Warning) {
                $totalWarnings++
                $warningTasks += ("{0} => app-state" -f [string]$taskName)
            }
        }
        else {
            $failedTasks += $taskName
            if ([string]::Equals([string]$TaskOutcomeMode, 'continue', [System.StringComparison]::OrdinalIgnoreCase)) {
                $totalWarnings += [Math]::Max([int]$taskResult.WarningCount + [int]$taskResult.ErrorCount, 1)
                $warningTasks += ("{0} => task-result" -f [string]$taskName)
                continue
            }

            $totalErrors += [Math]::Max([int]$taskResult.ErrorCount, 1)
            throw ("VM init task failed: {0}" -f [string]$taskName)
        }

        if ([bool]$taskResult.RebootRequired) {
            $rebootCount++
            $rebootRequestedTasks += $taskName
            Write-Host ("Task '{0}' requested a VM restart. The request was recorded and deferred until the vm-init stage completes." -f [string]$taskName) -ForegroundColor Yellow
            if ([string]::Equals([string]$TaskOutcomeMode, 'continue', [System.StringComparison]::OrdinalIgnoreCase)) {
                $totalWarnings++
                $warningTasks += ("{0} => reboot" -f [string]$taskName)
            }
        }
    }

    $uniqueSuccessfulTasks = @($successfulTasks | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    $uniqueFailedTasks = @($failedTasks | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    $uniqueWarningTasks = @($warningTasks | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

    Write-Host ("VM init stage summary: success={0}, failed={1}, warning={2}, error={3}, reboot={4}" -f @($uniqueSuccessfulTasks).Count, @($uniqueFailedTasks).Count, $totalWarnings, $totalErrors, $rebootCount)
    if (@($uniqueWarningTasks).Count -gt 0) {
        Write-Host 'Warning tasks:' -ForegroundColor Yellow
        foreach ($warningTask in @($uniqueWarningTasks)) {
            Write-Host ("- {0}" -f [string]$warningTask) -ForegroundColor Yellow
        }
    }
    if (@($uniqueFailedTasks).Count -gt 0) {
        Write-Host 'Failed tasks:' -ForegroundColor Yellow
        foreach ($failedTaskName in @($uniqueFailedTasks)) {
            Write-Host ("- {0}" -f [string]$failedTaskName) -ForegroundColor Yellow
        }
    }
    if ($rebootCount -gt 0) {
        $rebootTaskList = @($rebootRequestedTasks | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
        if (@($rebootTaskList).Count -eq 0) {
            $rebootTaskList = @('(task names unavailable)')
        }
        Write-Host 'VM restart requirement detected after vm-init.' -ForegroundColor Yellow
        Write-Host 'Tasks requesting restart:' -ForegroundColor Yellow
        foreach ($rebootTaskName in @($rebootTaskList)) {
            Write-Host ("- {0}" -f [string]$rebootTaskName) -ForegroundColor Yellow
        }
        Write-Host ("Hint: restart the VM if the restored init state depends on a reboot: az vm restart --resource-group {0} --name {1}" -f [string]$ResourceGroup, [string]$VmName) -ForegroundColor Cyan
    }
    if ([string]::Equals([string]$TaskOutcomeMode, 'strict', [System.StringComparison]::OrdinalIgnoreCase) -and ($totalWarnings -gt 0 -or $totalErrors -gt 0)) {
        throw ("VM init strict task outcome mode blocked continuation: warning={0}, error={1}" -f $totalWarnings, $totalErrors)
    }

    return [pscustomobject]@{
        SuccessCount = $totalSuccess
        WarningCount = $totalWarnings
        ErrorCount = $totalErrors
        RebootRequired = ($rebootCount -gt 0)
        NextTaskIndex = [int]$processedTaskCount
        TaskDurations = @()
    }
}
