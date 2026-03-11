# Shared 'perf' command option specification.

function Get-AzVmSharedPerfOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'perf')
}
