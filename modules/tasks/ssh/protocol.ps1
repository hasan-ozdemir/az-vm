# SSH protocol parsing and console-noise helpers.

# Handles Normalize-AzVmProtocolLine.
function Normalize-AzVmProtocolLine {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        return $null
    }

    $value = [string]$Text
    $value = $value.Replace("`0", "")
    $value = $value.TrimStart([char]0xFEFF)
    $value = $value.TrimEnd("`r", "`n")
    $trimmedLeading = $value.TrimStart()
    if ($trimmedLeading -match '^(?<spinner>[\|/\\-]{1,16})\s+(?<marker>(?:\[stderr\]\s+)?AZ_VM_[A-Z_]+:.*)$') {
        return [string]$Matches.marker
    }
    return $value
}

# Handles Test-AzVmTransientSpinnerLine.
function Test-AzVmTransientSpinnerLine {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        return $false
    }

    $value = [string]$Text
    if ($value.StartsWith("[stderr] ", [System.StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring(9)
    }

    $value = $value.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }

    return [regex]::IsMatch($value, '^[\|/\\-]{1,16}$')
}

# Handles Write-AzVmTransientConsoleText.
function Write-AzVmTransientConsoleText {
    param(
        [AllowNull()]
        [string]$Text
    )

    $value = if ($null -eq $Text) { "" } else { [string]$Text }
    [Console]::Write(("`r{0}" -f $value))
}

# Handles Clear-AzVmTransientConsoleText.
function Clear-AzVmTransientConsoleText {
    [Console]::WriteLine("")
}

# Handles Test-AzVmTaskOutputNoiseLine.
function Test-AzVmTaskOutputNoiseLine {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        return $false
    }

    $value = [string]$Text
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }

    return (
        $value.StartsWith("AZ_VM_TASK_BEGIN:", [System.StringComparison]::OrdinalIgnoreCase) -or
        $value.StartsWith("AZ_VM_TASK_END:", [System.StringComparison]::OrdinalIgnoreCase) -or
        $value.StartsWith("Update task started:", [System.StringComparison]::OrdinalIgnoreCase) -or
        $value.StartsWith("Update task completed:", [System.StringComparison]::OrdinalIgnoreCase) -or
        ($value -match "(?i)'wmic'\s+is\s+not\s+recognized\s+as\s+an\s+internal\s+or\s+external\s+command") -or
        ($value -match '(?i)^Seizure Warning:\s*https://aka\.ms/microsoft-store-seizure-warning')
    )
}

# Handles Convert-AzVmProtocolTaskExitCode.
function Convert-AzVmProtocolTaskExitCode {
    param(
        [AllowNull()]
        [string]$Text
    )

    $raw = ''
    if ($null -ne $Text) {
        $raw = [string]$Text
    }
    $raw = $raw.Trim()
    if ([string]::IsNullOrWhiteSpace([string]$raw)) {
        return 1
    }

    [Int64]$parsed = 0
    if (-not [Int64]::TryParse($raw, [ref]$parsed)) {
        throw ("Task exit code '{0}' is not a valid integer." -f $raw)
    }

    $uint32Max = [Int64][UInt32]::MaxValue
    $int32Max = [Int64][Int32]::MaxValue
    $int32Min = [Int64][Int32]::MinValue
    if ($parsed -gt $int32Max -and $parsed -le $uint32Max) {
        $parsed -= ($uint32Max + 1)
    }

    if ($parsed -lt $int32Min -or $parsed -gt $int32Max) {
        throw ("Task exit code '{0}' is outside the supported Int32 range." -f $raw)
    }

    return [int]$parsed
}
