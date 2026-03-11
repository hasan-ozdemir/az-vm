# Shared 'hibernation' command option specification.

function Get-AzVmSharedHibernationOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'hibernation')
}
