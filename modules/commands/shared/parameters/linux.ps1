# Shared 'linux' command option specification.

function Get-AzVmSharedLinuxOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'linux')
}
