# Compatibility loader for shared UI helpers.

$moduleFiles = @(
    'selection/azvm-location-picker.ps1'
    'selection/azvm-sku-picker.ps1'
    'selection/azvm-resource-targets.ps1'
    'show/azvm-show-report.ps1'
    'connection/azvm-lifecycle.ps1'
    'connection/azvm-connection-runtime.ps1'
    'shared/azvm-keyvalue.ps1'
)

foreach ($moduleFile in @($moduleFiles)) {
    $modulePath = Join-Path $PSScriptRoot $moduleFile
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw ("Required module file was not found: {0}" -f $modulePath)
    }

    . $modulePath
}
