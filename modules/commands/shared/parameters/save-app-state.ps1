# Shared 'save-app-state' command option specification.

function Get-AzVmSharedSaveAppStateOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'save-app-state')
}
