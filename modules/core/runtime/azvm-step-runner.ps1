# Shared runtime step and action wrappers.

# Handles Invoke-Step.
function Invoke-Step {
    param(
        [string] $prompt,
        [scriptblock] $Action
    )

    function Publish-NewStepVariables {
        param(
            [object[]]$BeforeVariables,
            [object[]]$AfterVariables
        )

        $beforeNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($beforeVar in $BeforeVariables) {
            [void]$beforeNames.Add([string]$beforeVar.Name)
        }

        foreach ($var in $AfterVariables) {
            $varName = [string]$var.Name
            if ($beforeNames.Contains($varName)) {
                continue
            }

            if (($var.Options -band [System.Management.Automation.ScopedItemOptions]::Constant) -ne 0) {
                continue
            }

            try {
                Set-Variable -Name $varName -Value $var.Value -Scope Script -Force -ErrorAction Stop
            }
            catch {
                # Skip transient or restricted variables safely.
            }
        }
    }

    $before = @(Get-Variable)
    if ($script:AutoMode) {
        Write-Host "$prompt (mode: auto)" -ForegroundColor Cyan
        $stepWatch = [System.Diagnostics.Stopwatch]::StartNew()
        . $Action
        if ($stepWatch.IsRunning) { $stepWatch.Stop() }
        if ($script:PerfMode) {
            Write-AzVmPerfTiming -Category "step" -Label ("{0} [mode:auto]" -f $prompt) -Seconds $stepWatch.Elapsed.TotalSeconds
        }
        $after = @(Get-Variable)
        Publish-NewStepVariables -BeforeVariables $before -AfterVariables $after
        return
    }
    do {
        $response = Read-Host "$prompt (mode: interactive) (yes/no)?"
    } until ($response -match '^[yYnN]$')
    if ($response -match '^[yY]$') {
        $stepWatch = [System.Diagnostics.Stopwatch]::StartNew()
        . $Action
        if ($stepWatch.IsRunning) { $stepWatch.Stop() }
        if ($script:PerfMode) {
            Write-AzVmPerfTiming -Category "step" -Label ("{0} [mode:interactive]" -f $prompt) -Seconds $stepWatch.Elapsed.TotalSeconds
        }
        $after = @(Get-Variable)
        Publish-NewStepVariables -BeforeVariables $before -AfterVariables $after
    }
    else {
        Write-Host "Skipping this step." -ForegroundColor Cyan
    }
}

# Handles Confirm-YesNo.
function Confirm-YesNo {
    param(
        [string]$PromptText,
        [bool]$DefaultYes = $false
    )

    $hintText = if ($DefaultYes) { " [Y/n]" } else { " [y/N]" }
    while ($true) {
        $raw = Read-Host ($PromptText + $hintText)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $DefaultYes
        }

        $value = $raw.Trim().ToLowerInvariant()
        if ($value -eq "y" -or $value -eq "yes") {
            return $true
        }
        if ($value -eq "n" -or $value -eq "no") {
            return $false
        }

        Write-Host "Please answer yes or no." -ForegroundColor Yellow
    }
}

# Handles Invoke-TrackedAction.
function Invoke-TrackedAction {
    param(
        [string]$Label,
        [scriptblock]$Action
    )

    if ([string]::IsNullOrWhiteSpace($Label)) {
        $Label = "action"
    }

    $isAzLabel = ([string]$Label).TrimStart().ToLowerInvariant().StartsWith("az ")
    Write-Host ("running: {0}" -f $Label) -ForegroundColor DarkCyan
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($isAzLabel) {
        $script:PerfSuppressAzTimingDepth = [int]$script:PerfSuppressAzTimingDepth + 1
    }
    try {
        $result = . $Action
        if ($null -ne $result) {
            return $result
        }
    }
    finally {
        if ($isAzLabel) {
            $script:PerfSuppressAzTimingDepth = [Math]::Max(0, ([int]$script:PerfSuppressAzTimingDepth - 1))
        }
        if ($watch.IsRunning) {
            $watch.Stop()
        }
        Write-Host ("finished: {0} ({1:N1}s)" -f $Label, $watch.Elapsed.TotalSeconds) -ForegroundColor DarkCyan
        if ($script:PerfMode) {
            $category = if ($isAzLabel) { "az" } else { "action" }
            Write-AzVmPerfTiming -Category $category -Label $Label -Seconds $watch.Elapsed.TotalSeconds
        }
    }
}
