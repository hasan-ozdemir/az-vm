# SSH process execution helpers.

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
