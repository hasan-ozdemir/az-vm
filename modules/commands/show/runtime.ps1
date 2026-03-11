# Show command runtime helpers.

function Get-AzVmShowCommandRuntime {
    param(
        [hashtable]$Options
    )

    return [pscustomobject]@{
        Options = $Options
    }
}
