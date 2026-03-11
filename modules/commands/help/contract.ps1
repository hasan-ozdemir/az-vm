# Contract for the 'help' command.

function Get-AzVmHelpOptionSpecifications {
    return @(
        (Get-AzVmHelpHelpOptionSpecification)
    )
}
