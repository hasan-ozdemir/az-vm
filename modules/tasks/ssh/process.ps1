# SSH process execution helpers.

function Invoke-AzVmCapturedProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = [string]$FilePath
    $psi.Arguments = ((@($Arguments) | ForEach-Object { Convert-AzVmProcessArgument -Value ([string]$_) }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psiType = $psi.GetType()
    if ($psiType.GetProperty('StandardOutputEncoding')) {
        try { $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    }
    if ($psiType.GetProperty('StandardErrorEncoding')) {
        try { $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8 } catch { }
    }
    $null = $psi.EnvironmentVariables
    $psi.EnvironmentVariables['PYTHONDONTWRITEBYTECODE'] = '1'

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    if (-not $proc.Start()) {
        throw ("Process could not be started: {0}" -f [string]$FilePath)
    }

    try {
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $outputParts = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$stdout)) {
            $outputParts += [string]$stdout
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$stderr)) {
            $outputParts += [string]$stderr
        }

        return [pscustomobject]@{
            ExitCode = [int]$proc.ExitCode
            Output = (($outputParts | ForEach-Object { [string]$_ }) -join "`n").Trim()
        }
    }
    finally {
        try { $proc.Dispose() } catch { }
    }
}

# Handles Invoke-AzVmProcessWithRetry.
function Invoke-AzVmProcessWithRetry {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$Label,
        [int]$MaxAttempts = 3,
        [switch]$AllowFailure,
        [switch]$SuppressTrackedLogging
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
        if ($SuppressTrackedLogging) {
            $processResult = Invoke-AzVmCapturedProcess -FilePath $FilePath -Arguments (@('-B') + @($Arguments))
        }
        else {
            $processResult = Invoke-TrackedAction -Label $attemptLabel -Action {
                Invoke-AzVmCapturedProcess -FilePath $FilePath -Arguments (@('-B') + @($Arguments))
            }
        }
        $lastExit = [int]$processResult.ExitCode
        $lastOutput = [string]$processResult.Output

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
