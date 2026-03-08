param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$requiredFiles = @(
    'AGENTS.md',
    'README.md',
    'CHANGELOG.md',
    'release-notes.md',
    'roadmap.md',
    'docs\prompt-history.md',
    'tools\enable-git-hooks.ps1',
    'tools\disable-git-hooks.ps1'
)

foreach ($relativePath in $requiredFiles) {
    $fullPath = Join-Path $RepoRoot $relativePath
    Assert-True -Condition (Test-Path -LiteralPath $fullPath) -Message ("Required documentation file is missing: {0}" -f $relativePath)
}

$agentsPath = Join-Path $RepoRoot 'AGENTS.md'
$readmePath = Join-Path $RepoRoot 'README.md'
$changelogPath = Join-Path $RepoRoot 'CHANGELOG.md'
$releaseNotesPath = Join-Path $RepoRoot 'release-notes.md'
$promptHistoryPath = Join-Path $RepoRoot 'docs\prompt-history.md'

$agentsText = Get-Content -LiteralPath $agentsPath -Raw
$readmeText = Get-Content -LiteralPath $readmePath -Raw
$changelogText = Get-Content -LiteralPath $changelogPath -Raw
$releaseNotesText = Get-Content -LiteralPath $releaseNotesPath -Raw
$promptHistoryText = Get-Content -LiteralPath $promptHistoryPath -Raw

$requiredCommandTokens = @('configure','create','update','group','show','do','exec','ssh','rdp','move','resize','set','delete','help')
foreach ($token in $requiredCommandTokens) {
    $commandNeedle = ([string][char]96) + $token + ([string][char]96)
    Assert-True -Condition ($readmeText.Contains($commandNeedle)) -Message ("README.md must mention command '{0}'." -f $token)
}

$requiredDocTokens = @('CHANGELOG.md','release-notes.md','roadmap.md','docs/prompt-history.md')
foreach ($token in $requiredDocTokens) {
    Assert-True -Condition ($readmeText -match [regex]::Escape($token)) -Message ("README.md must mention '{0}'." -f $token)
}

Assert-True -Condition ($readmeText -match 'tools[\\/]+enable-git-hooks\.ps1') -Message 'README.md must mention tools/enable-git-hooks.ps1.'
Assert-True -Condition ($readmeText -match 'tools[\\/]+disable-git-hooks\.ps1') -Message 'README.md must mention tools/disable-git-hooks.ps1.'
Assert-True -Condition ($agentsText -match [regex]::Escape('docs/prompt-history.md')) -Message 'AGENTS.md must mention docs/prompt-history.md.'
Assert-True -Condition ($agentsText -match [regex]::Escape('For every completed user prompt that causes code or repo file changes')) -Message 'AGENTS.md must define the mandatory prompt-history rule for repo-changing prompts.'
Assert-True -Condition ($agentsText -match [regex]::Escape('For user prompts that do not cause any repo file changes')) -Message 'AGENTS.md must define the non-mutating prompt-history exception.'
Assert-True -Condition ($agentsText -match [regex]::Escape('If the user replies yes or gives another clearly positive confirmation')) -Message 'AGENTS.md must define the opt-in recording path for non-mutating prompts.'
Assert-True -Condition ($agentsText -match [regex]::Escape('YYYY.M.D.N')) -Message 'AGENTS.md must define the release versioning format.'

$legacyTokens = @('SSH_PORT','TASK_OUTCOME_MODE','SERVER_NAME','VM_USER','VM_PASS','NAMING_TEMPLATE_ACTIVE','az-vm config ','substep mode')
foreach ($legacyToken in $legacyTokens) {
    if ($legacyToken -match '^[A-Z0-9_]+$') {
        $pattern = ('(?<![A-Za-z0-9_]){0}(?![A-Za-z0-9_])' -f [regex]::Escape($legacyToken))
    }
    else {
        $pattern = [regex]::Escape($legacyToken)
    }

    Assert-True -Condition (-not ($readmeText -match $pattern)) -Message ("README.md must not contain legacy token '{0}'." -f $legacyToken)
    Assert-True -Condition (-not ($agentsText -match $pattern)) -Message ("AGENTS.md must not contain legacy token '{0}'." -f $legacyToken)
}

$oldHookInstallerPattern = [regex]::Escape('install-git-hooks.ps1')
Assert-True -Condition (-not ($readmeText -match $oldHookInstallerPattern)) -Message 'README.md must not mention install-git-hooks.ps1.'
Assert-True -Condition (-not ($agentsText -match $oldHookInstallerPattern)) -Message 'AGENTS.md must not mention install-git-hooks.ps1.'
Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'tools\install-git-hooks.ps1'))) -Message 'tools/install-git-hooks.ps1 must not remain in the repository.'

$versionHeaderPattern = '(?m)^## \[(\d{4}\.\d{1,2}\.\d{1,2}\.(\d+))\] - \d{4}-\d{2}-\d{2}$'
$changelogMatches = [regex]::Matches($changelogText, $versionHeaderPattern)
Assert-True -Condition ($changelogMatches.Count -gt 0) -Message 'CHANGELOG.md must contain versioned headings.'

$currentCommitCount = [int](& git -C $RepoRoot rev-list --count HEAD)
$allowedCurrentCounts = @($currentCommitCount, ($currentCommitCount + 1))
$topVersionCount = [int]$changelogMatches[0].Groups[2].Value
Assert-True -Condition ($allowedCurrentCounts -contains $topVersionCount) -Message ("Top changelog version count must match HEAD or HEAD+1. Actual: {0}; allowed: {1}" -f $topVersionCount, ($allowedCurrentCounts -join ', '))

$releaseHeaderMatch = [regex]::Match($releaseNotesText, '(?m)^## Release (\d{4}\.\d{1,2}\.\d{1,2}\.(\d+)) - \d{4}-\d{2}-\d{2}$')
Assert-True -Condition $releaseHeaderMatch.Success -Message 'release-notes.md must contain a versioned release heading.'
$releaseVersionCount = [int]$releaseHeaderMatch.Groups[2].Value
Assert-True -Condition ($topVersionCount -eq $releaseVersionCount) -Message 'CHANGELOG.md and release-notes.md must use the same current version count.'

$userPromptCount = ([regex]::Matches($promptHistoryText, [regex]::Escape('**User Prompt**'))).Count
$assistantSummaryCount = ([regex]::Matches($promptHistoryText, [regex]::Escape('**Assistant Summary**'))).Count
Assert-True -Condition ($userPromptCount -gt 0) -Message 'docs/prompt-history.md must contain at least one user prompt entry.'
Assert-True -Condition ($assistantSummaryCount -gt 0) -Message 'docs/prompt-history.md must contain at least one assistant summary entry.'
Assert-True -Condition ($userPromptCount -eq $assistantSummaryCount) -Message 'docs/prompt-history.md must keep user prompt and assistant summary counts aligned.'
Assert-True -Condition (-not ($promptHistoryText -match [regex]::Escape('No final summary was recorded for this turn.'))) -Message 'docs/prompt-history.md must not contain incomplete summary placeholders.'

Write-Host 'Documentation contract checks passed.' -ForegroundColor Green
