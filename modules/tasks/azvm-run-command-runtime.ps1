# Imported runtime region: test-runcommand.

# Handles Resolve-CoRunCommandScriptText.
function Resolve-CoRunCommandScriptText {
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

# Handles Get-CoRunCommandScriptArgs.
function Get-CoRunCommandScriptArgs {
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

# Handles Get-CoRunCommandResultMessage.
function Get-CoRunCommandResultMessage {
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

# Handles Parse-AzVmStep8Markers.
function Parse-AzVmStep8Markers {
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

        if ($trimmed -match '^STEP8_SUMMARY:success=(\d+);warning=(\d+);error=(\d+);reboot=(\d+)$') {
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
        [ValidateSet("vm-init-task","exec-task")]
        [string]$PerfTaskCategory = "vm-init-task"
    )

    if (-not $TaskBlocks -or $TaskBlocks.Count -eq 0) {
        throw "VM run-command task list is empty."
    }
    Write-Host "Task-batch mode is enabled: init tasks will run in a single run-command call."

    $combinedBuilder = New-Object System.Text.StringBuilder
    if ($CombinedShell -eq "bash") {
        [void]$combinedBuilder.AppendLine('set -euo pipefail')
        [void]$combinedBuilder.AppendLine('invoke_combined_task() {')
        [void]$combinedBuilder.AppendLine('  local task_name_base64="$1"')
        [void]$combinedBuilder.AppendLine('  local script_base64="$2"')
        [void]$combinedBuilder.AppendLine('  local task_name')
        [void]$combinedBuilder.AppendLine('  task_name=$(printf ''%s'' "$task_name_base64" | base64 -d)')
        [void]$combinedBuilder.AppendLine('  echo "TASK started: ${task_name}"')
        [void]$combinedBuilder.AppendLine('  local start_ts')
        [void]$combinedBuilder.AppendLine('  start_ts=$(date +%s)')
        [void]$combinedBuilder.AppendLine('  local task_script')
        [void]$combinedBuilder.AppendLine('  task_script=$(printf ''%s'' "$script_base64" | base64 -d)')
        [void]$combinedBuilder.AppendLine('  if bash -lc "$task_script"; then')
        [void]$combinedBuilder.AppendLine('    local end_ts')
        [void]$combinedBuilder.AppendLine('    end_ts=$(date +%s)')
        [void]$combinedBuilder.AppendLine('    local elapsed=$(( end_ts - start_ts ))')
        [void]$combinedBuilder.AppendLine('    echo "TASK completed: ${task_name} (${elapsed}s)"')
        [void]$combinedBuilder.AppendLine('    echo "TASK result: success"')
        [void]$combinedBuilder.AppendLine('  else')
        [void]$combinedBuilder.AppendLine('    echo "TASK result: failure (${task_name})"')
        [void]$combinedBuilder.AppendLine('    return 1')
        [void]$combinedBuilder.AppendLine('  fi')
        [void]$combinedBuilder.AppendLine('}')
    }
    else {
        [void]$combinedBuilder.AppendLine('$ErrorActionPreference = "Stop"')
        [void]$combinedBuilder.AppendLine('$ProgressPreference = "SilentlyContinue"')
        [void]$combinedBuilder.AppendLine('function Invoke-CombinedTaskBlock {')
        [void]$combinedBuilder.AppendLine('    param([string]$TaskName,[string]$ScriptBase64)')
        [void]$combinedBuilder.AppendLine('    Write-Host "TASK started: $TaskName"')
        [void]$combinedBuilder.AppendLine('    $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()')
        [void]$combinedBuilder.AppendLine('    try {')
        [void]$combinedBuilder.AppendLine('        $decodedScript = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($ScriptBase64))')
        [void]$combinedBuilder.AppendLine('        Invoke-Expression $decodedScript')
        [void]$combinedBuilder.AppendLine('        $taskWatch.Stop()')
        [void]$combinedBuilder.AppendLine('        Write-Host ("TASK completed: {0} ({1:N1}s)" -f $TaskName, $taskWatch.Elapsed.TotalSeconds)')
        [void]$combinedBuilder.AppendLine('        Write-Host "TASK result: success"')
        [void]$combinedBuilder.AppendLine('    }')
        [void]$combinedBuilder.AppendLine('    catch {')
        [void]$combinedBuilder.AppendLine('        if ($taskWatch.IsRunning) { $taskWatch.Stop() }')
        [void]$combinedBuilder.AppendLine('        Write-Host "TASK result: failure ($TaskName)"')
        [void]$combinedBuilder.AppendLine('        throw')
        [void]$combinedBuilder.AppendLine('    }')
        [void]$combinedBuilder.AppendLine('}')
    }

    foreach ($taskBlock in $TaskBlocks) {
        $taskName = [string]$taskBlock.Name
        $taskScript = Resolve-CoRunCommandScriptText -ScriptText ([string]$taskBlock.Script)
        if ($CombinedShell -eq "bash") {
            $taskNameBytes = [System.Text.Encoding]::UTF8.GetBytes($taskName)
            $taskNameBase64 = [System.Convert]::ToBase64String($taskNameBytes)
            $taskBytes = [System.Text.Encoding]::UTF8.GetBytes($taskScript)
            $taskBase64 = [System.Convert]::ToBase64String($taskBytes)
            [void]$combinedBuilder.AppendLine(("invoke_combined_task '{0}' '{1}'" -f $taskNameBase64, $taskBase64))
        }
        else {
            $taskNameSafe = $taskName.Replace("'", "''")
            $taskBytes = [System.Text.Encoding]::UTF8.GetBytes($taskScript)
            $taskBase64 = [System.Convert]::ToBase64String($taskBytes)
            [void]$combinedBuilder.AppendLine(("Invoke-CombinedTaskBlock -TaskName '{0}' -ScriptBase64 '{1}'" -f $taskNameSafe, $taskBase64))
        }
    }

    $combinedScript = $combinedBuilder.ToString()
    try {
        $combinedArgs = Get-CoRunCommandScriptArgs -ScriptText $combinedScript -CommandId $CommandId
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
        $combinedMessage = Get-CoRunCommandResultMessage -TaskName "combined-task-batch" -RawJson $combinedJson -ModeLabel "auto-mode"
        Write-Host "TASK batch run-command completed."
        if (-not [string]::IsNullOrWhiteSpace($combinedMessage)) {
            Write-Host $combinedMessage
        }

        $marker = Parse-AzVmStep8Markers -MessageText $combinedMessage
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

        if ($Replacements) {
            foreach ($key in $Replacements.Keys) {
                $token = "__{0}__" -f [string]$key
                $value = [string]$Replacements[$key]
                $taskScript = $taskScript.Replace($token, $value)
            }
        }

        $assetCopies = @()
        if ($taskName -match '^\d{2}-set-private local-only accessibility-version$' -and -not [string]::IsNullOrWhiteSpace([string]$directoryPath)) {
            $versionDllPath = Join-Path $directoryPath 'version.dll'
            if (Test-Path -LiteralPath $versionDllPath) {
                $assetCopies += [pscustomobject]@{
                    LocalPath = [string](Resolve-Path -LiteralPath $versionDllPath).Path
                    RemotePath = 'C:/Windows/Temp/az-vm-private local-only accessibility-version.dll'
                }
            }
        }

        $resolvedBlocks += [pscustomobject]@{
            Name = $taskName
            Script = $taskScript
            RelativePath = $relativePath
            DirectoryPath = $directoryPath
            AssetCopies = @($assetCopies)
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



