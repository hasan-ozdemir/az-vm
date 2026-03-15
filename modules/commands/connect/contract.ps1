# Contract for the 'connect' command.

function Get-AzVmConnectOptionSpecifications {
    return @(
        (Get-AzVmConnectPerfOptionSpecification),
        (Get-AzVmConnectHelpOptionSpecification),
        (Get-AzVmConnectSubscriptionIdOptionSpecification),
        (Get-AzVmConnectGroupOptionSpecification),
        (Get-AzVmConnectVmNameOptionSpecification),
        (Get-AzVmConnectUserOptionSpecification),
        (Get-AzVmConnectTestOptionSpecification),
        (Get-AzVmConnectSshOptionSpecification),
        (Get-AzVmConnectRdpOptionSpecification)
    )
}
