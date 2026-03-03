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

    if ($CommandId -eq "RunPowerShellScript") {
        $scriptBytes = [System.Text.Encoding]::UTF8.GetBytes($ScriptText)
        $scriptBase64 = [System.Convert]::ToBase64String($scriptBytes)
        $wrapperTemplate = '$__b=''{0}''; $__s=[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($__b)); Invoke-Expression $__s'
        $wrapperScript = [string]::Format($wrapperTemplate, $scriptBase64)
        return @($wrapperScript)
    }

    return @($ScriptText)
}

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
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            $messages += $message.Trim()
        }

        if ($code -match '(?i)/failed$') {
            $hasError = $true
        }
        elseif ($code -match '(?i)StdErr' -and -not [string]::IsNullOrWhiteSpace($message) -and $message -match '(?i)(terminatingerror|exception|failed|not recognized|cannot find|categoryinfo)') {
            $hasError = $true
        }
    }

    if ($hasError) {
        $joinedMessages = ($messages -join " | ")
        throw "VM $ModeLabel task '$TaskName' reported error: $joinedMessages"
    }

    return ($messages -join "`n")
}

function Invoke-VmRunCommandScriptFile {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$CommandId,
        [string]$ScriptFilePath,
        [string]$ModeLabel
    )

    if ([string]::IsNullOrWhiteSpace($ScriptFilePath)) {
        throw "VM run-command script file path is empty."
    }
    if (-not (Test-Path -LiteralPath $ScriptFilePath)) {
        throw "VM run-command script file was not found: $ScriptFilePath"
    }

    try {
        $invokeLabel = "az vm run-command invoke (script-file)"
        $json = Invoke-TrackedAction -Label $invokeLabel -Action {
            $result = az vm run-command invoke `
                --resource-group $ResourceGroup `
                --name $VmName `
                --command-id $CommandId `
                --scripts "@$ScriptFilePath" `
                -o json
            Assert-LastExitCode "az vm run-command invoke (script-file)"
            $result
        }

        $message = Get-CoRunCommandResultMessage -TaskName "script-file" -RawJson $json -ModeLabel $ModeLabel
        Write-Host "TASK batch run-command completed."
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            Write-Host $message
        }
    }
    catch {
        throw "VM task batch execution failed in $ModeLabel flow: $($_.Exception.Message)"
    }
}

function Invoke-VmRunCommandBlocks {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$CommandId,
        [object[]]$TaskBlocks,
        [switch]$SubstepMode,
        [ValidateSet("bash","powershell")]
        [string]$CombinedShell = "powershell"
    )

    if (-not $TaskBlocks -or $TaskBlocks.Count -eq 0) {
        throw "VM run-command task list is empty."
    }

    if ($SubstepMode) {
        Write-Host "Substep mode is enabled: Step 8 tasks are executed one-by-one."
        foreach ($taskBlock in $TaskBlocks) {
            $taskName = [string]$taskBlock.Name
            $taskScript = Resolve-CoRunCommandScriptText -ScriptText ([string]$taskBlock.Script)
            $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                Write-Host "TASK started: $taskName"
                $taskArgs = Get-CoRunCommandScriptArgs -ScriptText $taskScript -CommandId $CommandId
                $taskAzArgs = @(
                    "vm", "run-command", "invoke",
                    "--resource-group", $ResourceGroup,
                    "--name", $VmName,
                    "--command-id", $CommandId,
                    "--scripts"
                )
                $taskAzArgs += $taskArgs
                $taskAzArgs += @("-o", "json")
                $taskInvokeLabel = "az vm run-command invoke (task: $taskName)"
                $taskJson = Invoke-TrackedAction -Label $taskInvokeLabel -Action {
                    $invokeResult = az @taskAzArgs
                    Assert-LastExitCode "az vm run-command invoke ($taskName)"
                    $invokeResult
                }
                $taskMessage = Get-CoRunCommandResultMessage -TaskName $taskName -RawJson $taskJson -ModeLabel "substep-mode"
                $taskWatch.Stop()
                Write-Host ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
                Write-Host "TASK result: success"
                if (-not [string]::IsNullOrWhiteSpace($taskMessage)) {
                    Write-Host $taskMessage
                }
            }
            catch {
                if ($taskWatch.IsRunning) { $taskWatch.Stop() }
                Write-Host "TASK result: failure ($taskName)" -ForegroundColor Red
                throw "VM task '$taskName' failed: $($_.Exception.Message)"
            }
        }
        return
    }

    Write-Host "Substep mode is not enabled: Step 8 tasks will run in a single run-command call."

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
        [void]$combinedBuilder.AppendLine('    Write-Output "TASK started: $TaskName"')
        [void]$combinedBuilder.AppendLine('    $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()')
        [void]$combinedBuilder.AppendLine('    try {')
        [void]$combinedBuilder.AppendLine('        $decodedScript = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($ScriptBase64))')
        [void]$combinedBuilder.AppendLine('        Invoke-Expression $decodedScript')
        [void]$combinedBuilder.AppendLine('        $taskWatch.Stop()')
        [void]$combinedBuilder.AppendLine('        Write-Output ("TASK completed: {0} ({1:N1}s)" -f $TaskName, $taskWatch.Elapsed.TotalSeconds)')
        [void]$combinedBuilder.AppendLine('        Write-Output "TASK result: success"')
        [void]$combinedBuilder.AppendLine('    }')
        [void]$combinedBuilder.AppendLine('    catch {')
        [void]$combinedBuilder.AppendLine('        if ($taskWatch.IsRunning) { $taskWatch.Stop() }')
        [void]$combinedBuilder.AppendLine('        Write-Output "TASK result: failure ($TaskName)"')
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
    }
    catch {
        throw "VM task batch execution failed in combined flow: $($_.Exception.Message)"
    }
}
