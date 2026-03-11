# Move command entry.

# Handles Invoke-AzVmMoveCommand.
function Invoke-AzVmMoveCommand {
    param(
        [hashtable]$Options,
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    if (Test-AzVmCliOptionPresent -Options $Options -Name 'vm-size') {
        Throw-FriendlyError `
            -Detail "Option '--vm-size' is not supported with move command." `
            -Code 62 `
            -Summary "Unsupported option for move command." `
            -Hint "Use resize command for VM size updates."
    }

    $forwardOptions = Copy-AzVmOptionsMap -Source $Options
    if (-not (Test-AzVmCliOptionPresent -Options $forwardOptions -Name 'vm-region')) {
        $forwardOptions['vm-region'] = ''
    }

    $regionValue = [string](Get-AzVmCliOptionText -Options $forwardOptions -Name 'vm-region')
    $effectiveAutoMode = $AutoMode -or (-not [string]::IsNullOrWhiteSpace([string]$regionValue))
    Invoke-AzVmChangeCommand -Options $forwardOptions -AutoMode:$effectiveAutoMode -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -OperationLabel 'move'
}
