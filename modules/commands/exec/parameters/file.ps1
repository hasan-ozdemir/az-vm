# 'file' option binding for 'exec'.

function Get-AzVmExecFileOptionSpecification {
    return (New-AzVmCommandOptionSpecification -Name 'file' -ShortNames @('f') -TakesValue)
}
