# Shared 'quiet' command option specification.

function Get-AzVmSharedQuietOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'quiet' -ShortNames @('q'))
}
