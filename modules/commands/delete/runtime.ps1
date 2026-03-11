# Delete command runtime helpers.

function Get-AzVmDeleteCommandRuntime {
    param(
        [hashtable]$Options
    )

    return [pscustomobject]@{
        Options = $Options
    }
}
