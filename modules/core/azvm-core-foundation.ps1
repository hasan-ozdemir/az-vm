# Compatibility loader for core foundation helpers.

$moduleFiles = @(
    'system/azvm-az-cli.ps1'
    'platform/azvm-platform-defaults.ps1'
    'config/azvm-config-resolution.ps1'
    'tasks/azvm-task-catalog.ps1'
    'host/azvm-startup-mirror.ps1'
    'tasks/azvm-task-materialization.ps1'
    'tasks/azvm-ssh-task-runner.ps1'
)

foreach ($moduleFile in @($moduleFiles)) {
    $modulePath = Join-Path $PSScriptRoot $moduleFile
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw ("Required module file was not found: {0}" -f $modulePath)
    }

    . $modulePath
}
