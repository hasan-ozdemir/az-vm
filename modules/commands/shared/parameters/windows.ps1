# Shared 'windows' command option specification.

function Get-AzVmSharedWindowsOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'windows')
}
