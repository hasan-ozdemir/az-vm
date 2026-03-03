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

function Write-TextFileNormalized {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [AllowNull()]
        [string]$Content,
        [ValidateSet("utf8NoBom", "ascii")]
        [string]$Encoding = "utf8NoBom",
        [ValidateSet("lf", "crlf", "preserve")]
        [string]$LineEnding = "preserve",
        [switch]$EnsureTrailingNewline
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Write-TextFileNormalized requires a valid file path."
    }

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if ($null -eq $Content) {
        $Content = ""
    }
    $text = [string]$Content

    switch ($LineEnding) {
        "lf" {
            $text = $text -replace "`r`n", "`n"
            $text = $text -replace "`r", "`n"
        }
        "crlf" {
            $text = $text -replace "`r`n", "`n"
            $text = $text -replace "`r", "`n"
            $text = $text -replace "`n", "`r`n"
        }
    }

    if ($EnsureTrailingNewline) {
        $targetEnding = if ($LineEnding -eq "crlf") { "`r`n" } else { "`n" }
        if (-not $text.EndsWith($targetEnding)) {
            $text += $targetEnding
        }
    }

    $encodingObject = switch ($Encoding) {
        "utf8NoBom" { New-Object System.Text.UTF8Encoding($false) }
        "ascii" { [System.Text.Encoding]::ASCII }
        default { New-Object System.Text.UTF8Encoding($false) }
    }

    [System.IO.File]::WriteAllText($Path, $text, $encodingObject)
}
