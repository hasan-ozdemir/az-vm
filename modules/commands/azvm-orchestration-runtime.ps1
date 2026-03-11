# Compatibility loader for orchestration helpers.

$moduleFiles = @(
    'context/azvm-managed-name-rules.ps1'
    'context/azvm-step1-context.ps1'
    'steps/azvm-vm-security.ps1'
    'steps/azvm-precheck-step.ps1'
    'features/azvm-feature-support.ps1'
    'steps/azvm-resource-group-step.ps1'
    'steps/azvm-network-step.ps1'
    'steps/azvm-vm-deploy-step.ps1'
    'runtime/azvm-vm-details.ps1'
    'runtime/azvm-diagnostics.ps1'
)

foreach ($moduleFile in @($moduleFiles)) {
    $modulePath = Join-Path $PSScriptRoot $moduleFile
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw ("Required module file was not found: {0}" -f $modulePath)
    }

    . $modulePath
}
