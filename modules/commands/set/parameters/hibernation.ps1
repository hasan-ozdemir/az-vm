# 'hibernation' option binding for 'set'.

function Get-AzVmSetHibernationOptionSpecification {
    return (Get-AzVmSharedHibernationOptionSpecification)
}
