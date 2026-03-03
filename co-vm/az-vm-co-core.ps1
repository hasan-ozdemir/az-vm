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
        . $Action
        $after = @(Get-Variable)
        Publish-NewStepVariables -BeforeVariables $before -AfterVariables $after
        return
    }
    do {
        $response = Read-Host "$prompt (mode: interactive) (yes/no)?"
    } until ($response -match '^[yYnN]$')
    if ($response -match '^[yY]$') {
        . $Action
        $after = @(Get-Variable)
        Publish-NewStepVariables -BeforeVariables $before -AfterVariables $after
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
    $result = @()
    if ($null -eq $parsed) {
        $result = @()
    }
    elseif ($parsed -is [System.Array]) {
        $result = @($parsed)
    }
    else {
        $result = @($parsed)
    }

    Write-Output -NoEnumerate $result
}

function ConvertTo-ObjectArrayCompat {
    param(
        [Parameter(Mandatory = $false)]
        [object]$InputObject
    )

    $result = @()

    if ($null -eq $InputObject) {
        $result = @()
    }
    elseif ($InputObject -is [System.Array]) {
        $result = @($InputObject)
    }
    elseif ($InputObject -is [string] -or $InputObject -is [char]) {
        $result = @([string]$InputObject)
    }
    elseif ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $result = @($InputObject)
    }
    else {
        $result = @($InputObject)
    }

    Write-Output -NoEnumerate $result
}
