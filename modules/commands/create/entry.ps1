# Create command entry.

function Invoke-AzVmCreateCommand {
    param(
        [hashtable]$Options,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag,
        [switch]$AutoMode
    )

    $runtime = New-AzVmCreateCommandRuntime -Options $Options -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -AutoMode:$AutoMode
    $script:UpdateMode = $false
    $script:ExecutionMode = 'default'
    Invoke-AzVmMain -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -CommandName 'create' -Step1OperationName ([string]$runtime.Step1OperationName) -InitialConfigOverrides $runtime.InitialConfigOverrides -ActionPlan $runtime.ActionPlan
}
