# SSH session lifecycle helpers.

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
