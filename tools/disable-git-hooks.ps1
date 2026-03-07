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

# Removes the repo-local .githooks setting without touching unrelated custom hook paths.
function Disable-RepoGitHooks {
    param(
        [string]$RepositoryRoot
    )

    $currentHooksPath = Get-RepoHooksPath -RepositoryRoot $RepositoryRoot
    if ([string]::IsNullOrWhiteSpace($currentHooksPath)) {
        Write-Host "Native git hooks are already disabled." -ForegroundColor Green
        return
    }

    if (-not [string]::Equals($currentHooksPath, ".githooks", [System.StringComparison]::Ordinal)) {
        Write-Host ("core.hooksPath is set to '{0}', not '.githooks'. Leaving that custom path untouched." -f $currentHooksPath) -ForegroundColor Yellow
        return
    }

    Push-Location $RepositoryRoot
    try {
        & git config --unset core.hooksPath
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to unset core.hooksPath."
        }
    }
    finally {
        Pop-Location
    }

    Write-Host "Disabled native git hooks for this repository." -ForegroundColor Green
}

Assert-GitCommand
Disable-RepoGitHooks -RepositoryRoot $RepoRoot
