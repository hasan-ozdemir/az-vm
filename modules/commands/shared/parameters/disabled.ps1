# Shared 'disabled' command option specification.

function Get-AzVmSharedDisabledOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'disabled')
}
