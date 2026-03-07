param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git command was not found."
}

Push-Location $RepoRoot
try {
    & git config core.hooksPath .githooks
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to configure core.hooksPath."
    }
}
finally {
    Pop-Location
}

Write-Host "Configured native git hooks path: .githooks" -ForegroundColor Green
Write-Host "Hook commands:" -ForegroundColor Cyan
Write-Host "- pre-commit -> tests/run-quality-audit.ps1 -SkipMatrix -SkipLinuxShellSyntax"
Write-Host "- pre-push   -> tests/run-quality-audit.ps1 -SkipLinuxShellSyntax"