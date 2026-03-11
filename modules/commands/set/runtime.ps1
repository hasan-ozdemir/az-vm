# Set command runtime helpers.

# Handles Resolve-AzVmToggleValue.
function Resolve-AzVmToggleValue {
    param(
        [string]$Name,
        [string]$RawValue
    )

    $value = if ($null -eq $RawValue) { '' } else { [string]$RawValue }
    $normalized = $value.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace([string]$normalized)) {
        return ''
    }

    if ($normalized -in @('on','true','1','yes','y')) {
        return 'on'
    }
    if ($normalized -in @('off','false','0','no','n')) {
        return 'off'
    }

    Throw-FriendlyError `
        -Detail ("Invalid value '{0}' for --{1}." -f $RawValue, $Name) `
        -Code 62 `
        -Summary "Invalid toggle value." `
        -Hint ("Use --{0}=on|off." -f $Name)
}

# Handles Read-AzVmToggleInteractive.
function Read-AzVmToggleInteractive {
    param(
        [string]$PromptText,
        [string]$DefaultValue = 'off'
    )

    $defaultNormalized = Resolve-AzVmToggleValue -Name 'toggle' -RawValue $DefaultValue
    if ([string]::IsNullOrWhiteSpace([string]$defaultNormalized)) {
        $defaultNormalized = 'off'
    }

    while ($true) {
        $raw = Read-Host ("{0} (on/off, default={1})" -f $PromptText, $defaultNormalized)
        if ([string]::IsNullOrWhiteSpace([string]$raw)) {
            return $defaultNormalized
        }
        $candidate = Resolve-AzVmToggleValue -Name 'toggle' -RawValue $raw
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            return $candidate
        }
    }
}

# Handles Copy-AzVmOptionsMap.
function Copy-AzVmOptionsMap {
    param(
        [hashtable]$Source
    )

    $copy = @{}
    if ($null -eq $Source) {
        return $copy
    }
    foreach ($key in @($Source.Keys)) {
        $copy[[string]$key] = $Source[$key]
    }
    return $copy
}
