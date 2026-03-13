# Contract for the 'rdp' command.

function Get-AzVmRdpOptionSpecifications {
    return @(
        (Get-AzVmRdpPerfOptionSpecification),
        (Get-AzVmRdpHelpOptionSpecification),
        (Get-AzVmSharedSubscriptionIdOptionSpecification),
        (Get-AzVmRdpGroupOptionSpecification),
        (Get-AzVmRdpVmNameOptionSpecification),
        (Get-AzVmRdpUserOptionSpecification),
        (Get-AzVmRdpTestOptionSpecification)
    )
}
