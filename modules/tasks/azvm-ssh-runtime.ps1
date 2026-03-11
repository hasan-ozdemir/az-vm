# Compatibility loader for SSH task helpers.

$moduleFiles = @(
    'ssh/tooling.ps1'
    'ssh/assets.ps1'
    'ssh/wait.ps1'
    'ssh/process.ps1'
    'ssh/session.ps1'
    'ssh/protocol.ps1'
    'ssh/runner.ps1'
)

foreach ($moduleFile in @($moduleFiles)) {
    $modulePath = Join-Path $PSScriptRoot $moduleFile
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw ("Required module file was not found: {0}" -f $modulePath)
    }

    . $modulePath
}
