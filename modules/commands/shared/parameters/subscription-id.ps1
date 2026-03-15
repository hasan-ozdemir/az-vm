# Shared 'subscription-id' command option specification.

function Get-AzVmSharedSubscriptionIdOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'subscription-id' -ShortNames @('s') -TakesValue -Validate {
        param([hashtable]$Options)

        if (-not (Test-AzVmCliOptionPresent -Options $Options -Name 'subscription-id')) {
            return
        }

        $rawValue = [string](Get-AzVmCliOptionText -Options $Options -Name 'subscription-id')
        if ([string]::IsNullOrWhiteSpace([string]$rawValue)) {
            Throw-FriendlyError `
                -Detail "Option '--subscription-id' requires a subscription id value." `
                -Code 2 `
                -Summary "Subscription id value is missing." `
                -Hint "Use '--subscription-id <subscription-guid>', '--subscription-id=<subscription-guid>', or '-s <subscription-guid>'."
        }
    })
}
