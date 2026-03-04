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

function Parse-CoVmStep8Markers {
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

        if ($trimmed -match '^CO_VM_REBOOT_REQUIRED:') {
            $result.RebootRequired = $true
            continue
        }
    }

    return [pscustomobject]$result
}

function Test-CoVmOutputIndicatesRebootRequired {
    param(
        [string]$MessageText
    )

    if ([string]::IsNullOrWhiteSpace($MessageText)) {
        return $false
    }

    if ($MessageText -match '^CO_VM_REBOOT_REQUIRED:' -or $MessageText -match '(?im)^TASK_REBOOT_REQUIRED:') {
        return $true
    }

    return ($MessageText -match '(?i)(reboot required|restart required|pending reboot|press any key to install windows subsystem for linux)')
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

        $marker = Parse-CoVmStep8Markers -MessageText $message
        if ($marker.HasSummaryLine) {
            Write-Host $marker.SummaryLine -ForegroundColor DarkGray
        }

        return [pscustomobject]@{
            Message = $message
            RebootRequired = ([bool]$marker.RebootRequired -or (Test-CoVmOutputIndicatesRebootRequired -MessageText $message))
            SuccessCount = [int]$marker.SuccessCount
            WarningCount = [int]$marker.WarningCount
            ErrorCount = [int]$marker.ErrorCount
            RebootCount = [int]$marker.RebootCount
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
        [int]$StartTaskIndex = 0,
        [switch]$SoftFail,
        [ValidateSet("bash","powershell")]
        [string]$CombinedShell = "powershell"
    )

    if (-not $TaskBlocks -or $TaskBlocks.Count -eq 0) {
        throw "VM run-command task list is empty."
    }
    if ($StartTaskIndex -lt 0) {
        $StartTaskIndex = 0
    }
    if ($StartTaskIndex -ge $TaskBlocks.Count) {
        return [pscustomobject]@{
            SuccessCount = 0
            WarningCount = 0
            ErrorCount = 0
            RebootRequired = $false
            NextTaskIndex = [int]$TaskBlocks.Count
        }
    }

    if ($SubstepMode) {
        Write-Host "Substep mode is enabled: Step 8 tasks are executed one-by-one."
        $successCount = 0
        $warningCount = 0
        $errorCount = 0
        $nextTaskIndex = [int]$StartTaskIndex
        for ($taskIndex = $StartTaskIndex; $taskIndex -lt $TaskBlocks.Count; $taskIndex++) {
            $taskBlock = $TaskBlocks[$taskIndex]
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
                $successCount++
                $nextTaskIndex = $taskIndex + 1
                if (Test-CoVmOutputIndicatesRebootRequired -MessageText $taskMessage) {
                    return [pscustomobject]@{
                        SuccessCount = $successCount
                        WarningCount = $warningCount
                        ErrorCount = $errorCount
                        RebootRequired = $true
                        NextTaskIndex = $nextTaskIndex
                    }
                }
            }
            catch {
                if ($taskWatch.IsRunning) { $taskWatch.Stop() }
                if ($SoftFail) {
                    $warningCount++
                    $nextTaskIndex = $taskIndex + 1
                    Write-Warning ("TASK warning: {0} => {1}" -f $taskName, $_.Exception.Message)
                    continue
                }

                Write-Host "TASK result: failure ($taskName)" -ForegroundColor Red
                throw "VM task '$taskName' failed: $($_.Exception.Message)"
            }
        }

        return [pscustomobject]@{
            SuccessCount = $successCount
            WarningCount = $warningCount
            ErrorCount = $errorCount
            RebootRequired = $false
            NextTaskIndex = $nextTaskIndex
        }
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

        $marker = Parse-CoVmStep8Markers -MessageText $combinedMessage
        return [pscustomobject]@{
            SuccessCount = [int]$marker.SuccessCount
            WarningCount = [int]$marker.WarningCount
            ErrorCount = [int]$marker.ErrorCount
            RebootRequired = ([bool]$marker.RebootRequired -or (Test-CoVmOutputIndicatesRebootRequired -MessageText $combinedMessage))
            NextTaskIndex = [int]$TaskBlocks.Count
        }
    }
    catch {
        throw "VM task batch execution failed in combined flow: $($_.Exception.Message)"
    }
}

function Apply-CoVmTaskBlockReplacements {
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

        if ($Replacements) {
            foreach ($key in $Replacements.Keys) {
                $token = "__{0}__" -f [string]$key
                $value = [string]$Replacements[$key]
                $taskScript = $taskScript.Replace($token, $value)
            }
        }

        $resolvedBlocks += [pscustomobject]@{
            Name = $taskName
            Script = $taskScript
        }
    }

    Write-Output -NoEnumerate $resolvedBlocks
}

function Wait-CoVmVmRunningState {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [int]$MaxAttempts = 60,
        [int]$DelaySeconds = 10
    )

    if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
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

function Invoke-CoVmPostStep8RebootAndProbe {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$PostRebootProbeScript = "",
        [string]$PostRebootProbeCommandId = "RunPowerShellScript",
        [int]$PostRebootProbeMaxAttempts = 3,
        [int]$PostRebootProbeRetryDelaySeconds = 20
    )

    Invoke-TrackedAction -Label ("az vm restart -g {0} -n {1}" -f $ResourceGroup, $VmName) -Action {
        az vm restart -g $ResourceGroup -n $VmName --no-wait
        Assert-LastExitCode "az vm restart --no-wait"
    } | Out-Null

    Write-Host "Waiting for VM restart completion..."
    Invoke-TrackedAction -Label ("az vm wait -g {0} -n {1} --updated" -f $ResourceGroup, $VmName) -Action {
        az vm wait -g $ResourceGroup -n $VmName --updated
        Assert-LastExitCode "az vm wait --updated"
    } | Out-Null

    Write-Host "Checking VM power state after reboot..."
    $isRunning = Wait-CoVmVmRunningState -ResourceGroup $ResourceGroup -VmName $VmName -MaxAttempts 90 -DelaySeconds 10
    if (-not $isRunning) {
        throw "VM did not reach 'VM running' state after reboot in Step 8."
    }

    if ([string]::IsNullOrWhiteSpace($PostRebootProbeScript)) {
        return
    }

    if ($PostRebootProbeMaxAttempts -lt 1) { $PostRebootProbeMaxAttempts = 1 }
    if ($PostRebootProbeMaxAttempts -gt 3) { $PostRebootProbeMaxAttempts = 3 }
    if ($PostRebootProbeRetryDelaySeconds -lt 1) { $PostRebootProbeRetryDelaySeconds = 1 }

    for ($attempt = 1; $attempt -le $PostRebootProbeMaxAttempts; $attempt++) {
        try {
            $probeArgs = Get-CoRunCommandScriptArgs -ScriptText $PostRebootProbeScript -CommandId $PostRebootProbeCommandId
            $probeAzArgs = @(
                "vm", "run-command", "invoke",
                "--resource-group", $ResourceGroup,
                "--name", $VmName,
                "--command-id", $PostRebootProbeCommandId,
                "--scripts"
            )
            $probeAzArgs += $probeArgs
            $probeAzArgs += @("-o", "json")

            $label = "az vm run-command invoke (post-reboot probe attempt $attempt)"
            $probeJson = Invoke-TrackedAction -Label $label -Action {
                $probeResult = az @probeAzArgs
                Assert-LastExitCode "az vm run-command invoke (post-reboot probe)"
                $probeResult
            }

            $probeMessage = Get-CoRunCommandResultMessage -TaskName "post-reboot-probe" -RawJson $probeJson -ModeLabel "post-reboot-probe"
            Write-Host "Post-reboot probe completed."
            if (-not [string]::IsNullOrWhiteSpace($probeMessage)) {
                Write-Host $probeMessage
            }
            return
        }
        catch {
            if ($attempt -ge $PostRebootProbeMaxAttempts) {
                Write-Warning ("Post-reboot probe failed after {0} attempt(s): {1}" -f $attempt, $_.Exception.Message)
                return
            }

            Write-Host ("Post-reboot probe attempt {0} failed: {1}" -f $attempt, $_.Exception.Message) -ForegroundColor Yellow
            Start-Sleep -Seconds $PostRebootProbeRetryDelaySeconds
        }
    }
}

function Invoke-CoVmStep8RunCommand {
    param(
        [switch]$SubstepMode,
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$CommandId,
        [string]$ScriptFilePath,
        [object[]]$TaskBlocks,
        [ValidateSet("bash","powershell")]
        [string]$CombinedShell,
        [switch]$RebootAfterExecution,
        [string]$PostRebootProbeScript = "",
        [string]$PostRebootProbeCommandId = "RunPowerShellScript",
        [int]$PostRebootProbeMaxAttempts = 3,
        [int]$PostRebootProbeRetryDelaySeconds = 20,
        [int]$MaxReboots = 3,
        [ValidateSet("soft-warning","strict")]
        [string]$TaskFailurePolicy = "soft-warning"
    )

    if ($MaxReboots -lt 0) {
        $MaxReboots = 0
    }
    if ($MaxReboots -gt 3) {
        $MaxReboots = 3
    }

    $totalSuccess = 0
    $totalWarnings = 0
    $totalErrors = 0
    $rebootCount = 0
    $hadMidStepReboot = $false

    if (-not $SubstepMode) {
        Write-Host ("Substep mode is not enabled: Step 8 tasks will run from the VM update script file. Failure policy: {0}" -f $TaskFailurePolicy)
        while ($true) {
            $scriptFileResult = Invoke-VmRunCommandScriptFile `
                -ResourceGroup $ResourceGroup `
                -VmName $VmName `
                -CommandId $CommandId `
                -ScriptFilePath $ScriptFilePath `
                -ModeLabel "auto-mode update-script-file"

            $totalSuccess = [int]$scriptFileResult.SuccessCount
            $totalWarnings = [int]$scriptFileResult.WarningCount
            $totalErrors = [int]$scriptFileResult.ErrorCount

            if (-not $scriptFileResult.RebootRequired) {
                break
            }

            if ($rebootCount -ge $MaxReboots) {
                throw ("Step 8 reboot-resume cannot continue because reboot limit ({0}) was reached." -f $MaxReboots)
            }

            $rebootCount++
            $hadMidStepReboot = $true
            Write-Host ("Step 8 requested a VM reboot ({0}/{1}). Resuming after reboot..." -f $rebootCount, $MaxReboots) -ForegroundColor Yellow
            Invoke-CoVmPostStep8RebootAndProbe `
                -ResourceGroup $ResourceGroup `
                -VmName $VmName `
                -PostRebootProbeScript $PostRebootProbeScript `
                -PostRebootProbeCommandId $PostRebootProbeCommandId `
                -PostRebootProbeMaxAttempts $PostRebootProbeMaxAttempts `
                -PostRebootProbeRetryDelaySeconds $PostRebootProbeRetryDelaySeconds
        }
    }
    else {
        Write-Host ("Substep mode is enabled: Step 8 will execute tasks one-by-one. Failure policy: {0}" -f $TaskFailurePolicy)
        $nextTaskIndex = 0
        while ($nextTaskIndex -lt $TaskBlocks.Count) {
            $blockResult = Invoke-VmRunCommandBlocks `
                -ResourceGroup $ResourceGroup `
                -VmName $VmName `
                -CommandId $CommandId `
                -TaskBlocks $TaskBlocks `
                -SubstepMode:$true `
                -StartTaskIndex $nextTaskIndex `
                -SoftFail:($TaskFailurePolicy -eq "soft-warning") `
                -CombinedShell $CombinedShell

            $totalSuccess += [int]$blockResult.SuccessCount
            $totalWarnings += [int]$blockResult.WarningCount
            $totalErrors += [int]$blockResult.ErrorCount
            $nextTaskIndex = [int]$blockResult.NextTaskIndex

            if (-not $blockResult.RebootRequired) {
                break
            }

            if ($rebootCount -ge $MaxReboots) {
                throw ("Step 8 reboot-resume cannot continue because reboot limit ({0}) was reached." -f $MaxReboots)
            }

            $rebootCount++
            $hadMidStepReboot = $true
            Write-Host ("Step 8 task flow requested a VM reboot ({0}/{1}). Resuming from task index {2}..." -f $rebootCount, $MaxReboots, $nextTaskIndex) -ForegroundColor Yellow
            Invoke-CoVmPostStep8RebootAndProbe `
                -ResourceGroup $ResourceGroup `
                -VmName $VmName `
                -PostRebootProbeScript $PostRebootProbeScript `
                -PostRebootProbeCommandId $PostRebootProbeCommandId `
                -PostRebootProbeMaxAttempts $PostRebootProbeMaxAttempts `
                -PostRebootProbeRetryDelaySeconds $PostRebootProbeRetryDelaySeconds
        }
    }

    Write-Host ("STEP8_SUMMARY:success={0};warning={1};error={2};reboot={3}" -f $totalSuccess, $totalWarnings, $totalErrors, $rebootCount)

    if ($TaskFailurePolicy -eq "strict" -and ($totalWarnings -gt 0 -or $totalErrors -gt 0)) {
        throw ("Step 8 strict failure policy blocked continuation: warning={0}, error={1}" -f $totalWarnings, $totalErrors)
    }

    if ($RebootAfterExecution) {
        if ($hadMidStepReboot) {
            Write-Host "Step 8 already rebooted during task execution; final reboot is skipped." -ForegroundColor DarkGray
        }
        else {
            Invoke-CoVmPostStep8RebootAndProbe `
                -ResourceGroup $ResourceGroup `
                -VmName $VmName `
                -PostRebootProbeScript $PostRebootProbeScript `
                -PostRebootProbeCommandId $PostRebootProbeCommandId `
                -PostRebootProbeMaxAttempts $PostRebootProbeMaxAttempts `
                -PostRebootProbeRetryDelaySeconds $PostRebootProbeRetryDelaySeconds
        }
    }
}
