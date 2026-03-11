# Shared command-contract resolution helpers.

function Get-AzVmCommandOptionSpecifications {
    param(
        [string]$CommandName
    )

    switch ($CommandName) {
        'create' { return @(Get-AzVmCreateOptionSpecifications) }
        'update' { return @(Get-AzVmUpdateOptionSpecifications) }
        'configure' { return @(Get-AzVmConfigureOptionSpecifications) }
        'group' { return @(Get-AzVmGroupOptionSpecifications) }
        'show' { return @(Get-AzVmShowOptionSpecifications) }
        'do' { return @(Get-AzVmDoOptionSpecifications) }
        'task' { return @(Get-AzVmTaskOptionSpecifications) }
        'move' { return @(Get-AzVmMoveOptionSpecifications) }
        'resize' { return @(Get-AzVmResizeOptionSpecifications) }
        'set' { return @(Get-AzVmSetOptionSpecifications) }
        'exec' { return @(Get-AzVmExecOptionSpecifications) }
        'ssh' { return @(Get-AzVmSshOptionSpecifications) }
        'rdp' { return @(Get-AzVmRdpOptionSpecifications) }
        'delete' { return @(Get-AzVmDeleteOptionSpecifications) }
        'help' { return @(Get-AzVmHelpOptionSpecifications) }
        default {
            Throw-FriendlyError -Detail ("Unsupported command '{0}'." -f $CommandName) -Code 2 -Summary "Unknown command." -Hint "Use one command: create | update | configure | group | show | do | task | exec | ssh | rdp | move | resize | set | delete | help."
        }
    }
}

function Assert-AzVmCommandOptions {
    param(
        [string]$CommandName,
        [hashtable]$Options
    )

    $specs = @(Get-AzVmCommandOptionSpecifications -CommandName $CommandName)
    $allowed = @($specs | ForEach-Object { [string]$_.Name })
    foreach ($key in @($Options.Keys)) {
        $optionName = [string]$key
        if ($allowed -notcontains $optionName) {
            Throw-FriendlyError -Detail ("Option '--{0}' is not supported for command '{1}'." -f $optionName, $CommandName) -Code 2 -Summary "Unsupported command option." -Hint ("Use valid options for '{0}' only." -f $CommandName)
        }
    }

    $helpRequested = Get-AzVmCliOptionBool -Options $Options -Name 'help' -DefaultValue $false
    if ($helpRequested -and $CommandName -ne 'help') {
        return
    }

    foreach ($spec in @($specs)) {
        if ($null -ne $spec -and $spec.PSObject.Properties.Match('Validate').Count -gt 0 -and $spec.Validate -is [scriptblock]) {
            & $spec.Validate $Options
        }
    }
}
