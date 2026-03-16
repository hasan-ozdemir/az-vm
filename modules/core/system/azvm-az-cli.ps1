# Shared repo/system/Azure CLI helpers.

# Handles Get-AzVmRepoRoot.
function Get-AzVmRepoRoot {
    if (-not [string]::IsNullOrWhiteSpace([string]$script:AzVmRepoRoot) -and (Test-Path -LiteralPath ([string]$script:AzVmRepoRoot))) {
        return [string]$script:AzVmRepoRoot
    }

    $repoRootCandidate = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:AzVmRepoRoot = [string]$repoRootCandidate
    return [string]$script:AzVmRepoRoot
}

# Handles Convert-AzVmPerfSecondsText.
function Convert-AzVmPerfSecondsText {
    param(
        [double]$Seconds
    )

    if ($Seconds -lt 0) {
        $Seconds = 0
    }

    return ("{0:N1} seconds" -f [double]$Seconds)
}

# Handles Write-AzVmPerfTiming.
function Write-AzVmPerfTiming {
    param(
        [string]$Category,
        [string]$Label,
        [double]$Seconds
    )

    if (-not $script:PerfMode -or $script:AzVmQuietOutput) {
        return
    }

    $categoryText = if ([string]::IsNullOrWhiteSpace([string]$Category)) { "metric" } else { ([string]$Category).Trim() }
    $labelText = if ([string]::IsNullOrWhiteSpace([string]$Label)) { "operation" } else { ([string]$Label).Trim() }
    if ($labelText.Length -gt 240) {
        $labelText = $labelText.Substring(0, 237) + "..."
    }

    $durationText = Convert-AzVmPerfSecondsText -Seconds $Seconds
    Write-Host ("perf: {0} -> {1} ({2})" -f $categoryText, $labelText, $durationText) -ForegroundColor DarkGray
}

# Handles Get-AzVmAzCliExecutable.
function Get-AzVmAzCliExecutable {
    if (-not [string]::IsNullOrWhiteSpace([string]$script:AzCliExecutable)) {
        return [string]$script:AzCliExecutable
    }

    $azApps = @(Get-Command az -All -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' -and -not [string]::IsNullOrWhiteSpace([string]$_.Source) })
    $azApp = $null
    if ($azApps.Count -gt 0) {
        $azApp = @($azApps | Where-Object { -not ([string]$_.Source).ToLowerInvariant().EndsWith('.cmd') -and -not ([string]$_.Source).ToLowerInvariant().EndsWith('.bat') } | Select-Object -First 1)
        if ($null -eq $azApp -or @($azApp).Count -eq 0) {
            $azApp = @($azApps | Select-Object -First 1)
        }
        if ($azApp -is [System.Array]) {
            $azApp = [object]$azApp[0]
        }
    }
    if ($null -eq $azApp -or [string]::IsNullOrWhiteSpace([string]$azApp.Source)) {
        throw "Azure CLI executable could not be resolved from PATH."
    }

    $script:AzCliExecutable = [string]$azApp.Source
    return [string]$script:AzCliExecutable
}

# Handles Invoke-AzVmAzCliCommand.
function Invoke-AzVmAzCliCommand {
    param(
        [string[]]$Arguments
    )

    $argValues = @($Arguments | ForEach-Object { [string]$_ })
    $bypassSubscription = ($script:BypassAzCliSubscription -and ([int]$script:BypassAzCliSubscription -gt 0))
    if (-not $bypassSubscription -and -not [string]::IsNullOrWhiteSpace([string]$script:AzVmActiveSubscriptionId)) {
        $hasSubscriptionArgument = $false
        foreach ($argValue in @($argValues)) {
            $candidate = [string]$argValue
            if ([string]::Equals($candidate, '--subscription', [System.StringComparison]::OrdinalIgnoreCase) -or
                $candidate.StartsWith('--subscription=', [System.StringComparison]::OrdinalIgnoreCase)) {
                $hasSubscriptionArgument = $true
                break
            }
        }
        if (-not $hasSubscriptionArgument) {
            $argValues += @('--subscription', [string]$script:AzVmActiveSubscriptionId)
        }
    }

    $perfWatch = $null
    $perfLabel = ''
    $shouldEmitHeartbeat = $script:PerfMode -and ([int]$script:PerfSuppressAzTimingDepth -le 0)
    $lastHeartbeatSeconds = 0
    if ($shouldEmitHeartbeat) {
        $perfLabel = "az " + ($argValues -join " ")
        $perfWatch = [System.Diagnostics.Stopwatch]::StartNew()
    }

    try {
        $azExecutable = Get-AzVmAzCliExecutable
        $timeoutSeconds = [int]$script:AzCommandTimeoutSeconds
        if ($timeoutSeconds -lt 0) { $timeoutSeconds = 0 }
        $azExecutableText = [string]$azExecutable
        $useCmdHost = -not $azExecutableText.ToLowerInvariant().EndsWith('.exe')
        $cmdHost = if ([string]::IsNullOrWhiteSpace([string]$env:ComSpec)) { 'cmd.exe' } else { [string]$env:ComSpec }

        if ($timeoutSeconds -eq 0) {
            if ($useCmdHost) {
                & $cmdHost /d /c $azExecutableText @argValues
            }
            else {
                & $azExecutableText @argValues
            }
            return
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        if ($useCmdHost) {
            $psi.FileName = $cmdHost
            $cmdArgs = @('/d', '/c', $azExecutableText)
            $cmdArgs += $argValues
            $psi.Arguments = ($cmdArgs | ForEach-Object { Convert-AzVmProcessArgument -Value ([string]$_) }) -join ' '
        }
        else {
            $psi.FileName = $azExecutableText
            $psi.Arguments = ($argValues | ForEach-Object { Convert-AzVmProcessArgument -Value ([string]$_) }) -join ' '
        }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()

        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $waitMs = [int][Math]::Min([double][int]::MaxValue, [double]$timeoutSeconds * 1000.0)
        $elapsedSeconds = 0.0
        while (-not $proc.WaitForExit(1000)) {
            $elapsedSeconds += 1.0
            if ($shouldEmitHeartbeat -and -not $script:AzVmQuietOutput -and $elapsedSeconds -ge 30 -and (($elapsedSeconds - $lastHeartbeatSeconds) -ge 30)) {
                $lastHeartbeatSeconds = $elapsedSeconds
                Write-Host ("progress: {0} ({1})" -f $perfLabel, (Convert-AzVmPerfSecondsText -Seconds $elapsedSeconds)) -ForegroundColor DarkGray
            }
            if ($elapsedSeconds -ge $timeoutSeconds) {
                try { $proc.Kill() } catch { }
                try { [void]$proc.WaitForExit() } catch { }
                $global:LASTEXITCODE = 124
                throw ("az command timed out after {0} second(s)." -f $timeoutSeconds)
            }
        }

        [void]$proc.WaitForExit()
        $stdoutText = ""
        $stderrText = ""
        try { $stdoutText = [string]$stdoutTask.Result } catch { }
        try { $stderrText = [string]$stderrTask.Result } catch { }
        $global:LASTEXITCODE = [int]$proc.ExitCode

        $suppressAzStderrEcho = $false
        if ($script:SuppressAzCliStderrEcho) {
            $suppressAzStderrEcho = $true
        }
        if ((-not $suppressAzStderrEcho) -and -not $script:AzVmQuietOutput -and -not [string]::IsNullOrWhiteSpace($stderrText)) {
            Write-Host ($stderrText.TrimEnd())
        }

        if ([string]::IsNullOrWhiteSpace($stdoutText)) {
            return @()
        }

        $stdoutLines = @($stdoutText -split "`r?`n" | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($stdoutLines.Count -eq 0) {
            return @()
        }
        if ($stdoutLines.Count -eq 1) {
            return [string]$stdoutLines[0]
        }

        return $stdoutLines
    }
    finally {
        if ($null -ne $perfWatch -and $perfWatch.IsRunning) {
            $perfWatch.Stop()
        }
    }
}

# Handles Invoke-AzVmWithBypassedAzCliSubscription.
function Invoke-AzVmWithBypassedAzCliSubscription {
    param(
        [scriptblock]$Action
    )

    if ($null -eq $Action) {
        throw 'Invoke-AzVmWithBypassedAzCliSubscription requires an action.'
    }

    $previousDepth = 0
    if ($script:BypassAzCliSubscription) {
        $previousDepth = [int]$script:BypassAzCliSubscription
    }

    $script:BypassAzCliSubscription = $previousDepth + 1
    try {
        return (& $Action)
    }
    finally {
        if ($previousDepth -gt 0) {
            $script:BypassAzCliSubscription = $previousDepth
        }
        else {
            $script:BypassAzCliSubscription = 0
        }
    }
}

# Handles Invoke-AzVmWithSuppressedAzCliStderr.
function Invoke-AzVmWithSuppressedAzCliStderr {
    param(
        [scriptblock]$Action
    )

    $previousValue = $false
    if ($script:SuppressAzCliStderrEcho) {
        $previousValue = $true
    }

    $script:SuppressAzCliStderrEcho = $true
    try {
        return (& $Action)
    }
    finally {
        $script:SuppressAzCliStderrEcho = $previousValue
    }
}

# Handles az.
function az {
    $argList = @()
    foreach ($arg in @($args)) {
        $argList += [string]$arg
    }

    return (Invoke-AzVmAzCliCommand -Arguments $argList)
}

# Handles Invoke-AzVmHttpRestMethod.
function Invoke-AzVmHttpRestMethod {
    param(
        [ValidateSet("Get","Post","Put","Delete","Patch","Head","Options")]
        [string]$Method = "Get",
        [string]$Uri,
        [hashtable]$Headers,
        [AllowNull()]
        [object]$Body,
        [string]$PerfLabel = "http request"
    )

    if ([string]::IsNullOrWhiteSpace([string]$Uri)) {
        throw "HTTP request URI is required."
    }

    $watch = $null
    if ($script:PerfMode) {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
    }

    try {
        $invokeParams = @{
            Method = [string]$Method
            Uri = [string]$Uri
            ErrorAction = 'Stop'
        }
        if ($null -ne $Headers) {
            $invokeParams['Headers'] = $Headers
        }
        if ($PSBoundParameters.ContainsKey('Body')) {
            $invokeParams['Body'] = $Body
        }

        return Invoke-RestMethod @invokeParams
    }
    finally {
        if ($null -ne $watch -and $watch.IsRunning) {
            $watch.Stop()
        }
        if ($null -ne $watch) {
            Write-AzVmPerfTiming -Category "http" -Label $PerfLabel -Seconds $watch.Elapsed.TotalSeconds
        }
    }
}
