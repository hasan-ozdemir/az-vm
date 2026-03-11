# Shared JSON compatibility helpers.

# Handles ConvertFrom-JsonCompat.
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

# Handles ConvertFrom-JsonArrayCompat.
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

    return $result
}

# Handles ConvertTo-ObjectArrayCompat.
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

    return $result
}
