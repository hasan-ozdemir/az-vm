# Template-resolution helpers.

# Handles Resolve-AzVmTemplate.
function Resolve-AzVmTemplate {
    param(
        [string]$Template,
        [hashtable]$Tokens
    )

    if ([string]::IsNullOrWhiteSpace([string]$Template)) {
        return $Template
    }

    $result = [string]$Template
    if ($Tokens) {
        foreach ($key in @($Tokens.Keys)) {
            $tokenName = [string]$key
            $tokenValue = [string]$Tokens[$key]
            $result = $result.Replace(("{" + $tokenName + "}"), $tokenValue)
        }
    }
    return $result
}
