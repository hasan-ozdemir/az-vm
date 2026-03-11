# Resource naming and path-resolution helpers.

# Handles Get-AzVmNextNameIndex.
function Get-AzVmNextNameIndex {
    param(
        [string]$ResourceGroup,
        [string]$NamePrefix
    )

    if ([string]::IsNullOrWhiteSpace([string]$NamePrefix)) {
        return 1
    }

    $groupExists = az group exists -n $ResourceGroup --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not [string]::Equals([string]$groupExists, 'true', [System.StringComparison]::OrdinalIgnoreCase)) {
        return 1
    }

    $namesText = az resource list -g $ResourceGroup --query "[].name" -o tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        return 1
    }

    $tokens = @(Convert-AzVmCliTextToTokens -Text $namesText)
    if ($tokens.Count -eq 0) {
        return 1
    }

    $pattern = '^' + [regex]::Escape([string]$NamePrefix) + '(\d+)$'
    $maxIndex = 0
    foreach ($token in @($tokens)) {
        $name = [string]$token
        $m = [regex]::Match($name, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $m.Success) { continue }
        $idxText = [string]$m.Groups[1].Value
        if (-not ($idxText -match '^\d+$')) { continue }
        $idx = [int]$idxText
        if ($idx -gt $maxIndex) {
            $maxIndex = $idx
        }
    }

    return ($maxIndex + 1)
}

# Handles Get-AzVmNextManagedResourceGroupIndex.
function Get-AzVmNextManagedResourceGroupIndex {
    param(
        [string]$NamePrefix
    )

    if ([string]::IsNullOrWhiteSpace([string]$NamePrefix)) {
        return 1
    }

    $rows = @()
    try {
        $rows = @(Get-AzVmManagedResourceGroupRows)
    }
    catch {
        Throw-FriendlyError `
            -Detail ("Managed resource groups could not be listed while resolving name prefix '{0}'." -f [string]$NamePrefix) `
            -Code 22 `
            -Summary "Resource group naming could not be resolved." `
            -Hint "Run az login and verify access to list tagged resource groups."
    }

    $pattern = '^' + [regex]::Escape([string]$NamePrefix) + '(\d+)$'
    $maxIndex = 0
    foreach ($row in @($rows)) {
        $name = [string]$row.name
        if ([string]::IsNullOrWhiteSpace([string]$name)) {
            continue
        }

        $m = [regex]::Match($name, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $m.Success) {
            continue
        }

        $idxText = [string]$m.Groups[1].Value
        if (-not ($idxText -match '^\d+$')) {
            continue
        }

        $idx = [int]$idxText
        if ($idx -gt $maxIndex) {
            $maxIndex = $idx
        }
    }

    return ($maxIndex + 1)
}

# Handles Resolve-AzVmResourceGroupNameFromTemplate.
function Resolve-AzVmResourceGroupNameFromTemplate {
    param(
        [string]$Template,
        [string]$VmName,
        [string]$RegionCode,
        [switch]$UseNextIndex
    )

    $effectiveTemplate = [string]$Template
    if ([string]::IsNullOrWhiteSpace([string]$effectiveTemplate)) {
        $effectiveTemplate = "rg-{VM_NAME}-{REGION_CODE}-g{N}"
    }

    $tokens = @{
        VM_NAME = [string]$VmName
        REGION_CODE = [string]$RegionCode
        N = "1"
    }

    $resolved = Resolve-AzVmTemplate -Template $effectiveTemplate -Tokens $tokens
    if ($resolved.IndexOf("{N}", [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        return $resolved
    }

    $index = 1
    if ($UseNextIndex) {
        $prefix = $resolved.Replace("{N}", "")
        $index = Get-AzVmNextManagedResourceGroupIndex -NamePrefix $prefix
    }

    return $resolved.Replace("{N}", [string]$index)
}

# Handles Resolve-AzVmNameFromTemplate.
function Resolve-AzVmNameFromTemplate {
    param(
        [string]$Template,
        [string]$ResourceType,
        [string]$VmName,
        [string]$RegionCode,
        [string]$ResourceGroup,
        [switch]$UseNextIndex
    )

    $effectiveTemplate = [string]$Template
    if ([string]::IsNullOrWhiteSpace($effectiveTemplate)) {
        $effectiveTemplate = "{RESOURCE_TYPE}-{VM_NAME}-{REGION_CODE}-n{N}"
    }

    $baseTokens = @{
        RESOURCE_TYPE = [string]$ResourceType
        VM_NAME = [string]$VmName
        REGION_CODE = [string]$RegionCode
    }

    $resolved = Resolve-AzVmTemplate -Template $effectiveTemplate -Tokens $baseTokens
    if ($resolved.IndexOf("{N}", [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        return $resolved
    }

    $index = 1
    if ($UseNextIndex) {
        $prefix = $resolved.Replace("{N}", "")
        $index = Get-AzVmNextNameIndex -ResourceGroup $ResourceGroup -NamePrefix $prefix
    }

    return $resolved.Replace("{N}", [string]$index)
}

# Handles Resolve-ConfigPath.
function Resolve-ConfigPath {
    param(
        [string]$PathValue,
        [string]$RootPath
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $PathValue
    }

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }

    return Join-Path $RootPath $PathValue
}
