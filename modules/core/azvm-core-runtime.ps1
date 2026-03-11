# Compatibility loader for core runtime helpers.

$moduleFiles = @(
    'runtime/azvm-step-runner.ps1'
    'runtime/azvm-errors.ps1'
    'move/azvm-move-cleanup.ps1'
    'cli/azvm-help.ps1'
    'cli/azvm-cli-parse.ps1'
    'runtime/azvm-json-compat.ps1'
    'runtime/azvm-vm-run-command-json.ps1'
    'runtime/azvm-file-output.ps1'
)

foreach ($moduleFile in @($moduleFiles)) {
    $modulePath = Join-Path $PSScriptRoot $moduleFile
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw ("Required module file was not found: {0}" -f $modulePath)
    }

    . $modulePath
}
