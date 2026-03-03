function Invoke-Step {
    param(
        [string] $prompt,
        [scriptblock] $Action
    )
    $before = Get-Variable
    if ($script:AutoMode) {
        Write-Host "$prompt (mode: auto)" -ForegroundColor Cyan
        . $Action
        $after = Get-Variable
        foreach ($var in $after) {
            if (-not ($before.Name -contains $var.Name)) {
                Set-Variable -Name $var.Name -Value $var.Value -Scope Script
            }
        }
        return
    }
    do {
        $response = Read-Host "$prompt (mode: interactive) (yes/no)?"
    } until ($response -match '^[yYnN]$')
    if ($response -match '^[yY]$') {
        . $Action
        $after = Get-Variable
        foreach ($var in $after) {
            if (-not ($before.Name -contains $var.Name)) {
                Set-Variable -Name $var.Name -Value $var.Value -Scope Script
            }
        }
    }
    else {
        Write-Host "Skipping this step." -ForegroundColor Cyan
    }
}

function Assert-LastExitCode {
    param(
        [string]$Context
    )
    if ($LASTEXITCODE -ne 0) {
        throw "$Context failed with exit code $LASTEXITCODE."
    }
}

function Throw-FriendlyError {
    param(
        [string]$Detail,
        [int]$Code,
        [string]$Summary,
        [string]$Hint
    )

    $ex = [System.Exception]::new($Detail)
    $ex.Data["ExitCode"] = $Code
    $ex.Data["Summary"] = $Summary
    $ex.Data["Hint"] = $Hint
    throw $ex
}
