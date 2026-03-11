# Shared config resolution helpers.

# Handles Test-AzVmConfigPlaceholderValue.
function Test-AzVmConfigPlaceholderValue {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return $false
    }

    $normalized = $Value.Trim().ToLowerInvariant()
    return (
        $normalized.Contains('change_me') -or
        $normalized.Contains('changeme') -or
        $normalized.Contains('replace_me') -or
        $normalized.Contains('set_me') -or
        $normalized.Contains('todo') -or
        $normalized.StartsWith('<') -or
        $normalized.EndsWith('>')
    )
}

# Handles Get-AzVmResolvedConfigValue.
function Get-AzVmResolvedConfigValue {
    param(
        [hashtable]$ConfigMap,
        [string]$Key,
        [hashtable]$Tokens = @{},
        [string]$DefaultValue = ''
    )

    $rawValue = [string](Get-ConfigValue -Config $ConfigMap -Key $Key -DefaultValue $DefaultValue)
    return [string](Resolve-AzVmTemplate -Template $rawValue -Tokens $Tokens)
}

# Handles Get-AzVmRequiredResolvedConfigValue.
function Get-AzVmRequiredResolvedConfigValue {
    param(
        [hashtable]$ConfigMap,
        [string]$Key,
        [hashtable]$Tokens = @{},
        [string]$Summary,
        [string]$Hint,
        [int]$Code = 14,
        [string]$DefaultValue = ''
    )

    $resolvedValue = [string](Get-AzVmResolvedConfigValue -ConfigMap $ConfigMap -Key $Key -Tokens $Tokens -DefaultValue $DefaultValue)
    if ([string]::IsNullOrWhiteSpace([string]$resolvedValue)) {
        Throw-FriendlyError `
            -Detail ("Required config value '{0}' is not set." -f $Key) `
            -Code $Code `
            -Summary $Summary `
            -Hint $Hint
    }

    if (Test-AzVmConfigPlaceholderValue -Value $resolvedValue) {
        Throw-FriendlyError `
            -Detail ("Config value '{0}' still uses a placeholder value: '{1}'." -f $Key, $resolvedValue) `
            -Code $Code `
            -Summary $Summary `
            -Hint $Hint
    }

    return $resolvedValue
}
