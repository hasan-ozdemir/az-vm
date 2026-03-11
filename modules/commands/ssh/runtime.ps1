# Ssh command runtime helpers.

function Get-AzVmSshCommandRuntime {
    param(
        [hashtable]$Options
    )

    return [pscustomobject]@{
        Options = $Options
    }
}
