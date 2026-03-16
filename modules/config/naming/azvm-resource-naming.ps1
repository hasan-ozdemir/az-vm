# Resource naming and path-resolution helpers.

# Handles Get-AzVmManagedResourceNames.
function Get-AzVmManagedResourceNames {
    $rows = @()
    try {
        $rows = @(Get-AzVmManagedResourceGroupRows)
    }
    catch {
        Throw-FriendlyError `
            -Detail "Managed resource groups could not be listed while resolving the next resource id." `
            -Code 22 `
            -Summary "Managed resource naming could not be resolved." `
            -Hint "Run az login and verify access to list tagged resource groups."
    }

    $names = @()
    foreach ($row in @($rows)) {
        $resourceGroup = [string]$row.name
        if ([string]::IsNullOrWhiteSpace([string]$resourceGroup)) {
            continue
        }

        $groupNamesText = az resource list -g $resourceGroup --query "[].name" -o tsv --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) {
            continue
        }

        $names += @(Convert-AzVmCliTextToTokens -Text $groupNamesText)
    }

    return @(
        @($names) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
}

# Handles Get-AzVmNextManagedResourceIndex.
function Get-AzVmNextManagedResourceIndex {
    $pattern = '-n(\d+)$'
    $maxIndex = 0
    foreach ($name in @(Get-AzVmManagedResourceNames)) {
        $match = [regex]::Match([string]$name, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) {
            continue
        }

        $idxText = [string]$match.Groups[1].Value
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

# Handles New-AzVmManagedResourceIndexAllocator.
function New-AzVmManagedResourceIndexAllocator {
    return @{
        ExistingMaxIndex = ((Get-AzVmNextManagedResourceIndex) - 1)
        NextIndex = (Get-AzVmNextManagedResourceIndex)
        AllocatedIndices = @{}
    }
}

# Handles Get-AzVmManagedResourceNameIndex.
function Get-AzVmManagedResourceNameIndex {
    param(
        [string]$Name
    )

    $match = [regex]::Match([string]$Name, '-n(\d+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        return 0
    }

    $idxText = [string]$match.Groups[1].Value
    if (-not ($idxText -match '^\d+$')) {
        return 0
    }

    return [int]$idxText
}

# Handles Register-AzVmManagedResourceNameIndex.
function Register-AzVmManagedResourceNameIndex {
    param(
        [hashtable]$Allocator,
        [string]$Name,
        [string]$LogicalName = 'resource'
    )

    if ($null -eq $Allocator) {
        return 0
    }

    if (-not $Allocator.ContainsKey('AllocatedIndices') -or $null -eq $Allocator['AllocatedIndices']) {
        $Allocator['AllocatedIndices'] = @{}
    }

    $index = Get-AzVmManagedResourceNameIndex -Name $Name
    if ($index -lt 1) {
        return 0
    }

    $allocatedIndices = $Allocator['AllocatedIndices']
    $existingMaxIndex = 0
    if ($Allocator.ContainsKey('ExistingMaxIndex')) {
        $existingMaxIndex = [int]$Allocator['ExistingMaxIndex']
    }

    if ($index -le $existingMaxIndex) {
        Throw-FriendlyError `
            -Detail ("Managed resource name '{0}' reuses existing global resource id n{1}." -f [string]$Name, $index) `
            -Code 62 `
            -Summary "Managed resource ids must be globally unique." `
            -Hint "Accept the generated resource name or choose a custom name with an unused nX suffix."
    }

    if ($allocatedIndices.ContainsKey([string]$index)) {
        $otherLogicalName = [string]$allocatedIndices[[string]$index]
        if ([string]::Equals([string]$otherLogicalName, [string]$LogicalName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $index
        }
        Throw-FriendlyError `
            -Detail ("Managed resource names '{0}' and '{1}' both use global resource id n{2}." -f [string]$LogicalName, [string]$otherLogicalName, $index) `
            -Code 62 `
            -Summary "Managed resource ids must stay unique within the provisioning plan." `
            -Hint "Use generated names or choose custom names with distinct nX suffixes."
    }

    $allocatedIndices[[string]$index] = [string]$LogicalName
    $Allocator['AllocatedIndices'] = $allocatedIndices
    $nextIndex = [int]$Allocator['NextIndex']
    if ($index -ge $nextIndex) {
        $Allocator['NextIndex'] = ($index + 1)
    }

    return $index
}

# Handles Get-AzVmManagedResourceIndexFromAllocator.
function Get-AzVmManagedResourceIndexFromAllocator {
    param(
        [hashtable]$Allocator,
        [string]$LogicalName = 'resource'
    )

    if ($null -eq $Allocator) {
        return (Get-AzVmNextManagedResourceIndex)
    }

    if (-not $Allocator.ContainsKey('NextIndex')) {
        $Allocator['NextIndex'] = (Get-AzVmNextManagedResourceIndex)
    }

    $index = [int]$Allocator['NextIndex']
    if ($index -lt 1) {
        $index = 1
    }

    $Allocator['NextIndex'] = ($index + 1)
    if (-not $Allocator.ContainsKey('AllocatedIndices') -or $null -eq $Allocator['AllocatedIndices']) {
        $Allocator['AllocatedIndices'] = @{}
    }
    $allocatedIndices = $Allocator['AllocatedIndices']
    $allocatedIndices[[string]$index] = [string]$LogicalName
    $Allocator['AllocatedIndices'] = $allocatedIndices
    return $index
}

# Handles Get-AzVmNextManagedResourceGroupIndex.
function Get-AzVmNextManagedResourceGroupIndex {
    param(
        [string]$NamePrefix
    )

    $rows = @()
    try {
        $rows = @(Get-AzVmManagedResourceGroupRows)
    }
    catch {
        Throw-FriendlyError `
            -Detail "Managed resource groups could not be listed while resolving the next group id." `
            -Code 22 `
            -Summary "Resource group naming could not be resolved." `
            -Hint "Run az login and verify access to list tagged resource groups."
    }

    $pattern = '-g(\d+)$'
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
        $effectiveTemplate = "rg-{SELECTED_VM_NAME}-{REGION_CODE}-g{N}"
    }

    $baseTokens = @{
        SELECTED_VM_NAME = [string]$VmName
        REGION_CODE = [string]$RegionCode
    }

    $resolved = Resolve-AzVmTemplate -Template $effectiveTemplate -Tokens $baseTokens
    $resolved = Assert-AzVmResolvedTemplateValue `
        -Value $resolved `
        -ConfigKey 'RESOURCE_GROUP_TEMPLATE' `
        -AllowedTokens @('N') `
        -Hint "Set RESOURCE_GROUP_TEMPLATE in .env to the current placeholder contract, for example rg-{SELECTED_VM_NAME}-{REGION_CODE}-g{N}."
    if ($resolved.IndexOf("{N}", [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        return $resolved
    }

    $index = 1
    if ($UseNextIndex) {
        $index = Get-AzVmNextManagedResourceGroupIndex -NamePrefix ''
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
        [switch]$UseNextIndex,
        [hashtable]$IndexAllocator,
        [string]$LogicalName = 'resource'
    )

    $effectiveTemplate = [string]$Template
    if ([string]::IsNullOrWhiteSpace($effectiveTemplate)) {
        $effectiveTemplate = "{RESOURCE_TYPE}-{SELECTED_VM_NAME}-{REGION_CODE}-n{N}"
    }

    $baseTokens = @{
        RESOURCE_TYPE = [string]$ResourceType
        SELECTED_VM_NAME = [string]$VmName
        REGION_CODE = [string]$RegionCode
    }

    $resolved = Resolve-AzVmTemplate -Template $effectiveTemplate -Tokens $baseTokens
    $resolved = Assert-AzVmResolvedTemplateValue `
        -Value $resolved `
        -ConfigKey ("{0} template" -f [string]$LogicalName) `
        -AllowedTokens @('N') `
        -Hint "Set naming templates in .env to the current placeholder contract, for example {RESOURCE_TYPE}-{SELECTED_VM_NAME}-{REGION_CODE}-n{N}."
    if ($resolved.IndexOf("{N}", [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        return $resolved
    }

    $index = 1
    if ($UseNextIndex) {
        $index = Get-AzVmManagedResourceIndexFromAllocator -Allocator $IndexAllocator -LogicalName $LogicalName
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
