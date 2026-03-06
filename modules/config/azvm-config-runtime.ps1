# Imported runtime region: test-config.

# Handles Read-DotEnvFile.
function Read-DotEnvFile {
    param(
        [string]$Path
    )

    $config = @{}
    if (-not (Test-Path $Path)) {
        Write-Warning ".env file was not found at '$Path'. Built-in defaults will be used."
        return $config
    }

    foreach ($rawLine in Get-Content -Path $Path) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            continue
        }

        $match = [regex]::Match($line, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$')
        if (-not $match.Success) {
            Write-Warning "Skipping invalid .env line: $rawLine"
            continue
        }

        $key = $match.Groups[1].Value
        $value = $match.Groups[2].Value.Trim()
        if (
            ($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))
        ) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        $config[$key] = $value
    }

    return $config
}

# Handles Get-ConfigValue.
function Get-ConfigValue {
    param(
        [hashtable]$Config,
        [string]$Key,
        [string]$DefaultValue
    )

    if ($script:ConfigOverrides -and $script:ConfigOverrides.ContainsKey($Key)) {
        $overrideValue = [string]$script:ConfigOverrides[$Key]
        if (-not [string]::IsNullOrWhiteSpace($overrideValue)) {
            return $overrideValue
        }
    }

    if ($Config -and $Config.ContainsKey($Key)) {
        $configValue = [string]$Config[$Key]
        if (-not [string]::IsNullOrWhiteSpace($configValue)) {
            return $configValue
        }
    }

    return $DefaultValue
}

# Handles Resolve-ServerTemplate.
function Resolve-ServerTemplate {
    param(
        [string]$Value,
        [string]$ServerName
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    return $Value.Replace("{SERVER_NAME}", $ServerName)
}

# Handles Get-AzVmRegionCodeMap.
function Get-AzVmRegionCodeMap {
    return @{
        'austriaeast' = 'ate1'
        'austriawest' = 'atw1'
        'centralindia' = 'inc1'
        'southindia' = 'ins1'
        'westindia' = 'inw1'
        'eastus' = 'use1'
        'eastus2' = 'use2'
        'centralus' = 'usc1'
        'northcentralus' = 'usn1'
        'southcentralus' = 'uss1'
        'westus' = 'usw1'
        'westus2' = 'usw2'
        'westus3' = 'usw3'
        'westcentralus' = 'usw4'
        'canadacentral' = 'cac1'
        'canadaeast' = 'cae1'
        'mexicocentral' = 'mxc1'
        'brazilsouth' = 'brs1'
        'brazilsoutheast' = 'brs2'
        'chilecentral' = 'clc1'
        'northeurope' = 'eun1'
        'westeurope' = 'euw1'
        'francecentral' = 'frc1'
        'francesouth' = 'frs1'
        'germanywestcentral' = 'gew1'
        'germanynorth' = 'gen1'
        'italynorth' = 'itn1'
        'norwayeast' = 'noe1'
        'norwaywest' = 'now1'
        'polandcentral' = 'plc1'
        'spaincentral' = 'esc1'
        'swedencentral' = 'sec1'
        'swedensouth' = 'ses1'
        'switzerlandnorth' = 'chn1'
        'switzerlandwest' = 'chw1'
        'uksouth' = 'gbs1'
        'ukwest' = 'gbw1'
        'finlandcentral' = 'fic1'
        'eastasia' = 'ase1'
        'southeastasia' = 'ass1'
        'japaneast' = 'jpe1'
        'japanwest' = 'jpw1'
        'koreacentral' = 'krc1'
        'koreasouth' = 'krs1'
        'singapore' = 'sgc1'
        'indonesiacentral' = 'idc1'
        'malaysiawest' = 'myw1'
        'newzealandnorth' = 'nzn1'
        'australiaeast' = 'aue1'
        'australiasoutheast' = 'aus1'
        'australiacentral' = 'auc1'
        'australiacentral2' = 'auc2'
        'southafricanorth' = 'zan1'
        'southafricawest' = 'zaw1'
        'uaenorth' = 'aen1'
        'uaecentral' = 'aec1'
        'qatarcentral' = 'qac1'
        'israelcentral' = 'ilc1'
        'jioindiacentral' = 'inc2'
        'jioindiawest' = 'inw2'
    }
}

# Handles Get-AzVmRegionCode.
function Get-AzVmRegionCode {
    param(
        [string]$Location
    )

    $normalized = if ($null -eq $Location) { '' } else { [string]$Location.Trim().ToLowerInvariant() }
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        Throw-FriendlyError `
            -Detail "Region code could not be resolved because AZ_LOCATION is empty." `
            -Code 22 `
            -Summary "Region code resolution failed." `
            -Hint "Set AZ_LOCATION to a valid Azure region."
    }

    $map = Get-AzVmRegionCodeMap
    if ($map.ContainsKey($normalized)) {
        return [string]$map[$normalized]
    }

    Throw-FriendlyError `
        -Detail ("No static REGION_CODE mapping exists for region '{0}'." -f $normalized) `
        -Code 22 `
        -Summary "Region code resolution failed." `
        -Hint "Add the region to the built-in REGION_CODE map in az-vm.ps1."
}

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
        [string]$ServerName,
        [string]$RegionCode,
        [switch]$UseNextIndex
    )

    $effectiveTemplate = [string]$Template
    if ([string]::IsNullOrWhiteSpace([string]$effectiveTemplate)) {
        $effectiveTemplate = "rg-{SERVER_NAME}-{REGION_CODE}-g{N}"
    }

    $tokens = @{
        SERVER_NAME = [string]$ServerName
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
        [string]$ServerName,
        [string]$RegionCode,
        [string]$ResourceGroup,
        [switch]$UseNextIndex
    )

    $effectiveTemplate = [string]$Template
    if ([string]::IsNullOrWhiteSpace($effectiveTemplate)) {
        $effectiveTemplate = "{RESOURCE_TYPE}-{SERVER_NAME}-{REGION_CODE}-n{N}"
    }

    $baseTokens = @{
        RESOURCE_TYPE = [string]$ResourceType
        SERVER_NAME = [string]$ServerName
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

# Handles Set-DotEnvValue.
function Set-DotEnvValue {
    param(
        [string]$Path,
        [string]$Key,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Set-DotEnvValue requires a valid file path."
    }
    if ([string]::IsNullOrWhiteSpace($Key)) {
        throw "Set-DotEnvValue requires a non-empty key."
    }
    if ($null -eq $Value) {
        $Value = ""
    }

    $lines = @()
    if (Test-Path -LiteralPath $Path) {
        $lines = @((Get-Content -Path $Path -ErrorAction Stop))
    }

    $pattern = "^\s*" + [regex]::Escape($Key) + "\s*="
    $updated = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) {
            $lines[$i] = "$Key=$Value"
            $updated = $true
            break
        }
    }

    if (-not $updated) {
        if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines += ""
        }
        $lines += "$Key=$Value"
    }

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Write-TextFileNormalized `
        -Path $Path `
        -Content ($lines -join "`n") `
        -Encoding "utf8NoBom" `
        -LineEnding "crlf" `
        -EnsureTrailingNewline
}
