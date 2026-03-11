# Configure command runtime helpers.

# Handles Get-AzVmConfigPersistenceMap.
function Get-AzVmConfigPersistenceMap {
    param(
        [string]$Platform,
        [hashtable]$Context
    )

    $tcpPortsCsv = [string]$Context.TcpPortsConfiguredCsv
    if ([string]::IsNullOrWhiteSpace([string]$tcpPortsCsv)) {
        $tcpPortsCsv = (@($Context.TcpPorts) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ','
    }
    $vmImageConfigKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey "VM_IMAGE"
    $vmSizeConfigKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey "VM_SIZE"
    $vmDiskSizeConfigKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey "VM_DISK_SIZE_GB"

    $persist = [ordered]@{
        VM_OS_TYPE = [string]$Platform
        AZ_LOCATION = [string]$Context.AzLocation
        RESOURCE_GROUP = [string]$Context.ResourceGroup
        VNET_NAME = [string]$Context.VNET
        SUBNET_NAME = [string]$Context.SUBNET
        NSG_NAME = [string]$Context.NSG
        NSG_RULE_NAME = [string]$Context.NsgRule
        PUBLIC_IP_NAME = [string]$Context.IP
        NIC_NAME = [string]$Context.NIC
        VM_NAME = [string]$Context.VmName
        VM_DISK_NAME = [string]$Context.VmDiskName
        VM_STORAGE_SKU = [string]$Context.VmStorageSku
        VM_SSH_PORT = [string]$Context.SshPort
        VM_RDP_PORT = [string]$Context.RdpPort
        TCP_PORTS = [string]$tcpPortsCsv
    }

    $persist[$vmImageConfigKey] = [string]$Context.VmImage
    $persist[$vmSizeConfigKey] = [string]$Context.VmSize
    $persist[$vmDiskSizeConfigKey] = [string]$Context.VmDiskSize

    return $persist
}

# Handles Save-AzVmConfigToDotEnv.
function Save-AzVmConfigToDotEnv {
    param(
        [string]$EnvFilePath,
        [hashtable]$ConfigBefore,
        [hashtable]$PersistMap
    )

    $before = @{}
    if ($ConfigBefore) {
        foreach ($key in @($ConfigBefore.Keys)) {
            $before[[string]$key] = [string]$ConfigBefore[$key]
        }
    }

    $changes = @()
    foreach ($key in @($PersistMap.Keys)) {
        $name = [string]$key
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $newValue = [string]$PersistMap[$name]
        $oldValue = ''
        if ($before.ContainsKey($name)) {
            $oldValue = [string]$before[$name]
        }

        if ([string]::Equals($oldValue, $newValue, [System.StringComparison]::Ordinal)) {
            continue
        }

        Set-DotEnvValue -Path $EnvFilePath -Key $name -Value $newValue
        $changes += [pscustomobject]@{
            Key = $name
            OldValue = $oldValue
            NewValue = $newValue
        }
    }

    return @($changes)
}
