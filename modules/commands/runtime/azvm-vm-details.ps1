# VM detail lookup helpers.

# Handles Get-AzVmVmDetails.
function Get-AzVmVmDetails {
    param(
        [hashtable]$Context
    )

    Show-AzVmStepFirstUseValues `
        -StepLabel "VM details lookup" `
        -Context $Context `
        -Keys @("ResourceGroup", "VmName", "AzLocation", "SshPort")

    $vmDetailsJson = Invoke-TrackedAction -Label "az vm show -g $($Context.ResourceGroup) -n $($Context.VmName) -d" -Action {
        $result = az vm show -g $Context.ResourceGroup -n $Context.VmName -d -o json --only-show-errors 2>$null
        Assert-LastExitCode "az vm show -d"
        $result
    }

    $vmDetails = ConvertFrom-JsonCompat -InputObject $vmDetailsJson
    if (-not $vmDetails) {
        throw "VM detail output could not be parsed."
    }

    $publicIP = $vmDetails.publicIps
    $vmFqdn = $vmDetails.fqdns
    $effectiveLocation = [string]$Context.AzLocation
    if ([string]::IsNullOrWhiteSpace([string]$effectiveLocation)) {
        $effectiveLocation = [string]$vmDetails.location
    }
    if ([string]::IsNullOrWhiteSpace($vmFqdn)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$effectiveLocation)) {
            $vmFqdn = "$($Context.VmName).$effectiveLocation.cloudapp.azure.com"
        }
    }

    return [ordered]@{
        VmDetails = $vmDetails
        PublicIP = $publicIP
        VmFqdn = $vmFqdn
    }
}
