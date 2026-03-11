# Rdp command runtime helpers.

function Get-AzVmRdpCommandRuntime {
    param(
        [hashtable]$Options
    )

    return [pscustomobject]@{
        Options = $Options
    }
}
