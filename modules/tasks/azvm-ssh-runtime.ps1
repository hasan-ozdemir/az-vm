# Imported runtime region: test-ssh.

# Handles Resolve-AzVmSshRetryCount.
function Resolve-AzVmSshRetryCount {
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

# Handles Resolve-AzVmPySshToolPath.
function Resolve-AzVmPySshToolPath {
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

# Handles Ensure-AzVmPySshTools.
function Ensure-AzVmPySshTools {
    param(
        [string]$RepoRoot,
        [string]$ConfiguredPySshClientPath = ""
    )

    $configuredClientPath = [string]$ConfiguredPySshClientPath
    $pySshClientPath = Resolve-AzVmPySshToolPath -ConfiguredPath $configuredClientPath -RepoRoot $RepoRoot -ToolName "ssh_client.py"
    $pySshVenvRoot = Join-Path (Join-Path $RepoRoot "tools\pyssh") ".venv"
    $isWindowsPlatform = ([System.IO.Path]::DirectorySeparatorChar -eq '\')
    $pySshPythonPath = if ($isWindowsPlatform) {
        Join-Path $pySshVenvRoot "Scripts\python.exe"
    }
    else {
        Join-Path $pySshVenvRoot "bin/python"
    }

    if ((Test-Path -LiteralPath $pySshClientPath) -and (Test-Path -LiteralPath $pySshPythonPath)) {
        return [ordered]@{
            ClientPath = $pySshClientPath
            PythonPath = (Resolve-Path -LiteralPath $pySshPythonPath).Path
        }
    }

    $installerPath = Join-Path $RepoRoot "tools\\install-pyssh-tool.ps1"
    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw "Python SSH tool installer script was not found: $installerPath"
    }

    Invoke-TrackedAction -Label ("powershell -File {0}" -f $installerPath) -Action {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installerPath
        Assert-LastExitCode "install-pyssh-tool.ps1"
    } | Out-Null

    if (-not (Test-Path -LiteralPath $pySshClientPath)) {
        throw "Python SSH tools could not be initialized. Missing ssh_client.py."
    }
    if (-not (Test-Path -LiteralPath $pySshPythonPath)) {
        throw "Python SSH tools could not be initialized. Missing pyssh venv python executable."
    }

    return [ordered]@{
        ClientPath = $pySshClientPath
        PythonPath = (Resolve-Path -LiteralPath $pySshPythonPath).Path
    }
}

# Handles Copy-AzVmAssetToVm.
function Copy-AzVmAssetToVm {
    param(
        [string]$PySshPythonPath,
        [string]$PySshClientPath,
        [string]$HostName,
        [string]$UserName,
        [string]$Password,
        [string]$Port,
        [string]$LocalPath,
        [string]$RemotePath,
        [int]$ConnectTimeoutSeconds = 30
    )

    if ([string]::IsNullOrWhiteSpace([string]$LocalPath) -or -not (Test-Path -LiteralPath $LocalPath)) {
        throw ("Task asset was not found: {0}" -f $LocalPath)
    }
    if ([string]::IsNullOrWhiteSpace([string]$RemotePath)) {
        throw "Task asset remote path is empty."
    }
    if ($ConnectTimeoutSeconds -lt 5) { $ConnectTimeoutSeconds = 5 }
    if ($ConnectTimeoutSeconds -gt 300) { $ConnectTimeoutSeconds = 300 }

    $copyArgs = @(
        [string]$PySshClientPath,
        "copy",
        "--host", [string]$HostName,
        "--port", [string]$Port,
        "--user", [string]$UserName,
        "--password", [string]$Password,
        "--timeout", [string]$ConnectTimeoutSeconds,
        "--local", [string]$LocalPath,
        "--remote", [string]$RemotePath
    )

    Invoke-AzVmProcessWithRetry -FilePath $PySshPythonPath -Arguments $copyArgs -Label ("pyssh copy asset -> {0}" -f [string]$RemotePath) -MaxAttempts 1 | Out-Null
}

# Handles Wait-AzVmVmPowerState.
function Wait-AzVmVmPowerState {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$DesiredPowerState = "VM running",
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 10
    )

    if ([string]::IsNullOrWhiteSpace($DesiredPowerState)) {
        $DesiredPowerState = "VM running"
    }
    if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
    if ($MaxAttempts -gt 120) { $MaxAttempts = 120 }
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
            if ([string]::Equals([string]$powerState, [string]$DesiredPowerState, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }

        Start-Sleep -Seconds $DelaySeconds
    }

    return $false
}

# Handles Invoke-AzVmProcessWithRetry.
function Invoke-AzVmProcessWithRetry {
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
        $previousDontWriteBytecode = [System.Environment]::GetEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "Process")
        try {
            [System.Environment]::SetEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1", "Process")
            $output = Invoke-TrackedAction -Label $attemptLabel -Action {
                & $FilePath -B @Arguments 2>&1
            }
        }
        finally {
            [System.Environment]::SetEnvironmentVariable("PYTHONDONTWRITEBYTECODE", $previousDontWriteBytecode, "Process")
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

# Handles Initialize-AzVmSshHostKey.
function Initialize-AzVmSshHostKey {
    param(
        [string]$PySshPythonPath,
        [string]$PySshClientPath,
        [string]$HostName,
        [string]$UserName,
        [string]$Password,
        [string]$Port,
        [int]$ConnectTimeoutSeconds = 30
    )

    if ($ConnectTimeoutSeconds -lt 5) { $ConnectTimeoutSeconds = 5 }
    if ($ConnectTimeoutSeconds -gt 300) { $ConnectTimeoutSeconds = 300 }
    if ([string]::IsNullOrWhiteSpace([string]$PySshPythonPath) -or -not (Test-Path -LiteralPath $PySshPythonPath)) {
        throw "Python executable for pyssh was not found."
    }

    $result = Invoke-AzVmProcessWithRetry `
        -FilePath $PySshPythonPath `
        -Arguments @(
            $PySshClientPath,
            "exec",
            "--host", [string]$HostName,
            "--port", [string]$Port,
            "--user", [string]$UserName,
            "--password", [string]$Password,
            "--timeout", [string]$ConnectTimeoutSeconds,
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







# Handles Convert-AzVmProcessArgument.
function Convert-AzVmProcessArgument {
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

# Handles Start-AzVmPersistentSshSession.
function Start-AzVmPersistentSshSession {
    param(
        [string]$PySshPythonPath,
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
    if ([string]::IsNullOrWhiteSpace([string]$PySshPythonPath) -or -not (Test-Path -LiteralPath $PySshPythonPath)) {
        throw "Persistent SSH session could not start because pyssh python executable is invalid."
    }
    if ($ConnectTimeoutSeconds -lt 5) { $ConnectTimeoutSeconds = 5 }
    if ($DefaultTaskTimeoutSeconds -lt 5) { $DefaultTaskTimeoutSeconds = 5 }

    $argList = @(
        "-B",
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
    $argText = ($argList | ForEach-Object { Convert-AzVmProcessArgument -Value ([string]$_) }) -join ' '

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = [string]$PySshPythonPath
    $psi.Arguments = $argText
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $null = $psi.EnvironmentVariables
    $psi.EnvironmentVariables["PYTHONDONTWRITEBYTECODE"] = "1"
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
        TransientConsoleActive = $false
        HostName = [string]$HostName
        UserName = [string]$UserName
        Port = [string]$Port
        Shell = [string]$Shell
        DefaultTaskTimeoutSeconds = [int]$DefaultTaskTimeoutSeconds
    }
}

# Handles Write-AzVmPersistentSshProtocolLine.
function Write-AzVmPersistentSshProtocolLine {
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

# Handles Normalize-AzVmProtocolLine.
function Normalize-AzVmProtocolLine {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        return $null
    }

    $value = [string]$Text
    $value = $value.Replace("`0", "")
    $value = $value.TrimStart([char]0xFEFF)
    $value = $value.TrimEnd("`r", "`n")
    return $value
}

# Handles Test-AzVmTransientSpinnerLine.
function Test-AzVmTransientSpinnerLine {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        return $false
    }

    $value = [string]$Text
    if ($value.StartsWith("[stderr] ", [System.StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring(9)
    }

    $value = $value.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }

    return [regex]::IsMatch($value, '^[\|/\\-]{1,16}$')
}

# Handles Write-AzVmTransientConsoleText.
function Write-AzVmTransientConsoleText {
    param(
        [AllowNull()]
        [string]$Text
    )

    $value = if ($null -eq $Text) { "" } else { [string]$Text }
    [Console]::Write(("`r{0}" -f $value))
}

# Handles Clear-AzVmTransientConsoleText.
function Clear-AzVmTransientConsoleText {
    [Console]::WriteLine("")
}

# Handles Test-AzVmTaskOutputNoiseLine.
function Test-AzVmTaskOutputNoiseLine {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        return $false
    }

    $value = [string]$Text
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }

    return (
        $value.StartsWith("AZ_VM_TASK_BEGIN:", [System.StringComparison]::OrdinalIgnoreCase) -or
        $value.StartsWith("AZ_VM_TASK_END:", [System.StringComparison]::OrdinalIgnoreCase) -or
        $value.StartsWith("Update task started:", [System.StringComparison]::OrdinalIgnoreCase) -or
        $value.StartsWith("Update task completed:", [System.StringComparison]::OrdinalIgnoreCase)
    )
}

# Handles Invoke-AzVmPersistentSshTask.
function Invoke-AzVmPersistentSshTask {
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

    Write-AzVmPersistentSshProtocolLine -Session $Session -Line ([string]$payload)

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
    $endMarkerRegex = '^AZ_VM_TASK_END:(?<task>.+?):(?<code>-?\d+)$'
    $beginMarkerRegex = '^AZ_VM_TASK_BEGIN:(?<task>.+)$'
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
                $lineText = [string]$line
                $normalizedLine = Normalize-AzVmProtocolLine -Text $lineText
                if ($null -eq $normalizedLine) { $normalizedLine = "" }
                if (($normalizedLine -as [string]) -like "AZ_VM_SESSION_ERROR:*") {
                    throw ("Persistent SSH session reported protocol error for task '{0}': {1}" -f $TaskName, [string]$normalizedLine)
                }
                if ($normalizedLine -match $endMarkerRegex) {
                    $markerTask = [string]$Matches.task
                    if ([string]::Equals($markerTask, [string]$TaskName, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $exitCode = [int]$Matches.code
                        break
                    }
                    continue
                }
                if ($normalizedLine -match $beginMarkerRegex) {
                    continue
                }
                if (Test-AzVmTaskOutputNoiseLine -Text ([string]$normalizedLine)) {
                    continue
                }
                if (Test-AzVmTransientSpinnerLine -Text ([string]$normalizedLine)) {
                    Write-AzVmTransientConsoleText -Text ([string]$normalizedLine)
                    $Session.TransientConsoleActive = $true
                    continue
                }
                if ([string]::IsNullOrWhiteSpace([string]$normalizedLine)) {
                    continue
                }
                if ($Session.TransientConsoleActive) {
                    Clear-AzVmTransientConsoleText
                    $Session.TransientConsoleActive = $false
                }
                [void]$outputLines.Add([string]$normalizedLine)
                Write-Host ([string]$normalizedLine)
            }
        }
        elseif ($completedIndex -eq 1) {
            $line = $stderrTask.Result
            $Session.PendingStderrTask = $stderrReader.ReadLineAsync()
            if ($null -ne $line) {
                $lineText = [string]$line
                $normalizedLine = Normalize-AzVmProtocolLine -Text $lineText
                if ($null -eq $normalizedLine) { $normalizedLine = "" }
                if (Test-AzVmTaskOutputNoiseLine -Text ([string]$normalizedLine)) {
                    continue
                }
                if (Test-AzVmTransientSpinnerLine -Text ([string]$normalizedLine)) {
                    Write-AzVmTransientConsoleText -Text ([string]$normalizedLine)
                    $Session.TransientConsoleActive = $true
                    continue
                }
                if ([string]::IsNullOrWhiteSpace([string]$normalizedLine)) {
                    continue
                }
                if ($Session.TransientConsoleActive) {
                    Clear-AzVmTransientConsoleText
                    $Session.TransientConsoleActive = $false
                }
                [void]$outputLines.Add([string]$normalizedLine)
                Write-Warning ([string]$normalizedLine)
            }
        }

        if ($proc.HasExited -and $null -eq $exitCode) {
            $stdoutTail = ""
            $stderrTail = ""
            try { $stdoutTail = [string]$stdoutReader.ReadToEnd() } catch { }
            try { $stderrTail = [string]$stderrReader.ReadToEnd() } catch { }
            if (-not [string]::IsNullOrWhiteSpace($stdoutTail)) {
                foreach ($line in ($stdoutTail -split "`r?`n")) {
                    $normalizedTailLine = Normalize-AzVmProtocolLine -Text ([string]$line)
                    if ([string]::IsNullOrWhiteSpace($normalizedTailLine)) { continue }
                    if (($normalizedTailLine -as [string]) -like "AZ_VM_SESSION_ERROR:*") {
                        throw ("Persistent SSH session reported protocol error for task '{0}': {1}" -f $TaskName, [string]$normalizedTailLine)
                    }
                    if ($normalizedTailLine -match $beginMarkerRegex) { continue }
                    if ($normalizedTailLine -match $endMarkerRegex) { continue }
                    if (Test-AzVmTaskOutputNoiseLine -Text ([string]$normalizedTailLine)) { continue }
                    if (Test-AzVmTransientSpinnerLine -Text ([string]$normalizedTailLine)) {
                        Write-AzVmTransientConsoleText -Text ([string]$normalizedTailLine)
                        $Session.TransientConsoleActive = $true
                        continue
                    }
                    if ($Session.TransientConsoleActive) {
                        Clear-AzVmTransientConsoleText
                        $Session.TransientConsoleActive = $false
                    }
                    [void]$outputLines.Add([string]$normalizedTailLine)
                    Write-Host ([string]$normalizedTailLine)
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($stderrTail)) {
                foreach ($line in ($stderrTail -split "`r?`n")) {
                    $normalizedTailLine = Normalize-AzVmProtocolLine -Text ([string]$line)
                    if ([string]::IsNullOrWhiteSpace($normalizedTailLine)) { continue }
                    if (Test-AzVmTaskOutputNoiseLine -Text ([string]$normalizedTailLine)) { continue }
                    if (Test-AzVmTransientSpinnerLine -Text ([string]$normalizedTailLine)) {
                        Write-AzVmTransientConsoleText -Text ([string]$normalizedTailLine)
                        $Session.TransientConsoleActive = $true
                        continue
                    }
                    if ($Session.TransientConsoleActive) {
                        Clear-AzVmTransientConsoleText
                        $Session.TransientConsoleActive = $false
                    }
                    [void]$outputLines.Add([string]$normalizedTailLine)
                    Write-Warning ([string]$normalizedTailLine)
                }
            }
            throw ("Persistent SSH session process exited before task completion (code={0})." -f $proc.ExitCode)
        }
        if ($taskWatch.Elapsed.TotalSeconds -gt ($TimeoutSeconds + 60)) {
            throw ("Persistent SSH task timeout guard reached for '{0}'." -f $TaskName)
        }
    }

    if ($taskWatch.IsRunning) { $taskWatch.Stop() }
    if ($Session.TransientConsoleActive) {
        Clear-AzVmTransientConsoleText
        $Session.TransientConsoleActive = $false
    }
    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Output = ($outputLines -join "`n")
        DurationSeconds = [double]$taskWatch.Elapsed.TotalSeconds
    }
}

# Handles Stop-AzVmPersistentSshSession.
function Stop-AzVmPersistentSshSession {
    param(
        [psobject]$Session
    )

    if ($null -eq $Session) {
        return
    }

    if ($Session.PSObject.Properties.Match('TransientConsoleActive').Count -gt 0 -and [bool]$Session.TransientConsoleActive) {
        Clear-AzVmTransientConsoleText
        $Session.TransientConsoleActive = $false
    }

    $proc = $Session.Process
    if ($null -ne $proc) {
        try {
            if (-not $proc.HasExited) {
                try {
                    $closePayload = @{ action = "close" } | ConvertTo-Json -Compress
                    Write-AzVmPersistentSshProtocolLine -Session $Session -Line ([string]$closePayload)
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

