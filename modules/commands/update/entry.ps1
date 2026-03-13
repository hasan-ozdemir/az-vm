# Update command entry.

function Invoke-AzVmUpdateCommand {
    param(
        [hashtable]$Options,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag,
        [switch]$AutoMode
    )

    $runtime = New-AzVmUpdateCommandRuntime -Options $Options -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -AutoMode:$AutoMode
    $script:UpdateMode = $true
    $script:ExecutionMode = 'update'
    Invoke-AzVmMain -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -CommandName 'update' -InitialConfigOverrides $runtime.InitialConfigOverrides -ActionPlan $runtime.ActionPlan
}
