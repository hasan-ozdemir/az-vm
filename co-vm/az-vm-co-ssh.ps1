function Resolve-CoVmSshRetryCount {
    param(
        [string]$RetryText,
        [int]$DefaultValue = 3
    )

    $value = $DefaultValue
    if ($RetryText -match '^\d+$') {
        $value = [int]$RetryText
    }

    if ($value -lt 1) {
        $value = 1
    }
    if ($value -gt 3) {
        $value = 3
    }

    return $value
}

function Resolve-CoVmPuttyToolPath {
    param(
        [string]$ConfiguredPath,
        [string]$RepoRoot,
        [string]$ToolName
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        $candidate = [string]$ConfiguredPath
        if (-not [System.IO.Path]::IsPathRooted($candidate)) {
            $candidate = Join-Path $RepoRoot $candidate
        }
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $defaultPath = Join-Path (Join-Path $RepoRoot "tools\\pyssh") $ToolName
    if (Test-Path -LiteralPath $defaultPath) {
        return (Resolve-Path -LiteralPath $defaultPath).Path
    }

    return $defaultPath
}

function Ensure-CoVmPuttyTools {
    param(
        [string]$RepoRoot,
        [string]$ConfiguredPlinkPath = "",
        [string]$ConfiguredPscpPath = ""
    )

    $configuredClientPath = if (-not [string]::IsNullOrWhiteSpace($ConfiguredPlinkPath)) { $ConfiguredPlinkPath } else { $ConfiguredPscpPath }
    $pySshClientPath = Resolve-CoVmPuttyToolPath -ConfiguredPath $configuredClientPath -RepoRoot $RepoRoot -ToolName "ssh_client.py"
    if (Test-Path -LiteralPath $pySshClientPath) {
        return [ordered]@{
            PlinkPath = $pySshClientPath
            PscpPath = $pySshClientPath
        }
    }

    $installerPath = Join-Path $RepoRoot "tools\\install-pyssh-tools.ps1"
    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw "Python SSH tool installer script was not found: $installerPath"
    }

    Invoke-TrackedAction -Label ("powershell -File {0}" -f $installerPath) -Action {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installerPath
        Assert-LastExitCode "install-pyssh-tools.ps1"
    } | Out-Null

    if (-not (Test-Path -LiteralPath $pySshClientPath)) {
        throw "Python SSH tools could not be initialized. Missing ssh_client.py."
    }

    return [ordered]@{
        PlinkPath = $pySshClientPath
        PscpPath = $pySshClientPath
    }
}

function Invoke-CoVmProcessWithRetry {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$Label,
        [int]$MaxAttempts = 3,
        [switch]$AllowFailure
    )

    if ($MaxAttempts -lt 1) {
        $MaxAttempts = 1
    }
    if ($MaxAttempts -gt 3) {
        $MaxAttempts = 3
    }

    $lastOutput = ""
    $lastExit = 0
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $attemptLabel = if ($MaxAttempts -gt 1) { ("{0} (attempt {1}/{2})" -f $Label, $attempt, $MaxAttempts) } else { $Label }
        $output = Invoke-TrackedAction -Label $attemptLabel -Action {
            & $FilePath @Arguments 2>&1
        }
        $lastExit = [int]$LASTEXITCODE
        $lastOutput = ((@($output) | ForEach-Object { [string]$_ }) -join "`n")

        if ($lastExit -eq 0 -or $AllowFailure) {
            return [pscustomobject]@{
                ExitCode = $lastExit
                Output = $lastOutput
            }
        }

        if ($attempt -lt $MaxAttempts) {
            Write-Host ("Retrying after failure (exit {0}): {1}" -f $lastExit, $Label) -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        }
    }

    throw ("{0} failed after {1} attempt(s). Exit={2}. Output={3}" -f $Label, $MaxAttempts, $lastExit, $lastOutput)
}

function Initialize-CoVmSshHostKey {
    param(
        [string]$PlinkPath,
        [string]$HostName,
        [string]$UserName,
        [string]$Password,
        [string]$Port
    )

    $result = Invoke-CoVmProcessWithRetry `
        -FilePath "python" `
        -Arguments @(
            $PlinkPath,
            "exec",
            "--host", [string]$HostName,
            "--port", [string]$Port,
            "--user", [string]$UserName,
            "--password", [string]$Password,
            "--timeout", "30",
            "--command", "whoami"
        ) `
        -Label "pyssh connection bootstrap" `
        -MaxAttempts 1 `
        -AllowFailure

    if ($result.ExitCode -ne 0) {
        Write-Warning "Python SSH bootstrap returned non-zero exit code. Continuing and allowing retry flow."
    }

    return [pscustomobject]@{
        ExitCode = [int]$result.ExitCode
        Output = [string]$result.Output
        HostKey = "auto-add"
    }
}

function Invoke-CoVmSshRemoteCommand {
    param(
        [string]$PlinkPath,
        [string]$HostName,
        [string]$UserName,
        [string]$Password,
        [string]$Port,
        [string]$HostKey = "",
        [string]$Command,
        [string]$Label,
        [int]$MaxAttempts = 3,
        [int]$TimeoutSeconds = 1800,
        [switch]$AllowFailure
    )

    if ($TimeoutSeconds -lt 5) {
        $TimeoutSeconds = 5
    }

    $args = @(
        $PlinkPath,
        "exec",
        "--host", [string]$HostName,
        "--port", [string]$Port,
        "--user", [string]$UserName,
        "--password", [string]$Password,
        "--timeout", [string]$TimeoutSeconds,
        "--command", [string]$Command
    )

    return (Invoke-CoVmProcessWithRetry `
            -FilePath "python" `
            -Arguments $args `
            -Label $Label `
            -MaxAttempts $MaxAttempts `
            -AllowFailure:$AllowFailure)
}

function Copy-CoVmFileToVmOverSsh {
    param(
        [string]$PscpPath,
        [string]$HostName,
        [string]$UserName,
        [string]$Password,
        [string]$Port,
        [string]$HostKey = "",
        [string]$LocalPath,
        [string]$RemotePath,
        [int]$TimeoutSeconds = 180,
        [int]$MaxAttempts = 3
    )

    if ($TimeoutSeconds -lt 5) {
        $TimeoutSeconds = 5
    }

    $args = @(
        $PscpPath,
        "copy",
        "--host", [string]$HostName,
        "--port", [string]$Port,
        "--user", [string]$UserName,
        "--password", [string]$Password,
        "--timeout", [string]$TimeoutSeconds,
        "--local", [string]$LocalPath,
        "--remote", [string]$RemotePath
    )

    return (Invoke-CoVmProcessWithRetry `
            -FilePath "python" `
            -Arguments $args `
            -Label ("pyssh copy -> {0}" -f $RemotePath) `
            -MaxAttempts $MaxAttempts)
}

function Test-CoVmWindowsRebootPendingOverSsh {
    param(
        [string]$PlinkPath,
        [string]$HostName,
        [string]$UserName,
        [string]$Password,
        [string]$Port,
        [string]$HostKey = "",
        [int]$MaxAttempts = 3
    )

    $checkCmd = 'cmd /d /c "(reg query \"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending\" >nul 2>&1 || reg query \"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired\" >nul 2>&1 || reg query \"HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\" /v PendingFileRenameOperations >nul 2>&1) && echo CO_VM_REBOOT_REQUIRED:pending-registry"'
    $probe = Invoke-CoVmSshRemoteCommand `
        -PlinkPath $PlinkPath `
        -HostName $HostName `
        -UserName $UserName `
        -Password $Password `
        -Port $Port `
        -HostKey $HostKey `
        -Command $checkCmd `
        -Label "ssh reboot-pending check" `
        -TimeoutSeconds 30 `
        -MaxAttempts $MaxAttempts `
        -AllowFailure

    return ([string]$probe.Output -match '^CO_VM_REBOOT_REQUIRED:')
}

function Convert-CoVmProcessArgument {
    param(
        [string]$Value
    )

    if ($null -eq $Value) {
        return '""'
    }

    $escaped = [string]$Value
    $escaped = $escaped -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return ('"{0}"' -f $escaped)
}

function Start-CoVmPersistentSshSession {
    param(
        [string]$PySshClientPath,
        [string]$HostName,
        [string]$UserName,
        [string]$Password,
        [string]$Port,
        [ValidateSet("powershell", "bash")]
        [string]$Shell = "powershell",
        [int]$ConnectTimeoutSeconds = 30,
        [int]$DefaultTaskTimeoutSeconds = 1800
    )

    if ([string]::IsNullOrWhiteSpace($PySshClientPath) -or -not (Test-Path -LiteralPath $PySshClientPath)) {
        throw "Persistent SSH session could not start because pyssh client path is invalid."
    }
    if ($ConnectTimeoutSeconds -lt 5) { $ConnectTimeoutSeconds = 5 }
    if ($DefaultTaskTimeoutSeconds -lt 5) { $DefaultTaskTimeoutSeconds = 5 }

    $argList = @(
        [string]$PySshClientPath,
        "session",
        "--host", [string]$HostName,
        "--port", [string]$Port,
        "--user", [string]$UserName,
        "--password", [string]$Password,
        "--timeout", [string]$ConnectTimeoutSeconds,
        "--task-timeout", [string]$DefaultTaskTimeoutSeconds,
        "--shell", [string]$Shell
    )
    $argText = ($argList | ForEach-Object { Convert-CoVmProcessArgument -Value ([string]$_) }) -join ' '

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "python"
    $psi.Arguments = $argText
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psiType = $psi.GetType()
    if ($psiType.GetProperty("StandardInputEncoding")) {
        try { $psi.StandardInputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    }
    if ($psiType.GetProperty("StandardOutputEncoding")) {
        try { $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    }
    if ($psiType.GetProperty("StandardErrorEncoding")) {
        try { $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8 } catch { }
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    if (-not $proc.Start()) {
        throw "Persistent SSH python process could not be started."
    }

    return [pscustomobject]@{
        Process = $proc
        StdoutReader = $proc.StandardOutput
        StderrReader = $proc.StandardError
        PendingStdoutTask = $null
        PendingStderrTask = $null
        HostName = [string]$HostName
        UserName = [string]$UserName
        Port = [string]$Port
        Shell = [string]$Shell
        DefaultTaskTimeoutSeconds = [int]$DefaultTaskTimeoutSeconds
    }
}

function Write-CoVmPersistentSshProtocolLine {
    param(
        [psobject]$Session,
        [string]$Line
    )

    if ($null -eq $Session -or $null -eq $Session.Process) {
        throw "Persistent SSH session is not initialized."
    }
    if ($Session.Process.HasExited) {
        throw ("Persistent SSH session process has already exited (code={0})." -f $Session.Process.ExitCode)
    }

    $text = [string]$Line
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text + "`n")
    $stream = $Session.Process.StandardInput.BaseStream
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Invoke-CoVmPersistentSshTask {
    param(
        [psobject]$Session,
        [string]$TaskName,
        [string]$TaskScript,
        [int]$TimeoutSeconds = 1800
    )

    if ($null -eq $Session -or $null -eq $Session.Process) {
        throw "Persistent SSH session is not initialized."
    }
    if ($Session.Process.HasExited) {
        $stdoutTail = ""
        $stderrTail = ""
        try { $stdoutTail = [string]$Session.Process.StandardOutput.ReadToEnd() } catch { }
        try { $stderrTail = [string]$Session.Process.StandardError.ReadToEnd() } catch { }
        $detail = ""
        if (-not [string]::IsNullOrWhiteSpace($stdoutTail)) { $detail += (" stdout={0}" -f $stdoutTail.Trim()) }
        if (-not [string]::IsNullOrWhiteSpace($stderrTail)) { $detail += (" stderr={0}" -f $stderrTail.Trim()) }
        throw ("Persistent SSH session process has already exited (code={0}).{1}" -f $Session.Process.ExitCode, $detail)
    }
    if ($TimeoutSeconds -lt 5) { $TimeoutSeconds = 5 }

    $payload = [ordered]@{
        action = "run"
        task = [string]$TaskName
        timeout = [int]$TimeoutSeconds
        script = [string]$TaskScript
    } | ConvertTo-Json -Compress -Depth 20

    Write-CoVmPersistentSshProtocolLine -Session $Session -Line ([string]$payload)

    $proc = $Session.Process
    $stdoutReader = $Session.StdoutReader
    if ($null -eq $stdoutReader) {
        $stdoutReader = $proc.StandardOutput
        $Session.StdoutReader = $stdoutReader
    }
    $stderrReader = $Session.StderrReader
    if ($null -eq $stderrReader) {
        $stderrReader = $proc.StandardError
        $Session.StderrReader = $stderrReader
    }

    if ($null -eq $Session.PendingStdoutTask) {
        $Session.PendingStdoutTask = $stdoutReader.ReadLineAsync()
    }
    if ($null -eq $Session.PendingStderrTask) {
        $Session.PendingStderrTask = $stderrReader.ReadLineAsync()
    }
    $outputLines = New-Object 'System.Collections.Generic.List[string]'
    $endMarkerRegex = '^CO_VM_TASK_END:(?<task>.+?):(?<code>-?\d+)$'
    $beginMarkerRegex = '^CO_VM_TASK_BEGIN:(?<task>.+)$'
    $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $exitCode = $null

    while ($null -eq $exitCode) {
        $stdoutTask = $Session.PendingStdoutTask
        $stderrTask = $Session.PendingStderrTask
        $completedIndex = [System.Threading.Tasks.Task]::WaitAny(@($stdoutTask, $stderrTask), 250)

        if ($completedIndex -eq 0) {
            $line = $stdoutTask.Result
            $Session.PendingStdoutTask = $stdoutReader.ReadLineAsync()
            if ($null -ne $line) {
                [void]$outputLines.Add([string]$line)
                Write-Host ([string]$line)
                if (($line -as [string]) -like "CO_VM_SESSION_ERROR:*") {
                    throw ("Persistent SSH session reported protocol error for task '{0}': {1}" -f $TaskName, [string]$line)
                }
                if ($line -match $beginMarkerRegex) {
                    continue
                }
                if ($line -match $endMarkerRegex) {
                    $markerTask = [string]$Matches.task
                    if ([string]::Equals($markerTask, [string]$TaskName, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $exitCode = [int]$Matches.code
                        break
                    }
                }
            }
        }
        elseif ($completedIndex -eq 1) {
            $line = $stderrTask.Result
            $Session.PendingStderrTask = $stderrReader.ReadLineAsync()
            if ($null -ne $line) {
                [void]$outputLines.Add([string]$line)
                Write-Warning ([string]$line)
            }
        }

        if ($proc.HasExited -and $null -eq $exitCode) {
            $stdoutTail = ""
            $stderrTail = ""
            try { $stdoutTail = [string]$stdoutReader.ReadToEnd() } catch { }
            try { $stderrTail = [string]$stderrReader.ReadToEnd() } catch { }
            if (-not [string]::IsNullOrWhiteSpace($stdoutTail)) {
                foreach ($line in ($stdoutTail -split "`r?`n")) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    [void]$outputLines.Add([string]$line)
                    Write-Host ([string]$line)
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($stderrTail)) {
                foreach ($line in ($stderrTail -split "`r?`n")) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    [void]$outputLines.Add([string]$line)
                    Write-Warning ([string]$line)
                }
            }
            throw ("Persistent SSH session process exited before task completion (code={0})." -f $proc.ExitCode)
        }
        if ($taskWatch.Elapsed.TotalSeconds -gt ($TimeoutSeconds + 60)) {
            throw ("Persistent SSH task timeout guard reached for '{0}'." -f $TaskName)
        }
    }

    if ($taskWatch.IsRunning) { $taskWatch.Stop() }
    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Output = ($outputLines -join "`n")
    }
}

function Stop-CoVmPersistentSshSession {
    param(
        [psobject]$Session
    )

    if ($null -eq $Session) {
        return
    }

    $proc = $Session.Process
    if ($null -ne $proc) {
        try {
            if (-not $proc.HasExited) {
                try {
                    $closePayload = @{ action = "close" } | ConvertTo-Json -Compress
                    Write-CoVmPersistentSshProtocolLine -Session $Session -Line ([string]$closePayload)
                    $proc.StandardInput.Close()
                }
                catch { }

                if (-not $proc.WaitForExit(5000)) {
                    try { $proc.Kill() } catch { }
                    [void]$proc.WaitForExit(2000)
                }
            }
        }
        finally {
            try { $proc.Dispose() } catch { }
        }
    }
}

function Invoke-CoVmStep8OverSsh {
    param(
        [ValidateSet("windows","linux")]
        [string]$Platform,
        [switch]$SubstepMode,
        [string]$RepoRoot,
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$SshHost,
        [string]$SshUser,
        [string]$SshPassword,
        [string]$SshPort,
        [string]$ScriptFilePath,
        [object[]]$TaskBlocks,
        [switch]$RebootAfterExecution,
        [string]$PostRebootProbeScript = "",
        [string]$PostRebootProbeCommandId = "RunPowerShellScript",
        [int]$PostRebootProbeMaxAttempts = 3,
        [int]$PostRebootProbeRetryDelaySeconds = 20,
        [int]$MaxReboots = 3,
        [ValidateSet("soft-warning","strict")]
        [string]$TaskFailurePolicy = "soft-warning",
        [int]$SshMaxRetries = 3,
        [string]$ConfiguredPlinkPath = "",
        [string]$ConfiguredPscpPath = ""
    )

    if ([string]::IsNullOrWhiteSpace($SshHost)) {
        throw "Step 8 SSH mode requires a VM host/FQDN."
    }
    if ([string]::IsNullOrWhiteSpace($SshUser)) {
        throw "Step 8 SSH mode requires a VM SSH user."
    }
    if ([string]::IsNullOrWhiteSpace($SshPassword)) {
        throw "Step 8 SSH mode requires a VM SSH password."
    }
    if ([string]::IsNullOrWhiteSpace($SshPort)) {
        throw "Step 8 SSH mode requires an SSH port."
    }
    if (-not $TaskBlocks -or $TaskBlocks.Count -eq 0) {
        throw "Step 8 SSH mode requires task blocks."
    }
    if (-not $SubstepMode) {
        if ([string]::IsNullOrWhiteSpace($ScriptFilePath)) {
            throw "Step 8 SSH combined mode requires ScriptFilePath."
        }
        if (-not (Test-Path -LiteralPath $ScriptFilePath)) {
            throw "Step 8 SSH combined mode script file was not found: $ScriptFilePath"
        }
    }

    $SshMaxRetries = Resolve-CoVmSshRetryCount -RetryText ([string]$SshMaxRetries) -DefaultValue 3
    if ($MaxReboots -lt 0) { $MaxReboots = 0 }
    if ($MaxReboots -gt 3) { $MaxReboots = 3 }
    if ($PostRebootProbeMaxAttempts -lt 1) { $PostRebootProbeMaxAttempts = 1 }
    if ($PostRebootProbeMaxAttempts -gt 3) { $PostRebootProbeMaxAttempts = 3 }

    $putty = Ensure-CoVmPuttyTools `
        -RepoRoot $RepoRoot `
        -ConfiguredPlinkPath $ConfiguredPlinkPath `
        -ConfiguredPscpPath $ConfiguredPscpPath

    $hostKeyBootstrapResult = Initialize-CoVmSshHostKey `
        -PlinkPath ([string]$putty.PlinkPath) `
        -HostName $SshHost `
        -UserName $SshUser `
        -Password $SshPassword `
        -Port $SshPort
    $resolvedHostKey = ""
    if ($hostKeyBootstrapResult) {
        $resolvedHostKey = [string]$hostKeyBootstrapResult.HostKey
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedHostKey)) {
        Write-Host ("Resolved SSH host key for batch transport: {0}" -f $resolvedHostKey) -ForegroundColor DarkGray
    }

    $totalSuccess = 0
    $totalWarnings = 0
    $totalErrors = 0
    $rebootCount = 0
    $hadMidStepReboot = $false
    $tempRoot = $null
    $persistentSession = $null

    try {
        Write-Host "SSH mode is enabled for Step 8 execution." -ForegroundColor Yellow
        Write-Host ("Step 8 failure policy: {0}" -f $TaskFailurePolicy)

        if ($SubstepMode) {
            Write-Host "Substep mode is enabled: Step 8 tasks are executed one-by-one over SSH."
            if ($Platform -eq "windows") {
                Write-Host "Persistent SSH task session is enabled: one SSH connection will be reused for Step 8 substeps." -ForegroundColor DarkCyan
                $persistentSession = Start-CoVmPersistentSshSession `
                    -PySshClientPath ([string]$putty.PlinkPath) `
                    -HostName $SshHost `
                    -UserName $SshUser `
                    -Password $SshPassword `
                    -Port $SshPort `
                    -Shell "powershell" `
                    -ConnectTimeoutSeconds 30 `
                    -DefaultTaskTimeoutSeconds 1800

                for ($taskIndex = 0; $taskIndex -lt $TaskBlocks.Count; $taskIndex++) {
                    $taskBlock = $TaskBlocks[$taskIndex]
                    $taskName = [string]$taskBlock.Name
                    $taskScript = Resolve-CoRunCommandScriptText -ScriptText ([string]$taskBlock.Script)

                    Write-Host ("TASK started: {0}" -f $taskName)
                    $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()
                    $taskResult = $null
                    $taskInvocationError = $null

                    for ($taskAttempt = 1; $taskAttempt -le $SshMaxRetries; $taskAttempt++) {
                        try {
                            $taskResult = Invoke-CoVmPersistentSshTask `
                                -Session $persistentSession `
                                -TaskName $taskName `
                                -TaskScript $taskScript `
                                -TimeoutSeconds 1800
                            $taskInvocationError = $null
                            break
                        }
                        catch {
                            $taskInvocationError = $_
                            if ($taskAttempt -lt $SshMaxRetries) {
                                Write-Warning ("Persistent SSH task execution failed for '{0}' (attempt {1}/{2}): {3}" -f $taskName, $taskAttempt, $SshMaxRetries, $_.Exception.Message)
                                Stop-CoVmPersistentSshSession -Session $persistentSession
                                $persistentSession = Start-CoVmPersistentSshSession `
                                    -PySshClientPath ([string]$putty.PlinkPath) `
                                    -HostName $SshHost `
                                    -UserName $SshUser `
                                    -Password $SshPassword `
                                    -Port $SshPort `
                                    -Shell "powershell" `
                                    -ConnectTimeoutSeconds 30 `
                                    -DefaultTaskTimeoutSeconds 1800
                            }
                        }
                    }

                    if ($taskWatch.IsRunning) { $taskWatch.Stop() }

                    if ($null -ne $taskInvocationError) {
                        if ($TaskFailurePolicy -eq "soft-warning") {
                            $totalWarnings++
                            Write-Warning ("TASK warning: {0} failed in persistent session => {1}" -f $taskName, $taskInvocationError.Exception.Message)
                            Write-Host ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
                            Write-Host "TASK result: warning"
                            Write-Host ("TASK_STATUS:{0}:warning" -f $taskName)
                            try {
                                Stop-CoVmPersistentSshSession -Session $persistentSession
                            }
                            catch { }
                            $persistentSession = Start-CoVmPersistentSshSession `
                                -PySshClientPath ([string]$putty.PlinkPath) `
                                -HostName $SshHost `
                                -UserName $SshUser `
                                -Password $SshPassword `
                                -Port $SshPort `
                                -Shell "powershell" `
                                -ConnectTimeoutSeconds 30 `
                                -DefaultTaskTimeoutSeconds 1800
                            continue
                        }

                        $totalErrors++
                        Write-Host ("TASK result: failure ({0})" -f $taskName) -ForegroundColor Red
                        Write-Host ("TASK_STATUS:{0}:error" -f $taskName)
                        throw ("Step 8 SSH task failed in persistent session: {0} => {1}" -f $taskName, $taskInvocationError.Exception.Message)
                    }

                    if ([int]$taskResult.ExitCode -eq 0) {
                        $totalSuccess++
                        Write-Host ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
                        Write-Host "TASK result: success"
                        Write-Host ("TASK_STATUS:{0}:success" -f $taskName)
                    }
                    else {
                        if ($TaskFailurePolicy -eq "soft-warning") {
                            $totalWarnings++
                            Write-Warning ("TASK warning: {0} exited with code {1}" -f $taskName, $taskResult.ExitCode)
                            Write-Host ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
                            Write-Host "TASK result: warning"
                            Write-Host ("TASK_STATUS:{0}:warning" -f $taskName)
                        }
                        else {
                            $totalErrors++
                            Write-Host ("TASK result: failure ({0})" -f $taskName) -ForegroundColor Red
                            Write-Host ("TASK_STATUS:{0}:error" -f $taskName)
                            throw ("Step 8 SSH task failed: {0} (exit {1})" -f $taskName, $taskResult.ExitCode)
                        }
                    }

                    $rebootRequired = Test-CoVmOutputIndicatesRebootRequired -MessageText ([string]$taskResult.Output)
                    if (-not $rebootRequired) {
                        $rebootRequired = Test-CoVmWindowsRebootPendingOverSsh `
                            -PlinkPath ([string]$putty.PlinkPath) `
                            -HostName $SshHost `
                            -UserName $SshUser `
                            -Password $SshPassword `
                            -Port $SshPort `
                            -HostKey $resolvedHostKey `
                            -MaxAttempts $SshMaxRetries
                    }

                    if ($rebootRequired) {
                        if ($rebootCount -ge $MaxReboots) {
                            throw ("Step 8 SSH reboot-resume cannot continue because reboot limit ({0}) was reached." -f $MaxReboots)
                        }

                        $rebootCount++
                        $hadMidStepReboot = $true
                        Write-Host ("CO_VM_REBOOT_REQUIRED:task={0};index={1};rebootCount={2}" -f $taskName, $taskIndex, $rebootCount)
                        Write-Host ("Step 8 SSH flow requested a VM reboot ({0}/{1}). Resuming..." -f $rebootCount, $MaxReboots) -ForegroundColor Yellow

                        Stop-CoVmPersistentSshSession -Session $persistentSession
                        $persistentSession = $null

                        Invoke-CoVmPostStep8RebootAndProbe `
                            -ResourceGroup $ResourceGroup `
                            -VmName $VmName `
                            -PostRebootProbeScript $PostRebootProbeScript `
                            -PostRebootProbeCommandId $PostRebootProbeCommandId `
                            -PostRebootProbeMaxAttempts $PostRebootProbeMaxAttempts `
                            -PostRebootProbeRetryDelaySeconds $PostRebootProbeRetryDelaySeconds

                        $persistentSession = Start-CoVmPersistentSshSession `
                            -PySshClientPath ([string]$putty.PlinkPath) `
                            -HostName $SshHost `
                            -UserName $SshUser `
                            -Password $SshPassword `
                            -Port $SshPort `
                            -Shell "powershell" `
                            -ConnectTimeoutSeconds 30 `
                            -DefaultTaskTimeoutSeconds 1800
                    }
                }
            }
            else {
                $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("az-vm-step8-ssh-" + [guid]::NewGuid().ToString("N"))
                New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

                for ($taskIndex = 0; $taskIndex -lt $TaskBlocks.Count; $taskIndex++) {
                    $taskBlock = $TaskBlocks[$taskIndex]
                    $taskName = [string]$taskBlock.Name
                    $taskScript = Resolve-CoRunCommandScriptText -ScriptText ([string]$taskBlock.Script)
                    $localTaskName = ("task-{0:D2}.sh" -f ($taskIndex + 1))
                    $localTaskPath = Join-Path $tempRoot $localTaskName
                    $writeSettings = Get-CoVmWriteSettingsForPlatform -Platform $Platform
                    Write-TextFileNormalized `
                        -Path $localTaskPath `
                        -Content $taskScript `
                        -Encoding $writeSettings.Encoding `
                        -LineEnding $writeSettings.LineEnding `
                        -EnsureTrailingNewline

                    $remoteTaskPath = ("./{0}" -f $localTaskName)
                    Copy-CoVmFileToVmOverSsh `
                        -PscpPath ([string]$putty.PscpPath) `
                        -HostName $SshHost `
                        -UserName $SshUser `
                        -Password $SshPassword `
                        -Port $SshPort `
                        -HostKey $resolvedHostKey `
                        -LocalPath $localTaskPath `
                        -RemotePath $remoteTaskPath `
                        -MaxAttempts $SshMaxRetries | Out-Null

                    $remoteCommand = ('bash "{0}"' -f $remoteTaskPath)
                    Write-Host ("TASK started: {0}" -f $taskName)
                    $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()
                    $taskResult = Invoke-CoVmSshRemoteCommand `
                        -PlinkPath ([string]$putty.PlinkPath) `
                        -HostName $SshHost `
                        -UserName $SshUser `
                        -Password $SshPassword `
                        -Port $SshPort `
                        -HostKey $resolvedHostKey `
                        -Command $remoteCommand `
                        -Label ("ssh task: {0}" -f $taskName) `
                        -MaxAttempts $SshMaxRetries `
                        -AllowFailure
                    if ($taskWatch.IsRunning) { $taskWatch.Stop() }

                    if (-not [string]::IsNullOrWhiteSpace([string]$taskResult.Output)) {
                        Write-Host ([string]$taskResult.Output)
                    }

                    if ([int]$taskResult.ExitCode -eq 0) {
                        $totalSuccess++
                        Write-Host ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
                        Write-Host "TASK result: success"
                        Write-Host ("TASK_STATUS:{0}:success" -f $taskName)
                    }
                    else {
                        if ($TaskFailurePolicy -eq "soft-warning") {
                            $totalWarnings++
                            Write-Warning ("TASK warning: {0} exited with code {1}" -f $taskName, $taskResult.ExitCode)
                            Write-Host ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
                            Write-Host "TASK result: warning"
                            Write-Host ("TASK_STATUS:{0}:warning" -f $taskName)
                        }
                        else {
                            $totalErrors++
                            Write-Host ("TASK result: failure ({0})" -f $taskName) -ForegroundColor Red
                            Write-Host ("TASK_STATUS:{0}:error" -f $taskName)
                            throw ("Step 8 SSH task failed: {0} (exit {1})" -f $taskName, $taskResult.ExitCode)
                        }
                    }

                    $rebootRequired = Test-CoVmOutputIndicatesRebootRequired -MessageText ([string]$taskResult.Output)
                    if ($rebootRequired) {
                        if ($rebootCount -ge $MaxReboots) {
                            throw ("Step 8 SSH reboot-resume cannot continue because reboot limit ({0}) was reached." -f $MaxReboots)
                        }

                        $rebootCount++
                        $hadMidStepReboot = $true
                        Write-Host ("CO_VM_REBOOT_REQUIRED:task={0};index={1};rebootCount={2}" -f $taskName, $taskIndex, $rebootCount)
                        Write-Host ("Step 8 SSH flow requested a VM reboot ({0}/{1}). Resuming..." -f $rebootCount, $MaxReboots) -ForegroundColor Yellow
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
        }
        else {
            Write-Host ("Substep mode is not enabled: Step 8 tasks will run from the VM update script file over SSH. Failure policy: {0}" -f $TaskFailurePolicy)
            $scriptLeaf = [System.IO.Path]::GetFileName([string]$ScriptFilePath)
            if ([string]::IsNullOrWhiteSpace($scriptLeaf)) {
                $scriptLeaf = if ($Platform -eq "windows") { "az-vm-step8-update.ps1" } else { "az-vm-step8-update.sh" }
            }
            $remoteScriptPath = ("./{0}" -f $scriptLeaf)

            while ($true) {
                Copy-CoVmFileToVmOverSsh `
                    -PscpPath ([string]$putty.PscpPath) `
                    -HostName $SshHost `
                    -UserName $SshUser `
                    -Password $SshPassword `
                    -Port $SshPort `
                    -HostKey $resolvedHostKey `
                    -LocalPath $ScriptFilePath `
                    -RemotePath $remoteScriptPath `
                    -MaxAttempts $SshMaxRetries | Out-Null

                if ($Platform -eq "linux") {
                    Invoke-CoVmSshRemoteCommand `
                        -PlinkPath ([string]$putty.PlinkPath) `
                        -HostName $SshHost `
                        -UserName $SshUser `
                        -Password $SshPassword `
                        -Port $SshPort `
                        -HostKey $resolvedHostKey `
                        -Command ('chmod +x "{0}"' -f $remoteScriptPath) `
                        -Label "ssh chmod update script" `
                        -MaxAttempts $SshMaxRetries | Out-Null
                }

                $combinedRemoteCommand = if ($Platform -eq "windows") {
                    ('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $remoteScriptPath)
                }
                else {
                    ('bash "{0}"' -f $remoteScriptPath)
                }

                $combinedResult = Invoke-CoVmSshRemoteCommand `
                    -PlinkPath ([string]$putty.PlinkPath) `
                    -HostName $SshHost `
                    -UserName $SshUser `
                    -Password $SshPassword `
                    -Port $SshPort `
                    -HostKey $resolvedHostKey `
                    -Command $combinedRemoteCommand `
                    -Label "ssh step8 update-script-file" `
                    -MaxAttempts $SshMaxRetries `
                    -AllowFailure

                if (-not [string]::IsNullOrWhiteSpace([string]$combinedResult.Output)) {
                    Write-Host ([string]$combinedResult.Output)
                }

                $marker = Parse-CoVmStep8Markers -MessageText ([string]$combinedResult.Output)
                if ($marker.HasSummaryLine) {
                    $totalSuccess = [int]$marker.SuccessCount
                    $totalWarnings = [int]$marker.WarningCount
                    $totalErrors = [int]$marker.ErrorCount
                    Write-Host $marker.SummaryLine -ForegroundColor DarkGray
                }
                elseif ([int]$combinedResult.ExitCode -eq 0) {
                    $totalSuccess = [int]@($TaskBlocks).Count
                }
                elseif ($TaskFailurePolicy -eq "soft-warning") {
                    $totalWarnings = [Math]::Max($totalWarnings, 1)
                }
                else {
                    $totalErrors = [Math]::Max($totalErrors, 1)
                }

                if ([int]$combinedResult.ExitCode -ne 0) {
                    if ($TaskFailurePolicy -eq "soft-warning") {
                        Write-Warning ("Step 8 SSH combined flow exited with code {0}; continuing due soft-warning policy." -f $combinedResult.ExitCode)
                    }
                    else {
                        throw ("Step 8 SSH combined flow failed with exit code {0}." -f $combinedResult.ExitCode)
                    }
                }

                $rebootRequired = ([bool]$marker.RebootRequired -or (Test-CoVmOutputIndicatesRebootRequired -MessageText ([string]$combinedResult.Output)))
                if (-not $rebootRequired -and $Platform -eq "windows") {
                    $rebootRequired = Test-CoVmWindowsRebootPendingOverSsh `
                        -PlinkPath ([string]$putty.PlinkPath) `
                        -HostName $SshHost `
                        -UserName $SshUser `
                        -Password $SshPassword `
                        -Port $SshPort `
                        -HostKey $resolvedHostKey `
                        -MaxAttempts $SshMaxRetries
                }

                if (-not $rebootRequired) {
                    break
                }

                if ($rebootCount -ge $MaxReboots) {
                    throw ("Step 8 SSH reboot-resume cannot continue because reboot limit ({0}) was reached." -f $MaxReboots)
                }

                $rebootCount++
                $hadMidStepReboot = $true
                Write-Host ("Step 8 SSH combined flow requested a VM reboot ({0}/{1}). Resuming..." -f $rebootCount, $MaxReboots) -ForegroundColor Yellow
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
                Write-Host "Step 8 already rebooted during SSH task execution; final reboot is skipped." -ForegroundColor DarkGray
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
    finally {
        if ($null -ne $persistentSession) {
            Stop-CoVmPersistentSshSession -Session $persistentSession
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$tempRoot) -and (Test-Path -LiteralPath $tempRoot)) {
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
