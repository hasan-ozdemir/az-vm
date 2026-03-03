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

function ConvertFrom-JsonCompat {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [string]) {
        $text = [string]$InputObject
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }
        return ($text | ConvertFrom-Json)
    }

    if ($InputObject -is [System.Array]) {
        if ($InputObject.Length -eq 0) {
            return @()
        }

        $first = $InputObject[0]
        if ($first -is [string]) {
            $joined = (($InputObject | ForEach-Object { [string]$_ }) -join "`n")
            if ([string]::IsNullOrWhiteSpace($joined)) {
                return $null
            }
            return ($joined | ConvertFrom-Json)
        }

        return $InputObject
    }

    $asText = [string]$InputObject
    $trimmed = $asText.TrimStart()
    if ($trimmed.StartsWith("{") -or $trimmed.StartsWith("[")) {
        return ($asText | ConvertFrom-Json)
    }

    return $InputObject
}

function ConvertFrom-JsonArrayCompat {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    $parsed = ConvertFrom-JsonCompat -InputObject $InputObject
    if ($null -eq $parsed) {
        return @()
    }
    if ($parsed -is [System.Array]) {
        return $parsed
    }

    return @($parsed)
}
