# Shared 'restore-app-state' command option specification.

function Get-AzVmSharedRestoreAppStateOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'restore-app-state')
}
