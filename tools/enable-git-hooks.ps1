param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Ensures the git command is available before mutating repo-local hook settings.
function Assert-GitCommand {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git command was not found."
    }
}

# Reads the current repo-local core.hooksPath value when present.
function Get-RepoHooksPath {
    param(
        [string]$RepositoryRoot
    )

    Push-Location $RepositoryRoot
    try {
        $rawValue = & git config --get core.hooksPath 2>$null
        if ($LASTEXITCODE -ne 0) {
            return ""
        }

        return ([string]$rawValue).Trim()
    }
    finally {
        Pop-Location
    }
}

# Sets the repo-local hooks path to the committed .githooks directory.
function Enable-RepoGitHooks {
    param(
        [string]$RepositoryRoot
    )

    $currentHooksPath = Get-RepoHooksPath -RepositoryRoot $RepositoryRoot
    if ([string]::Equals($currentHooksPath, ".githooks", [System.StringComparison]::Ordinal)) {
        Write-Host "Native git hooks are already enabled: .githooks" -ForegroundColor Green
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($currentHooksPath)) {
        throw ("core.hooksPath is already set to '{0}'. Disable or replace that custom path manually before enabling the repo hooks." -f $currentHooksPath)
    }

    Push-Location $RepositoryRoot
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
    Write-Host "- pre-commit -> tests/code-quality-check.ps1"
    Write-Host "- pre-push   -> tests/code-quality-check.ps1 + tests/bash-syntax-check.ps1 + tests/powershell-compatibility-check.ps1"
}

Assert-GitCommand
Enable-RepoGitHooks -RepositoryRoot $RepoRoot
