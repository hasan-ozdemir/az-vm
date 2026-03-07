# Imported runtime region: test-guest.

















# Handles Get-AzVmConnectionDisplayModel.
function Get-AzVmConnectionDisplayModel {
    param(
        [hashtable]$Context,
        [string]$ManagerUser,
        [string]$AssistantUser,
        [string]$SshPort,
        [string]$RdpPort = '3389',
        [switch]$IncludeRdp
    )

    $vmConnectionInfo = Get-AzVmVmDetails -Context $Context
    $publicIP = [string]$vmConnectionInfo.PublicIP
    $vmFqdn = [string]$vmConnectionInfo.VmFqdn
    $resolvedHost = if ([string]::IsNullOrWhiteSpace([string]$vmFqdn)) { $publicIP } else { $vmFqdn }

    $sshConnections = @(
        [pscustomobject]@{
            User = $ManagerUser
            Command = ("ssh -p {0} {1}@{2}" -f $SshPort, $ManagerUser, $resolvedHost)
        },
        [pscustomobject]@{
            User = $AssistantUser
            Command = ("ssh -p {0} {1}@{2}" -f $SshPort, $AssistantUser, $resolvedHost)
        }
    )

    $model = [ordered]@{
        PublicIP = $publicIP
        VmFqdn = $vmFqdn
        ConnectionHost = $resolvedHost
        SshConnections = $sshConnections
    }

    if ($IncludeRdp) {
        $rdpConnections = @(
            [pscustomobject]@{
                User = $ManagerUser
                Username = (".\{0}" -f $ManagerUser)
                Command = ("mstsc /v:{0}:{1}" -f $resolvedHost, $RdpPort)
            },
            [pscustomobject]@{
                User = $AssistantUser
                Username = (".\{0}" -f $AssistantUser)
                Command = ("mstsc /v:{0}:{1}" -f $resolvedHost, $RdpPort)
            }
        )
        $model["RdpConnections"] = $rdpConnections
    }

    return $model
}


