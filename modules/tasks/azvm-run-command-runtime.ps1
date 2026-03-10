# Imported runtime region: test-runcommand.

# Handles Resolve-AzVmRunCommandScriptText.
function Resolve-AzVmRunCommandScriptText {
    param(
        [string]$ScriptText
    )

    if ([string]::IsNullOrWhiteSpace($ScriptText)) {
        throw "VM run-command task script content is empty."
    }

    if ($ScriptText.StartsWith("@")) {
        $scriptPath = $ScriptText.Substring(1)
        if (-not (Test-Path -LiteralPath $scriptPath)) {
            throw "VM run-command task script file was not found: $scriptPath"
        }
        return (Get-Content -Path $scriptPath -Raw)
    }

    return $ScriptText
}

# Handles Get-AzVmRunCommandScriptArgs.
function Get-AzVmRunCommandScriptArgs {
    param(
        [string]$ScriptText,
        [string]$CommandId
    )

    if ([string]::IsNullOrWhiteSpace($ScriptText)) {
        throw "VM run-command task script content is empty."
    }

    if ($ScriptText.StartsWith("@")) {
        return @($ScriptText)
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'az-vm-run-command'
    if (-not (Test-Path -LiteralPath $tempRoot)) {
        [void](New-Item -ItemType Directory -Path $tempRoot -Force)
    }

    $extension = if ($CommandId -eq "RunPowerShellScript") { ".ps1" } else { ".sh" }
    $fileName = "task-{0}{1}" -f ([System.Guid]::NewGuid().ToString("N")), $extension
    $tempPath = Join-Path $tempRoot $fileName

    Write-TextFileNormalized -Path $tempPath -Content $ScriptText -Encoding "utf8NoBom" -EnsureTrailingNewline:$true
    return @("@$tempPath")
}

# Handles Test-AzVmBenignRunCommandStdErr.
function Test-AzVmBenignRunCommandStdErr {
    param(
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace([string]$Message)) {
        return $false
    }

    $normalized = [string]$Message
    $normalized = $normalized -replace "`r", " "
    $normalized = $normalized -replace "`n", " "

    $benignPatterns = @(
        "(?i)'wmic'\s+is\s+not\s+recognized\s+as\s+an\s+internal\s+or\s+external\s+command"
    )

    foreach ($pattern in $benignPatterns) {
        if ($normalized -match $pattern) {
            return $true
        }
    }

    return $false
}

# Handles Get-AzVmRunCommandResultMessage.
function Get-AzVmRunCommandResultMessage {
    param(
        [string]$TaskName,
        [object]$RawJson,
        [string]$ModeLabel
    )

    if ($null -eq $RawJson -or [string]::IsNullOrWhiteSpace([string]$RawJson)) {
        throw "VM $ModeLabel task '$TaskName' run-command output is empty."
    }

    try {
        $result = ConvertFrom-JsonCompat -InputObject $RawJson
    }
    catch {
        throw "VM $ModeLabel task '$TaskName' run-command output could not be parsed as JSON."
    }

    $resultEntries = ConvertTo-ObjectArrayCompat -InputObject $result.value
    if (-not $resultEntries -or $resultEntries.Count -eq 0) {
        throw "VM $ModeLabel task '$TaskName' run-command output is empty."
    }

    $messages = @()
    $hasError = $false
    foreach ($entry in $resultEntries) {
        $code = [string]$entry.code
        $message = [string]$entry.message
        $isFailedCode = ($code -match '(?i)/failed$')
        $isStdErrCode = ($code -match '(?i)StdErr')
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            $messages += $message.Trim()
        }

        if ($isStdErrCode -and -not [string]::IsNullOrWhiteSpace($message)) {
            if (Test-AzVmBenignRunCommandStdErr -Message $message) {
                Write-Warning ("Ignoring benign run-command stderr line for task '{0}': {1}" -f $TaskName, $message.Trim())
            }
            elseif ($message -match '(?i)(terminatingerror|exception|failed|not recognized|cannot find|categoryinfo)') {
                $hasError = $true
            }
            elseif ($isFailedCode) {
                $hasError = $true
            }
        }
        elseif ($isFailedCode) {
            $hasError = $true
        }
    }

    if ($hasError) {
        $joinedMessages = ($messages -join " | ")
        throw "VM $ModeLabel task '$TaskName' reported error: $joinedMessages"
    }

    return ($messages -join "`n")
}

# Handles Parse-AzVmRunCommandBatchMarkers.
function Parse-AzVmRunCommandBatchMarkers {
    param(
        [string]$MessageText
    )

    $result = [ordered]@{
        SuccessCount = 0
        WarningCount = 0
        ErrorCount = 0
        RebootCount = 0
        RebootRequired = $false
        HasSummaryLine = $false
        SummaryLine = ""
    }

    if ([string]::IsNullOrWhiteSpace($MessageText)) {
        return [pscustomobject]$result
    }

    $lines = @($MessageText -split "`r?`n")
    foreach ($line in $lines) {
        $trimmed = [string]$line
        if ($trimmed -match '^TASK_STATUS:(.+?):(success|warning|error)$') {
            $status = [string]$Matches[2]
            switch ($status) {
                "success" { $result.SuccessCount++ }
                "warning" { $result.WarningCount++ }
                "error" { $result.ErrorCount++ }
            }
            continue
        }

        if ($trimmed -match '^RUN_COMMAND_SUMMARY:success=(\d+);warning=(\d+);error=(\d+);reboot=(\d+)$') {
            $result.SuccessCount = [int]$Matches[1]
            $result.WarningCount = [int]$Matches[2]
            $result.ErrorCount = [int]$Matches[3]
            $result.RebootCount = [int]$Matches[4]
            $result.HasSummaryLine = $true
            $result.SummaryLine = $trimmed
            continue
        }

        if ($trimmed -match '^AZ_VM_REBOOT_REQUIRED:') {
            $result.RebootRequired = $true
            continue
        }
    }

    return [pscustomobject]$result
}

# Handles Test-AzVmOutputIndicatesRebootRequired.
function Test-AzVmOutputIndicatesRebootRequired {
    param(
        [string]$MessageText
    )

    if ([string]::IsNullOrWhiteSpace($MessageText)) {
        return $false
    }

    if ($MessageText -match '^AZ_VM_REBOOT_REQUIRED:' -or $MessageText -match '(?im)^TASK_REBOOT_REQUIRED:') {
        return $true
    }

    return ($MessageText -match '(?i)(reboot required|restart required|pending reboot|press any key to install windows subsystem for linux)')
}

# Handles Get-AzVmTaskDurationsFromMessageText.
function Get-AzVmTaskDurationsFromMessageText {
    param(
        [string]$MessageText
    )

    $durations = @()
    if ([string]::IsNullOrWhiteSpace([string]$MessageText)) {
        return @()
    }

    foreach ($lineRaw in @($MessageText -split "`r?`n")) {
        $line = [string]$lineRaw
        if ($line -match '^TASK completed:\s*(.+?)\s*\(([0-9]+(?:\.[0-9]+)?)s\)\s*$') {
            $taskName = [string]$Matches[1]
            $seconds = [double]$Matches[2]
            $durations += [pscustomobject]@{
                Name = $taskName
                Seconds = $seconds
            }
        }
    }

    return @($durations)
}

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
        [ValidateSet("vm-init-task","exec-task")]
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

# Handles Apply-AzVmTaskBlockReplacements.
function Apply-AzVmTaskBlockReplacements {
    param(
        [object[]]$TaskBlocks,
        [hashtable]$Replacements
    )

    if (-not $TaskBlocks) {
        return @()
    }

    $resolvedBlocks = @()
    foreach ($taskBlock in $TaskBlocks) {
        $taskName = [string]$taskBlock.Name
        $taskScript = [string]$taskBlock.Script
        $relativePath = ''
        $directoryPath = ''
        if ($taskBlock.PSObject.Properties.Match('RelativePath').Count -gt 0) {
            $relativePath = [string]$taskBlock.RelativePath
        }
        if ($taskBlock.PSObject.Properties.Match('DirectoryPath').Count -gt 0) {
            $directoryPath = [string]$taskBlock.DirectoryPath
        }
        $timeoutSeconds = 180
        if ($taskBlock.PSObject.Properties.Match('TimeoutSeconds').Count -gt 0) {
            $timeoutSeconds = Get-AzVmTaskTimeoutSeconds -TaskBlock $taskBlock -DefaultTimeoutSeconds 180
        }
        $assetSpecs = @()
        if ($taskBlock.PSObject.Properties.Match('AssetSpecs').Count -gt 0 -and $null -ne $taskBlock.AssetSpecs) {
            $assetSpecs = @(ConvertTo-ObjectArrayCompat -InputObject $taskBlock.AssetSpecs)
        }

        if ($Replacements) {
            foreach ($key in $Replacements.Keys) {
                $token = "__{0}__" -f [string]$key
                $value = [string]$Replacements[$key]
                $taskScript = $taskScript.Replace($token, $value)
            }
        }

        $assetCopies = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$directoryPath)) {
            foreach ($assetSpec in @($assetSpecs)) {
                $assetLocalPath = [string]$assetSpec.LocalPath
                $assetRemotePath = [string]$assetSpec.RemotePath
                if ($Replacements) {
                    foreach ($key in $Replacements.Keys) {
                        $token = "__{0}__" -f [string]$key
                        $value = [string]$Replacements[$key]
                        $assetLocalPath = $assetLocalPath.Replace($token, $value)
                        $assetRemotePath = $assetRemotePath.Replace($token, $value)
                    }
                }

                if (-not [System.IO.Path]::IsPathRooted($assetLocalPath)) {
                    $assetLocalPath = Join-Path $directoryPath ($assetLocalPath.Replace('/', '\'))
                }
                if (-not (Test-Path -LiteralPath $assetLocalPath)) {
                    throw ("Task asset was not found for '{0}': {1}" -f $taskName, $assetLocalPath)
                }

                $assetCopies += [pscustomobject]@{
                    LocalPath = [string](Resolve-Path -LiteralPath $assetLocalPath).Path
                    RemotePath = [string]$assetRemotePath
                }
            }

            if ($taskName -in @('34-configure-ux-windows', '36-copy-settings-user', '28-install-be-my-eyes')) {
                $repoRoot = Split-Path -Path (Split-Path -Path $directoryPath -Parent) -Parent
                $helperLocalPath = Join-Path $repoRoot 'tools\windows\az-vm-interactive-session-helper.ps1'
                if (-not (Test-Path -LiteralPath $helperLocalPath)) {
                    throw ("Interactive session helper was not found for '{0}': {1}" -f $taskName, $helperLocalPath)
                }

                $assetCopies += [pscustomobject]@{
                    LocalPath = [string](Resolve-Path -LiteralPath $helperLocalPath).Path
                    RemotePath = 'C:/Windows/Temp/az-vm-interactive-session-helper.ps1'
                }
            }
        }

        $resolvedBlocks += [pscustomobject]@{
            Name = $taskName
            Script = $taskScript
            RelativePath = $relativePath
            DirectoryPath = $directoryPath
            AssetCopies = @($assetCopies)
            TimeoutSeconds = [int]$timeoutSeconds
        }
    }

    return $resolvedBlocks
}

# Handles Wait-AzVmVmRunningState.
function Wait-AzVmVmRunningState {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 10
    )

    if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
    if ($MaxAttempts -gt 3) { $MaxAttempts = 3 }
    if ($DelaySeconds -lt 1) { $DelaySeconds = 1 }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $powerState = az vm get-instance-view `
            --resource-group $ResourceGroup `
            --name $VmName `
            --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" `
            -o tsv
        Assert-LastExitCode "az vm get-instance-view (power state)"

        if ([string]::IsNullOrWhiteSpace([string]$powerState)) {
            Write-Host ("VM power state is empty (attempt {0}/{1})." -f $attempt, $MaxAttempts) -ForegroundColor Yellow
        }
        else {
            Write-Host ("VM power state: {0} (attempt {1}/{2})" -f [string]$powerState, $attempt, $MaxAttempts)
            if ([string]$powerState -eq "VM running") {
                return $true
            }
        }

        Start-Sleep -Seconds $DelaySeconds
    }

    return $false
}



