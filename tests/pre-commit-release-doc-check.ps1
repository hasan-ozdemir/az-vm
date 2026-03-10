param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Push-Location $RepoRoot
try {
    $stagedText = & git diff --cached --name-only --diff-filter=ACMR
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read staged files from git."
    }

    $stagedFiles = @(
        @($stagedText) |
            ForEach-Object { [string]$_ } |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { $_ -replace '\\', '/' } |
            Select-Object -Unique
    )

    if ($stagedFiles.Count -eq 0) {
        Write-Host "Pre-commit release-doc check skipped: no staged files." -ForegroundColor Yellow
        exit 0
    }

    $exemptFiles = @(
        'CHANGELOG.md',
        'release-notes.md',
        'docs/prompt-history.md'
    )

    $meaningfulFiles = @(
        $stagedFiles |
            Where-Object { $exemptFiles -notcontains [string]$_ }
    )

    if ($meaningfulFiles.Count -eq 0) {
        Write-Host "Pre-commit release-doc check passed: only exempt release-history files are staged." -ForegroundColor Green
        exit 0
    }

    $hasChangelog = $stagedFiles -contains 'CHANGELOG.md'
    $hasReleaseNotes = $stagedFiles -contains 'release-notes.md'
    if (-not $hasChangelog -or -not $hasReleaseNotes) {
        $missing = @()
        if (-not $hasChangelog) { $missing += 'CHANGELOG.md' }
        if (-not $hasReleaseNotes) { $missing += 'release-notes.md' }

        throw ("Repo-changing staged work must include {0}. Staged non-exempt files: {1}" -f ($missing -join ', '), ($meaningfulFiles -join ', '))
    }

    Write-Host "Pre-commit release-doc check passed." -ForegroundColor Green
}
finally {
    Pop-Location
}
