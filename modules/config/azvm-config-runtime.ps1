# Compatibility loader for config helpers.

$moduleFiles = @(
    'dotenv/azvm-dotenv.ps1'
    'region/azvm-region-codes.ps1'
    'templates/azvm-templates.ps1'
    'naming/azvm-resource-naming.ps1'
)

foreach ($moduleFile in @($moduleFiles)) {
    $modulePath = Join-Path $PSScriptRoot $moduleFile
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw ("Required module file was not found: {0}" -f $modulePath)
    }

    . $modulePath
}
