# Shared 'test' command option specification.

function Get-AzVmSharedTestOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'test')
}
