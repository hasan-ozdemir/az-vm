# Compatibility loader for run-command task helpers.

$moduleFiles = @(
    'run-command/script.ps1'
    'run-command/parser.ps1'
    'run-command/template.ps1'
    'run-command/runner.ps1'
    'run-command/wait.ps1'
)

foreach ($moduleFile in @($moduleFiles)) {
    $modulePath = Join-Path $PSScriptRoot $moduleFile
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw ("Required module file was not found: {0}" -f $modulePath)
    }

    . $modulePath
}
