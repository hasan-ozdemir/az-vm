# Dotenv read/write helpers.

function Get-AzVmRetiredDotEnvKeys {
    return @(
        'VM_OS_TYPE',
        'VM_NAME',
        'company_name',
        'company_web_address',
        'company_email_address',
        'employee_email_address',
        'employee_full_name',
        'azure_subscription_id',
        'AZ_LOCATION',
        'RESOURCE_GROUP',
        'VNET_NAME',
        'SUBNET_NAME',
        'NSG_NAME',
        'NSG_RULE_NAME',
        'PUBLIC_IP_NAME',
        'NIC_NAME',
        'VM_DISK_NAME',
        'PRICE_HOURS',
        'AZ_COMMAND_TIMEOUT_SECONDS'
    )
}

function Resolve-AzVmRuntimeConfigAliases {
    param(
        [hashtable]$ConfigMap
    )

    $resolved = @{}
    if ($ConfigMap) {
        foreach ($key in @($ConfigMap.Keys)) {
            $resolved[[string]$key] = [string]$ConfigMap[$key]
        }
    }

    foreach ($retiredKey in @(Get-AzVmRetiredDotEnvKeys)) {
        if ($resolved.ContainsKey([string]$retiredKey)) {
            $null = $resolved.Remove([string]$retiredKey)
        }
    }

    $aliasMap = [ordered]@{
        SELECTED_VM_OS = 'VM_OS_TYPE'
        SELECTED_VM_NAME = 'VM_NAME'
        SELECTED_COMPANY_NAME = 'company_name'
        SELECTED_COMPANY_WEB_ADDRESS = 'company_web_address'
        SELECTED_COMPANY_EMAIL_ADDRESS = 'company_email_address'
        SELECTED_EMPLOYEE_EMAIL_ADDRESS = 'employee_email_address'
        SELECTED_EMPLOYEE_FULL_NAME = 'employee_full_name'
        SELECTED_AZURE_SUBSCRIPTION_ID = 'azure_subscription_id'
        SELECTED_AZURE_REGION = 'AZ_LOCATION'
        SELECTED_RESOURCE_GROUP = 'RESOURCE_GROUP'
        VM_PRICE_COUNT_HOURS = 'PRICE_HOURS'
        AZURE_COMMAND_TIMEOUT_SECONDS = 'AZ_COMMAND_TIMEOUT_SECONDS'
    }

    foreach ($sourceKey in @($aliasMap.Keys)) {
        $targetKey = [string]$aliasMap[[string]$sourceKey]
        $sourceValue = ''
        if ($resolved.ContainsKey([string]$sourceKey)) {
            $sourceValue = [string]$resolved[[string]$sourceKey]
        }
        if ([string]::IsNullOrWhiteSpace([string]$sourceValue)) {
            continue
        }

        $resolved[[string]$targetKey] = [string]$sourceValue
    }

    return $resolved
}

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

    return (Resolve-AzVmRuntimeConfigAliases -ConfigMap $config)
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
    elseif ($script:ConfigOverrides) {
        foreach ($overrideKey in @($script:ConfigOverrides.Keys)) {
            if (-not [string]::Equals([string]$overrideKey, [string]$Key, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $overrideValue = [string]$script:ConfigOverrides[$overrideKey]
            if (-not [string]::IsNullOrWhiteSpace($overrideValue)) {
                return $overrideValue
            }
        }
    }

    if ($Config -and $Config.ContainsKey($Key)) {
        $configValue = [string]$Config[$Key]
        if (-not [string]::IsNullOrWhiteSpace($configValue)) {
            return $configValue
        }
    }
    elseif ($Config) {
        foreach ($configKey in @($Config.Keys)) {
            if (-not [string]::Equals([string]$configKey, [string]$Key, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $configValue = [string]$Config[$configKey]
            if (-not [string]::IsNullOrWhiteSpace($configValue)) {
                return $configValue
            }
        }
    }

    return $DefaultValue
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

function Remove-DotEnvKeys {
    param(
        [string]$Path,
        [string[]]$Keys
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path) -or -not (Test-Path -LiteralPath $Path)) {
        return
    }

    $keysToRemove = @(
        @($Keys) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Sort-Object -Unique
    )
    if (@($keysToRemove).Count -eq 0) {
        return
    }

    $lines = @((Get-Content -Path $Path -ErrorAction Stop))
    $filtered = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($lines)) {
        $removeLine = $false
        foreach ($key in @($keysToRemove)) {
            $pattern = "^\s*" + [regex]::Escape($key) + "\s*="
            if ([string]$line -match $pattern) {
                $removeLine = $true
                break
            }
        }

        if (-not $removeLine) {
            [void]$filtered.Add([string]$line)
        }
    }

    Write-TextFileNormalized `
        -Path $Path `
        -Content (@($filtered) -join "`n") `
        -Encoding "utf8NoBom" `
        -LineEnding "crlf" `
        -EnsureTrailingNewline
}
