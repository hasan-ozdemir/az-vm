# Imported runtime region: test-guest.

















# Handles Get-AzVmConnectionDisplayModel.
function Get-AzVmConnectionDisplayModel {
    param(
        [hashtable]$Context,
        [string]$ManagerUser,
        [string]$AssistantUser,
        [string]$SshPort,
        [switch]$IncludeRdp
    )

    $vmConnectionInfo = Get-AzVmVmDetails -Context $Context
    $publicIP = [string]$vmConnectionInfo.PublicIP
    $vmFqdn = [string]$vmConnectionInfo.VmFqdn

    $sshConnections = @(
        [pscustomobject]@{
            User = $ManagerUser
            Command = ("ssh -p {0} {1}@{2}" -f $SshPort, $ManagerUser, $vmFqdn)
        },
        [pscustomobject]@{
            User = $AssistantUser
            Command = ("ssh -p {0} {1}@{2}" -f $SshPort, $AssistantUser, $vmFqdn)
        }
    )

    $model = [ordered]@{
        PublicIP = $publicIP
        VmFqdn = $vmFqdn
        SshConnections = $sshConnections
    }

    if ($IncludeRdp) {
        $rdpConnections = @(
            [pscustomobject]@{
                User = $ManagerUser
                Username = (".\{0}" -f $ManagerUser)
                Command = ("mstsc /v:{0}:3389" -f $vmFqdn)
            },
            [pscustomobject]@{
                User = $AssistantUser
                Username = (".\{0}" -f $AssistantUser)
                Command = ("mstsc /v:{0}:3389" -f $vmFqdn)
            }
        )
        $model["RdpConnections"] = $rdpConnections
    }

    return $model
}


