# Connect command runtime helpers.

function Resolve-AzVmConnectMode {
    param(
        [hashtable]$Options
    )

    $sshRequested = Test-AzVmCliOptionPresent -Options $Options -Name 'ssh'
    $rdpRequested = Test-AzVmCliOptionPresent -Options $Options -Name 'rdp'

    if ($sshRequested -and $rdpRequested) {
        Throw-FriendlyError `
            -Detail "Both --ssh and --rdp were provided." `
            -Code 66 `
            -Summary "Connect mode is ambiguous." `
            -Hint "Use exactly one of --ssh or --rdp."
    }

    if ($sshRequested) {
        return 'ssh'
    }
    if ($rdpRequested) {
        return 'rdp'
    }

    Throw-FriendlyError `
        -Detail "Connect command requires one transport selector." `
        -Code 66 `
        -Summary "Connect mode is missing." `
        -Hint "Use az-vm connect --ssh ... or az-vm connect --rdp ...."
}
