# Create command entry.

function Invoke-AzVmCreateCommand {
    param(
        [hashtable]$Options,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    $runtime = New-AzVmCreateCommandRuntime -Options $Options -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag
    $script:UpdateMode = $false
    $script:RenewMode = [bool]$runtime.RenewMode
    $script:ExecutionMode = if ($script:RenewMode) { 'destructive rebuild' } else { 'default' }
    Invoke-AzVmMain -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -CommandName 'create' -InitialConfigOverrides $runtime.InitialConfigOverrides -ActionPlan $runtime.ActionPlan
}
