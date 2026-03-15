# Run-command task-batch runner.

# Handles Invoke-VmRunCommandBlocks.
function Invoke-VmRunCommandBlocks {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$CommandId,
        [object[]]$TaskBlocks,
        [ValidateSet("bash","powershell")]
        [string]$CombinedShell = "powershell",
        [ValidateSet("continue","strict")]
        [string]$TaskOutcomeMode = "continue",
        [ValidateSet("vm-init-task","task-run")]
        [string]$PerfTaskCategory = "vm-init-task"
    )

    if (-not $TaskBlocks -or $TaskBlocks.Count -eq 0) {
        throw "VM run-command task list is empty."
    }
    Write-Host "Task-batch mode is enabled: init tasks will run in a single run-command call."
    Write-Host ("Task outcome policy: {0}" -f $TaskOutcomeMode)

    $combinedBuilder = New-Object System.Text.StringBuilder
    if ($CombinedShell -eq "bash") {
        [void]$combinedBuilder.AppendLine('set -uo pipefail')
        [void]$combinedBuilder.AppendLine(("VM_TASK_OUTCOME_MODE='{0}'" -f $TaskOutcomeMode))
        [void]$combinedBuilder.AppendLine('success_count=0')
        [void]$combinedBuilder.AppendLine('warning_count=0')
        [void]$combinedBuilder.AppendLine('error_count=0')
        [void]$combinedBuilder.AppendLine('reboot_count=0')
        [void]$combinedBuilder.AppendLine('strict_failure=0')
        [void]$combinedBuilder.AppendLine('invoke_combined_task() {')
        [void]$combinedBuilder.AppendLine('  local task_name_base64="$1"')
        [void]$combinedBuilder.AppendLine('  local script_base64="$2"')
        [void]$combinedBuilder.AppendLine('  local task_timeout="$3"')
        [void]$combinedBuilder.AppendLine('  local task_name')
        [void]$combinedBuilder.AppendLine('  task_name=$(printf ''%s'' "$task_name_base64" | base64 -d)')
        [void]$combinedBuilder.AppendLine('  echo "TASK started: ${task_name} (max ${task_timeout}s)"')
        [void]$combinedBuilder.AppendLine('  local start_ts')
        [void]$combinedBuilder.AppendLine('  start_ts=$(date +%s)')
        [void]$combinedBuilder.AppendLine('  local task_script')
        [void]$combinedBuilder.AppendLine('  task_script=$(printf ''%s'' "$script_base64" | base64 -d)')
        [void]$combinedBuilder.AppendLine('  local task_output=""')
        [void]$combinedBuilder.AppendLine('  if task_output=$(timeout --signal=TERM --kill-after=15 "${task_timeout}" bash -lc "$task_script" 2>&1); then')
        [void]$combinedBuilder.AppendLine('    local end_ts')
        [void]$combinedBuilder.AppendLine('    end_ts=$(date +%s)')
        [void]$combinedBuilder.AppendLine('    local elapsed=$(( end_ts - start_ts ))')
        [void]$combinedBuilder.AppendLine('    if [ -n "$task_output" ]; then')
        [void]$combinedBuilder.AppendLine('      printf ''%s\n'' "$task_output"')
        [void]$combinedBuilder.AppendLine('    fi')
        [void]$combinedBuilder.AppendLine('    echo "TASK completed: ${task_name} (${elapsed}s)"')
        [void]$combinedBuilder.AppendLine('    echo "TASK result: success"')
        [void]$combinedBuilder.AppendLine('    echo "TASK_STATUS:${task_name}:success"')
        [void]$combinedBuilder.AppendLine('    success_count=$(( success_count + 1 ))')
        [void]$combinedBuilder.AppendLine('  else')
        [void]$combinedBuilder.AppendLine('    local exit_code=$?')
        [void]$combinedBuilder.AppendLine('    local end_ts')
        [void]$combinedBuilder.AppendLine('    end_ts=$(date +%s)')
        [void]$combinedBuilder.AppendLine('    local elapsed=$(( end_ts - start_ts ))')
        [void]$combinedBuilder.AppendLine('    if [ -n "$task_output" ]; then')
        [void]$combinedBuilder.AppendLine('      printf ''%s\n'' "$task_output"')
        [void]$combinedBuilder.AppendLine('    fi')
        [void]$combinedBuilder.AppendLine('    echo "TASK completed: ${task_name} (${elapsed}s)"')
        [void]$combinedBuilder.AppendLine('    if [ "$exit_code" -eq 124 ] || [ "$exit_code" -eq 137 ]; then')
        [void]$combinedBuilder.AppendLine('      echo "TASK result: timeout (${task_name})"')
        [void]$combinedBuilder.AppendLine('    else')
        [void]$combinedBuilder.AppendLine('      echo "TASK result: failure (${task_name})"')
        [void]$combinedBuilder.AppendLine('    fi')
        [void]$combinedBuilder.AppendLine('    echo "TASK_STATUS:${task_name}:error"')
        [void]$combinedBuilder.AppendLine('    error_count=$(( error_count + 1 ))')
        [void]$combinedBuilder.AppendLine('    if [ "$VM_TASK_OUTCOME_MODE" = "strict" ]; then')
        [void]$combinedBuilder.AppendLine('      return 1')
        [void]$combinedBuilder.AppendLine('    fi')
        [void]$combinedBuilder.AppendLine('  fi')
        [void]$combinedBuilder.AppendLine('}')
    }
    else {
        [void]$combinedBuilder.AppendLine('$ErrorActionPreference = "Stop"')
        [void]$combinedBuilder.AppendLine('$ProgressPreference = "SilentlyContinue"')
        [void]$combinedBuilder.AppendLine(('$TaskOutcomeMode = "{0}"' -f $TaskOutcomeMode))
        [void]$combinedBuilder.AppendLine('$script:SuccessCount = 0')
        [void]$combinedBuilder.AppendLine('$script:WarningCount = 0')
        [void]$combinedBuilder.AppendLine('$script:ErrorCount = 0')
        [void]$combinedBuilder.AppendLine('$script:RebootCount = 0')
        [void]$combinedBuilder.AppendLine('$script:StrictFailure = $false')
        [void]$combinedBuilder.AppendLine('function Invoke-CombinedTaskBlock {')
        [void]$combinedBuilder.AppendLine('    param([string]$TaskName,[string]$ScriptBase64,[int]$TimeoutSeconds,[string]$TaskOutcomeMode)')
        [void]$combinedBuilder.AppendLine('    if ($TimeoutSeconds -lt 5) { $TimeoutSeconds = 5 }')
        [void]$combinedBuilder.AppendLine('    Write-Host ("TASK started: {0} (max {1}s)" -f $TaskName, $TimeoutSeconds)')
        [void]$combinedBuilder.AppendLine('    $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()')
        [void]$combinedBuilder.AppendLine('    $completionWritten = $false')
        [void]$combinedBuilder.AppendLine('    $job = $null')
        [void]$combinedBuilder.AppendLine('    $tempPath = $null')
        [void]$combinedBuilder.AppendLine('    try {')
        [void]$combinedBuilder.AppendLine('        $decodedScript = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($ScriptBase64))')
        [void]$combinedBuilder.AppendLine('        $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("az-vm-init-task-{0}.ps1" -f [System.Guid]::NewGuid().ToString("N"))')
        [void]$combinedBuilder.AppendLine('        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)')
        [void]$combinedBuilder.AppendLine('        [System.IO.File]::WriteAllText($tempPath, $decodedScript, $utf8NoBom)')
        [void]$combinedBuilder.AppendLine('        $job = Start-Job -ArgumentList $tempPath -ScriptBlock {')
        [void]$combinedBuilder.AppendLine('            param($TaskPath)')
        [void]$combinedBuilder.AppendLine('            $commandOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TaskPath 2>&1')
        [void]$combinedBuilder.AppendLine('            [pscustomobject]@{ ExitCode = [int]$LASTEXITCODE; Lines = @($commandOutput | ForEach-Object { [string]$_ }) }')
        [void]$combinedBuilder.AppendLine('        }')
        [void]$combinedBuilder.AppendLine('        $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds')
        [void]$combinedBuilder.AppendLine('        if ($null -eq $completed) {')
        [void]$combinedBuilder.AppendLine('            Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null')
        [void]$combinedBuilder.AppendLine('            throw "Task timed out."')
        [void]$combinedBuilder.AppendLine('        }')
        [void]$combinedBuilder.AppendLine('        $jobResult = Receive-Job -Job $job -ErrorAction Stop')
        [void]$combinedBuilder.AppendLine('        if ($jobResult -is [System.Array] -and $jobResult.Count -gt 0) {')
        [void]$combinedBuilder.AppendLine('            $jobResult = $jobResult[-1]')
        [void]$combinedBuilder.AppendLine('        }')
        [void]$combinedBuilder.AppendLine('        $jobOutputLines = @()')
        [void]$combinedBuilder.AppendLine('        $jobExitCode = 0')
        [void]$combinedBuilder.AppendLine('        if ($null -ne $jobResult) {')
        [void]$combinedBuilder.AppendLine('            if ($jobResult.PSObject.Properties.Match("Lines").Count -gt 0 -and $null -ne $jobResult.Lines) {')
        [void]$combinedBuilder.AppendLine('                $jobOutputLines = @($jobResult.Lines | ForEach-Object { [string]$_ })')
        [void]$combinedBuilder.AppendLine('            }')
        [void]$combinedBuilder.AppendLine('            if ($jobResult.PSObject.Properties.Match("ExitCode").Count -gt 0) {')
        [void]$combinedBuilder.AppendLine('                $jobExitCode = [int]$jobResult.ExitCode')
        [void]$combinedBuilder.AppendLine('            }')
        [void]$combinedBuilder.AppendLine('        }')
        [void]$combinedBuilder.AppendLine('        foreach ($line in @($jobOutputLines)) {')
        [void]$combinedBuilder.AppendLine('            if (-not [string]::IsNullOrWhiteSpace([string]$line)) {')
        [void]$combinedBuilder.AppendLine('                Write-Host ([string]$line)')
        [void]$combinedBuilder.AppendLine('            }')
        [void]$combinedBuilder.AppendLine('        }')
        [void]$combinedBuilder.AppendLine('        if ($taskWatch.IsRunning) { $taskWatch.Stop() }')
        [void]$combinedBuilder.AppendLine('        Write-Host ("TASK completed: {0} ({1:N1}s)" -f $TaskName, $taskWatch.Elapsed.TotalSeconds)')
        [void]$combinedBuilder.AppendLine('        $completionWritten = $true')
        [void]$combinedBuilder.AppendLine('        if ($jobExitCode -ne 0) { throw ("Task exited with code {0}." -f $jobExitCode) }')
        [void]$combinedBuilder.AppendLine('        Write-Host "TASK result: success"')
        [void]$combinedBuilder.AppendLine('        Write-Host ("TASK_STATUS:{0}:success" -f $TaskName)')
        [void]$combinedBuilder.AppendLine('        $script:SuccessCount++')
        [void]$combinedBuilder.AppendLine('        return $true')
        [void]$combinedBuilder.AppendLine('    }')
        [void]$combinedBuilder.AppendLine('    catch {')
        [void]$combinedBuilder.AppendLine('        if ($taskWatch.IsRunning) { $taskWatch.Stop() }')
        [void]$combinedBuilder.AppendLine('        if (-not $completionWritten) {')
        [void]$combinedBuilder.AppendLine('            Write-Host ("TASK completed: {0} ({1:N1}s)" -f $TaskName, $taskWatch.Elapsed.TotalSeconds)')
        [void]$combinedBuilder.AppendLine('        }')
        [void]$combinedBuilder.AppendLine('        Write-Host ("TASK result: failure ({0})" -f $TaskName)')
        [void]$combinedBuilder.AppendLine('        Write-Host ("TASK_STATUS:{0}:error" -f $TaskName)')
        [void]$combinedBuilder.AppendLine('        $script:ErrorCount++')
        [void]$combinedBuilder.AppendLine('        if ([string]::Equals($TaskOutcomeMode, "strict", [System.StringComparison]::OrdinalIgnoreCase)) {')
        [void]$combinedBuilder.AppendLine('            return $false')
        [void]$combinedBuilder.AppendLine('        }')
        [void]$combinedBuilder.AppendLine('        return $true')
        [void]$combinedBuilder.AppendLine('    }')
        [void]$combinedBuilder.AppendLine('    finally {')
        [void]$combinedBuilder.AppendLine('        if ($null -ne $job) {')
        [void]$combinedBuilder.AppendLine('            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null')
        [void]$combinedBuilder.AppendLine('        }')
        [void]$combinedBuilder.AppendLine('        if ($null -ne $tempPath) {')
        [void]$combinedBuilder.AppendLine('            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue')
        [void]$combinedBuilder.AppendLine('        }')
        [void]$combinedBuilder.AppendLine('    }')
        [void]$combinedBuilder.AppendLine('}')
    }

    foreach ($taskBlock in $TaskBlocks) {
        $taskName = [string]$taskBlock.Name
        $taskScript = Resolve-AzVmRunCommandScriptText -ScriptText ([string]$taskBlock.Script)
        $taskTimeoutSeconds = Get-AzVmTaskTimeoutSeconds -TaskBlock $taskBlock -DefaultTimeoutSeconds 180
        if ($CombinedShell -eq "bash") {
            $taskNameBytes = [System.Text.Encoding]::UTF8.GetBytes($taskName)
            $taskNameBase64 = [System.Convert]::ToBase64String($taskNameBytes)
            $taskBytes = [System.Text.Encoding]::UTF8.GetBytes($taskScript)
            $taskBase64 = [System.Convert]::ToBase64String($taskBytes)
            [void]$combinedBuilder.AppendLine(("if ! invoke_combined_task '{0}' '{1}' '{2}'; then strict_failure=1; break; fi" -f $taskNameBase64, $taskBase64, [int]$taskTimeoutSeconds))
        }
        else {
            $taskNameSafe = $taskName.Replace("'", "''")
            $taskBytes = [System.Text.Encoding]::UTF8.GetBytes($taskScript)
            $taskBase64 = [System.Convert]::ToBase64String($taskBytes)
            [void]$combinedBuilder.AppendLine(('$taskSucceeded = Invoke-CombinedTaskBlock -TaskName ''{0}'' -ScriptBase64 ''{1}'' -TimeoutSeconds {2} -TaskOutcomeMode $TaskOutcomeMode' -f $taskNameSafe, $taskBase64, [int]$taskTimeoutSeconds))
            [void]$combinedBuilder.AppendLine('if (-not $taskSucceeded) { $script:StrictFailure = $true; break }')
        }
    }
    if ($CombinedShell -eq "bash") {
        [void]$combinedBuilder.AppendLine('echo "RUN_COMMAND_SUMMARY:success=${success_count};warning=${warning_count};error=${error_count};reboot=${reboot_count}"')
        [void]$combinedBuilder.AppendLine('if [ "$VM_TASK_OUTCOME_MODE" = "strict" ] && [ "$strict_failure" -ne 0 ]; then')
        [void]$combinedBuilder.AppendLine('  exit 1')
        [void]$combinedBuilder.AppendLine('fi')
    }
    else {
        [void]$combinedBuilder.AppendLine('Write-Host ("RUN_COMMAND_SUMMARY:success={0};warning={1};error={2};reboot={3}" -f $script:SuccessCount, $script:WarningCount, $script:ErrorCount, $script:RebootCount)')
        [void]$combinedBuilder.AppendLine('if ([string]::Equals($TaskOutcomeMode, "strict", [System.StringComparison]::OrdinalIgnoreCase) -and $script:StrictFailure) {')
        [void]$combinedBuilder.AppendLine('    throw "One or more VM init tasks failed in strict mode."')
        [void]$combinedBuilder.AppendLine('}')
    }

    $combinedScript = $combinedBuilder.ToString()
    try {
        $combinedArgs = Get-AzVmRunCommandScriptArgs -ScriptText $combinedScript -CommandId $CommandId
        $combinedAzArgs = @(
            "vm", "run-command", "invoke",
            "--resource-group", $ResourceGroup,
            "--name", $VmName,
            "--command-id", $CommandId,
            "--scripts"
        )
        $combinedAzArgs += $combinedArgs
        $combinedAzArgs += @("-o", "json")
        $combinedInvokeLabel = "az vm run-command invoke (task-batch-combined)"
        $combinedJson = Invoke-TrackedAction -Label $combinedInvokeLabel -Action {
            $invokeResult = az @combinedAzArgs
            Assert-LastExitCode "az vm run-command invoke (task-batch-combined)"
            $invokeResult
        }
        $combinedMessage = Get-AzVmRunCommandResultMessage -TaskName "combined-task-batch" -RawJson $combinedJson -ModeLabel "auto-mode"
        Write-Host "TASK batch run-command completed."
        if (-not [string]::IsNullOrWhiteSpace($combinedMessage)) {
            Write-Host $combinedMessage
        }

        $marker = Parse-AzVmRunCommandBatchMarkers -MessageText $combinedMessage
        $taskDurations = @(Get-AzVmTaskDurationsFromMessageText -MessageText $combinedMessage)
        if ($script:PerfMode -and $taskDurations.Count -gt 0) {
            foreach ($taskDuration in $taskDurations) {
                Write-AzVmPerfTiming -Category $PerfTaskCategory -Label ([string]$taskDuration.Name) -Seconds ([double]$taskDuration.Seconds)
            }
        }
        return [pscustomobject]@{
            SuccessCount = [int]$marker.SuccessCount
            WarningCount = [int]$marker.WarningCount
            ErrorCount = [int]$marker.ErrorCount
            RebootRequired = ([bool]$marker.RebootRequired -or (Test-AzVmOutputIndicatesRebootRequired -MessageText $combinedMessage))
            NextTaskIndex = [int]$TaskBlocks.Count
            TaskDurations = @($taskDurations)
        }
    }
    catch {
        throw "VM task batch execution failed in combined flow: $($_.Exception.Message)"
    }
}
