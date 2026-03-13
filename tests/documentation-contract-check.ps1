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

function Test-ContainsTurkishLetters {
    param(
        [string]$Text
    )

    if ($null -eq $Text) {
        return $false
    }

    $turkishLetters = @([char]0x00E7,[char]0x00C7,[char]0x011F,[char]0x011E,[char]0x0131,[char]0x0130,[char]0x00F6,[char]0x00D6,[char]0x015F,[char]0x015E,[char]0x00FC,[char]0x00DC)
    foreach ($letter in @($turkishLetters)) {
        if ($Text.Contains([string]$letter)) {
            return $true
        }
    }

    return $false
}

$requiredFiles = @(
    'AGENTS.md',
    'README.md',
    'LICENSE',
    'CONTRIBUTING.md',
    'SUPPORT.md',
    'SECURITY.md',
    'CODE_OF_CONDUCT.md',
    'CHANGELOG.md',
    'release-notes.md',
    'roadmap.md',
    'docs\prompt-history.md',
    'tools\enable-git-hooks.ps1',
    'tools\disable-git-hooks.ps1',
    'tests\pre-commit-release-doc-check.ps1',
    '.githooks\pre-commit',
    '.github\workflows\quality-gate.yml',
    '.github\ISSUE_TEMPLATE\bug-report.yml',
    '.github\ISSUE_TEMPLATE\feature-request.yml',
    '.github\ISSUE_TEMPLATE\config.yml',
    '.github\pull_request_template.md'
)

foreach ($relativePath in $requiredFiles) {
    $fullPath = Join-Path $RepoRoot $relativePath
    Assert-True -Condition (Test-Path -LiteralPath $fullPath) -Message ("Required documentation file is missing: {0}" -f $relativePath)
}

$agentsPath = Join-Path $RepoRoot 'AGENTS.md'
$readmePath = Join-Path $RepoRoot 'README.md'
$licensePath = Join-Path $RepoRoot 'LICENSE'
$contributingPath = Join-Path $RepoRoot 'CONTRIBUTING.md'
$supportPath = Join-Path $RepoRoot 'SUPPORT.md'
$securityPath = Join-Path $RepoRoot 'SECURITY.md'
$codeOfConductPath = Join-Path $RepoRoot 'CODE_OF_CONDUCT.md'
$changelogPath = Join-Path $RepoRoot 'CHANGELOG.md'
$releaseNotesPath = Join-Path $RepoRoot 'release-notes.md'
$roadmapPath = Join-Path $RepoRoot 'roadmap.md'
$promptHistoryPath = Join-Path $RepoRoot 'docs\prompt-history.md'
$preCommitCheckPath = Join-Path $RepoRoot 'tests\pre-commit-release-doc-check.ps1'
$preCommitPath = Join-Path $RepoRoot '.githooks\pre-commit'
$workflowPath = Join-Path $RepoRoot '.github\workflows\quality-gate.yml'

$agentsText = Get-Content -LiteralPath $agentsPath -Raw
$readmeText = Get-Content -LiteralPath $readmePath -Raw
$licenseText = Get-Content -LiteralPath $licensePath -Raw
$contributingText = Get-Content -LiteralPath $contributingPath -Raw
$supportText = Get-Content -LiteralPath $supportPath -Raw
$securityText = Get-Content -LiteralPath $securityPath -Raw
$codeOfConductText = Get-Content -LiteralPath $codeOfConductPath -Raw
$changelogText = Get-Content -LiteralPath $changelogPath -Raw
$releaseNotesText = Get-Content -LiteralPath $releaseNotesPath -Raw
$roadmapText = Get-Content -LiteralPath $roadmapPath -Raw
$promptHistoryText = Get-Content -LiteralPath $promptHistoryPath -Raw
$preCommitCheckText = Get-Content -LiteralPath $preCommitCheckPath -Raw
$preCommitText = Get-Content -LiteralPath $preCommitPath -Raw
$workflowText = Get-Content -LiteralPath $workflowPath -Raw

$requiredCommandTokens = @('configure','create','update','list','show','do','task','exec','ssh','rdp','move','resize','set','delete','help')
foreach ($token in $requiredCommandTokens) {
    $commandNeedle = ([string][char]96) + $token + ([string][char]96)
    Assert-True -Condition ($readmeText.Contains($commandNeedle)) -Message ("README.md must mention command '{0}'." -f $token)
}

$requiredDocTokens = @('LICENSE','CONTRIBUTING.md','SUPPORT.md','SECURITY.md','CODE_OF_CONDUCT.md','CHANGELOG.md','release-notes.md','roadmap.md','docs/prompt-history.md')
foreach ($token in $requiredDocTokens) {
    Assert-True -Condition ($readmeText -match [regex]::Escape($token)) -Message ("README.md must mention '{0}'." -f $token)
}

Assert-True -Condition ($readmeText -match 'tools[\\/]+enable-git-hooks\.ps1') -Message 'README.md must mention tools/enable-git-hooks.ps1.'
Assert-True -Condition ($readmeText -match 'tools[\\/]+disable-git-hooks\.ps1') -Message 'README.md must mention tools/disable-git-hooks.ps1.'
Assert-True -Condition ($agentsText -match [regex]::Escape('docs/prompt-history.md')) -Message 'AGENTS.md must mention docs/prompt-history.md.'
Assert-True -Condition ($agentsText -match [regex]::Escape('CONTRIBUTING.md')) -Message 'AGENTS.md must mention CONTRIBUTING.md.'
Assert-True -Condition ($agentsText -match [regex]::Escape('SUPPORT.md')) -Message 'AGENTS.md must mention SUPPORT.md.'
Assert-True -Condition ($agentsText -match [regex]::Escape('SECURITY.md')) -Message 'AGENTS.md must mention SECURITY.md.'
Assert-True -Condition ($agentsText -match [regex]::Escape('CODE_OF_CONDUCT.md')) -Message 'AGENTS.md must mention CODE_OF_CONDUCT.md.'
Assert-True -Condition ($agentsText -match [regex]::Escape('For every completed user prompt that causes code or repo file changes')) -Message 'AGENTS.md must define the mandatory prompt-history rule for repo-changing prompts.'
Assert-True -Condition ($agentsText -match [regex]::Escape('For user prompts that do not cause any repo file changes')) -Message 'AGENTS.md must define the non-mutating prompt-history exception.'
Assert-True -Condition ($agentsText -match [regex]::Escape('If the user replies yes or gives another clearly positive confirmation')) -Message 'AGENTS.md must define the opt-in recording path for non-mutating prompts.'
Assert-True -Condition ($agentsText -match [regex]::Escape('Record prompt-history entries in English.')) -Message 'AGENTS.md must require English-normalized prompt-history entries.'
Assert-True -Condition ($agentsText -match [regex]::Escape('If the original user prompt or assistant summary is not English')) -Message 'AGENTS.md must define translation before prompt-history recording.'
Assert-True -Condition ($agentsText -match [regex]::Escape('Keep maintained repository documentation in English.')) -Message 'AGENTS.md must require English documentation.'
Assert-True -Condition ($agentsText -match [regex]::Escape('Keep app-wide customization, secrets, operator identity, and reusable overrides in `.env`.')) -Message 'AGENTS.md must require app-wide customization to live in .env.'
Assert-True -Condition ($agentsText -match [regex]::Escape('Keep task-only customization in a clearly labeled config block at the top of the owning `vm-init` or `vm-update` script.')) -Message 'AGENTS.md must define the task-local config-block rule.'
Assert-True -Condition ($agentsText -match [regex]::Escape('Do not hard-code personal, company-specific, or secret fallback values in runtime code or shared orchestration paths.')) -Message 'AGENTS.md must forbid hard-coded personal/company/secret fallbacks.'
Assert-True -Condition ($agentsText -match [regex]::Escape('`create` is fresh-only: it creates one new managed resource group plus one new managed VM target and must not be documented or wired as an existing-resource reuse path.')) -Message 'AGENTS.md must define the fresh-only create contract.'
Assert-True -Condition ($agentsText -match [regex]::Escape('`update` is existing-managed-target only: it requires one existing managed resource group plus one existing VM and must not fall through to implicit fresh-create behavior.')) -Message 'AGENTS.md must define the existing-only update contract.'
Assert-True -Condition ($agentsText -match [regex]::Escape('`configure` is the managed target-selection and `.env` synchronization command: it must stay Azure-read-only, select only az-vm-managed targets, and persist only target-derived values from actual Azure state.')) -Message 'AGENTS.md must define the configure target-sync contract.'
Assert-True -Condition ($agentsText -match [regex]::Escape('`list` is the managed inventory command: it must stay Azure-read-only, must not write `.env`, and must expose managed resource listings through `--type` plus optional exact `--group` filtering.')) -Message 'AGENTS.md must define the list inventory contract.'
Assert-True -Condition ($agentsText -match [regex]::Escape('`create --auto` requires an explicit platform plus `--vm-name`, `--vm-region`, and `--vm-size`; `update --auto` requires an explicit platform plus `--group` and `--vm-name`.')) -Message 'AGENTS.md must define the strict auto-mode contract.'
Assert-True -Condition ($agentsText -match [regex]::Escape('Managed resource group ids use a globally increasing `gX` suffix across all managed groups, regardless of region.')) -Message 'AGENTS.md must document global managed resource-group ids.'
Assert-True -Condition ($agentsText -match [regex]::Escape('Managed resource ids use a globally increasing `nX` suffix across all generated managed resources; one generated `nX` must not be reused by another managed resource, even across resource types.')) -Message 'AGENTS.md must document global managed resource ids.'
Assert-True -Condition ($agentsText -match [regex]::Escape('Interactive `create` and `update` are review-first flows: only `group`, `vm-deploy`, `vm-init`, and `vm-update` may ask `yes/no/cancel` review questions.')) -Message 'AGENTS.md must define the four review checkpoints.'
Assert-True -Condition ($agentsText -match [regex]::Escape('`configure` and `vm-summary` must always render without confirmation, even when partial step selection skips interior mutation stages.')) -Message 'AGENTS.md must define the always-visible configure/vm-summary rule.'
Assert-True -Condition ($agentsText -match [regex]::Escape('VM_ENABLE_HIBERNATION')) -Message 'AGENTS.md must mention the shared VM_ENABLE_HIBERNATION config key.'
Assert-True -Condition ($agentsText -match [regex]::Escape('VM_ENABLE_NESTED_VIRTUALIZATION')) -Message 'AGENTS.md must mention the shared VM_ENABLE_NESTED_VIRTUALIZATION config key.'
Assert-True -Condition ($agentsText -match [regex]::Escape('<task-number>-verb-noun-target.ext')) -Message 'AGENTS.md must define the normalized task filename contract.'
Assert-True -Condition ($agentsText -match [regex]::Escape('01-99')) -Message 'AGENTS.md must describe the initial task-number band.'
Assert-True -Condition ($agentsText -match [regex]::Escape('101-999')) -Message 'AGENTS.md must describe the normal task-number band.'
Assert-True -Condition ($agentsText -match [regex]::Escape('1001-9999')) -Message 'AGENTS.md must describe the local task-number band.'
Assert-True -Condition ($agentsText -match [regex]::Escape('10001-10099')) -Message 'AGENTS.md must describe the final task-number band.'
Assert-True -Condition ($agentsText -match [regex]::Escape('Script-local metadata may supply `priority`, `enabled`, `timeout`, and `assets`')) -Message 'AGENTS.md must define the local-only task metadata contract.'
Assert-True -Condition ($agentsText -match [regex]::Escape('Intentionally local-only tasks live under `local/`, are discovered from disk at runtime, and use script metadata only.')) -Message 'AGENTS.md must define the local-only task directory contract.'
Assert-True -Condition ($agentsText -match [regex]::Escape('Intentionally local-only disabled tasks live under `local/disabled/` and remain disabled by location.')) -Message 'AGENTS.md must define the local-only disabled task directory contract.'
Assert-True -Condition ($agentsText -match [regex]::Escape('Local-only task priority precedence is: script metadata `priority` -> filename task number -> deterministic auto-detect in the `1001+` band.')) -Message 'AGENTS.md must define the local-only priority precedence rule.'
Assert-True -Condition ($agentsText -match [regex]::Escape('For tracked tasks that are missing from catalog entries, runtime defaults to `priority=1000`, `enabled=true`, `timeout=180`.')) -Message 'AGENTS.md must document tracked task fallback defaults.'
Assert-True -Condition ($agentsText -match [regex]::Escape('For catalog entries missing `priority`, default to `1000`.')) -Message 'AGENTS.md must document the tracked priority fallback.'
Assert-True -Condition ($agentsText -match [regex]::Escape('Before creating the final commit for a repo-changing prompt, update `CHANGELOG.md` and `release-notes.md`')) -Message 'AGENTS.md must require changelog and release-notes updates before the final commit.'
Assert-True -Condition ($agentsText -match [regex]::Escape('YYYY.M.D.N')) -Message 'AGENTS.md must define the release versioning format.'
Assert-True -Condition ($agentsText -match [regex]::Escape('For live publish or release-readiness claims, require one successful end-to-end live acceptance cycle against the active profile')) -Message 'AGENTS.md must define the live release-acceptance gate.'
Assert-True -Condition ($licenseText -match [regex]::Escape('Commercial licensing requires explicit permission from the developer.')) -Message 'LICENSE must define the commercial licensing rule.'
Assert-True -Condition ($licenseText -match [regex]::Escape('contact the developer')) -Message 'LICENSE must mention the developer contact path.'
Assert-True -Condition ($contributingText -match [regex]::Escape('contact-first')) -Message 'CONTRIBUTING.md must define the contact-first contribution model.'
Assert-True -Condition ($contributingText -match [regex]::Escape('CHANGELOG.md')) -Message 'CONTRIBUTING.md must require release-doc alignment.'
Assert-True -Condition ($supportText -match [regex]::Escape('README.md')) -Message 'SUPPORT.md must route users to the main docs first.'
Assert-True -Condition ($supportText -match [regex]::Escape('SECURITY.md')) -Message 'SUPPORT.md must route sensitive reports to SECURITY.md.'
Assert-True -Condition ($securityText -match [regex]::Escape('do not open a public GitHub issue')) -Message 'SECURITY.md must forbid public vulnerability reporting.'
Assert-True -Condition ($codeOfConductText -match [regex]::Escape('respectful')) -Message 'CODE_OF_CONDUCT.md must define respectful participation.'
Assert-True -Condition ($readmeText -match [regex]::Escape('This repository is distributed under the custom non-commercial license')) -Message 'README.md must summarize the custom non-commercial license.'
Assert-True -Condition ($readmeText -match [regex]::Escape('commercial licensing and sponsorship discussions should be directed to the developer')) -Message 'README.md must mention the sponsorship/contact path.'
Assert-True -Condition ($readmeText -match [regex]::Escape('English-normalized')) -Message 'README.md must describe the English-normalized prompt-history policy.'
Assert-True -Condition ($readmeText -match [regex]::Escape('Task-only constants should stay in the owning task script')) -Message 'README.md must explain the task-local configuration policy.'
Assert-True -Condition ($readmeText -match [regex]::Escape('`-h`, `--help`')) -Message 'README.md must document the -h and --help aliases together.'
Assert-True -Condition ($readmeText -match [regex]::Escape('--user=manager --test')) -Message 'README.md must document the automated --test examples for connection commands.'
Assert-True -Condition ($readmeText -match [regex]::Escape('password-bearing `.env` values are redacted')) -Message 'README.md must document show redaction for password-bearing values.'
Assert-True -Condition ($readmeText -match [regex]::Escape('`create` now stays dedicated to one fresh managed resource group plus one fresh managed VM; `create explicit destructive rebuild flow` remains the explicit destructive rebuild path for that fresh target.')) -Message 'README.md must describe create as fresh-only.'
Assert-True -Condition ($readmeText -match [regex]::Escape('`update` now requires an existing managed resource group and VM, then applies create-or-update operations plus `az vm redeploy` in one guided maintenance flow.')) -Message 'README.md must describe update as existing-managed-target only.'
Assert-True -Condition ($readmeText -match [regex]::Escape('Purpose: select one existing managed VM target, read actual Azure state, and sync target-derived values into `.env`.')) -Message 'README.md must describe configure as a target-sync command.'
Assert-True -Condition ($readmeText -match [regex]::Escape('Purpose: print read-only managed inventory sections for az-vm-tagged resource groups and resources.')) -Message 'README.md must describe list as a read-only inventory command.'
Assert-True -Condition ($readmeText -match [regex]::Escape('Auto `create` requires an explicit platform plus `--vm-name`, `--vm-region`, and `--vm-size`.')) -Message 'README.md must document strict create auto options.'
Assert-True -Condition ($readmeText -match [regex]::Escape('Auto `update` requires an explicit platform plus `--group` and `--vm-name`.')) -Message 'README.md must document strict update auto options.'
Assert-True -Condition ($readmeText -match [regex]::Escape('if `--windows` or `--linux` is omitted, interactive mode asks for the VM OS type first and then scopes size, disk, and image defaults to that selection')) -Message 'README.md must document the interactive create OS prompt.'
Assert-True -Condition ($readmeText -match [regex]::Escape('Interactive `create` and `update` use `yes/no/cancel` review checkpoints only for `group`, `vm-deploy`, `vm-init`, and `vm-update`.')) -Message 'README.md must document the four review checkpoints.'
Assert-True -Condition ($readmeText -match [regex]::Escape('`configure` and `vm-summary` stay visible in both interactive and auto mode, even when partial step selection skips interior stages.')) -Message 'README.md must document the always-visible configure/vm-summary rule.'
Assert-True -Condition ($readmeText -match [regex]::Escape('Managed resource group ids use a global `gX` suffix that increments across all managed groups, regardless of region.')) -Message 'README.md must document global gX naming.'
Assert-True -Condition ($readmeText -match [regex]::Escape('Managed resource ids use a global `nX` suffix that increments across all generated managed resources and is never reused by another managed resource of any type.')) -Message 'README.md must document global nX naming.'
Assert-True -Condition ($readmeText -match [regex]::Escape('`create` never reuses an existing managed resource group or existing managed resource names, and `update` never falls through to an implicit fresh-create path.')) -Message 'README.md must reject create reuse and implicit update create behavior.'
Assert-True -Condition ($readmeText -match [regex]::Escape('`list` gives a read-only managed inventory view across groups and resource types')) -Message 'README.md must explain the list inventory outcome.'
Assert-True -Condition ($readmeText -match [regex]::Escape('`configure` selects one managed VM target and synchronizes actual Azure state into `.env`')) -Message 'README.md must explain the configure synchronization outcome.'
Assert-True -Condition ($readmeText -match [regex]::Escape('Azure single-VM APIs do not expose a separate nested-virtualization toggle')) -Message 'README.md must document the nested virtualization control model accurately.'
Assert-True -Condition ($readmeText -match [regex]::Escape('builtin catalog `initial` tasks, builtin catalog `normal` tasks, local git-untracked tasks from `local/`, then builtin catalog `final` tasks')) -Message 'README.md must document the natural task execution order.'
Assert-True -Condition ($readmeText -match [regex]::Escape('VM_ENABLE_HIBERNATION')) -Message 'README.md must document VM_ENABLE_HIBERNATION.'
Assert-True -Condition ($readmeText -match [regex]::Escape('VM_ENABLE_NESTED_VIRTUALIZATION')) -Message 'README.md must document VM_ENABLE_NESTED_VIRTUALIZATION.'
Assert-True -Condition ($readmeText -match [regex]::Escape('tools/pyssh/ssh_client.py')) -Message 'README.md must document the default PYSSH client path.'
Assert-True -Condition ($readmeText -match [regex]::Escape('.github/workflows/quality-gate.yml')) -Message 'README.md must mention the GitHub Actions quality gate workflow.'
Assert-True -Condition ($readmeText -match [regex]::Escape('### Live Release Acceptance')) -Message 'README.md must define the live release-acceptance section.'
Assert-True -Condition ($readmeText -match [regex]::Escape('confirm `az-vm do --vm-action=status --vm-name=<vm-name>` reports the VM as started')) -Message 'README.md must require a started-state check in the live release gate.'
Assert-True -Condition ($readmeText -match [regex]::Escape('<task-number>-verb-noun-target.ext')) -Message 'README.md must define the normalized task filename contract.'
Assert-True -Condition ($readmeText -match [regex]::Escape('01-99')) -Message 'README.md must describe the initial task-number band.'
Assert-True -Condition ($readmeText -match [regex]::Escape('101-999')) -Message 'README.md must describe the normal task-number band.'
Assert-True -Condition ($readmeText -match [regex]::Escape('1001-9999')) -Message 'README.md must describe the local task-number band.'
Assert-True -Condition ($readmeText -match [regex]::Escape('10001-10099')) -Message 'README.md must describe the final task-number band.'
Assert-True -Condition ($readmeText -match [regex]::Escape('# az-vm-task-meta: {...}')) -Message 'README.md must document the local-only task metadata comment contract.'
Assert-True -Condition ($readmeText -match [regex]::Escape('local-only tasks under `local/` are discovered from disk dynamically and do not consume catalog entries')) -Message 'README.md must document local-only disk discovery.'
Assert-True -Condition ($readmeText -match [regex]::Escape('local-only tasks under `local/disabled/` remain disabled by location')) -Message 'README.md must document local-only disabled placement.'
Assert-True -Condition ($readmeText -match [regex]::Escape('local missing `priority`: script metadata first, then filename task number, then deterministic auto-detect from the `1001+` band')) -Message 'README.md must document local priority precedence.'
Assert-True -Condition ($readmeText -match [regex]::Escape('tracked missing `priority`: default to `1000`')) -Message 'README.md must document the tracked priority fallback.'
Assert-True -Condition ($readmeText -match [regex]::Escape('missing tracked entry entirely: `priority=1000`, `enabled=true`, `timeout=180`')) -Message 'README.md must document the tracked missing-entry fallback.'
Assert-True -Condition ($roadmapText -match [regex]::Escape('business value')) -Message 'roadmap.md must be framed around business value.'
Assert-True -Condition ($preCommitText -match [regex]::Escape('tests/pre-commit-release-doc-check.ps1')) -Message '.githooks/pre-commit must run the release-doc pre-commit check.'
Assert-True -Condition ($preCommitCheckText -match [regex]::Escape('CHANGELOG.md')) -Message 'pre-commit-release-doc-check.ps1 must require CHANGELOG.md.'
Assert-True -Condition ($preCommitCheckText -match [regex]::Escape('release-notes.md')) -Message 'pre-commit-release-doc-check.ps1 must require release-notes.md.'
Assert-True -Condition ($preCommitCheckText -match [regex]::Escape('docs/prompt-history.md')) -Message 'pre-commit-release-doc-check.ps1 must exempt docs/prompt-history.md from recursive release-doc enforcement.'
Assert-True -Condition ($workflowText -match [regex]::Escape('tests\powershell-compatibility-check.ps1')) -Message 'quality-gate.yml must use tests/powershell-compatibility-check.ps1.'
Assert-True -Condition ($workflowText -match [regex]::Escape('tests\az-vm-smoke-tests.ps1')) -Message 'quality-gate.yml must run the non-live smoke contract suite.'
Assert-True -Condition (-not ($workflowText -match [regex]::Escape('tests\powershell-matrix.ps1'))) -Message 'quality-gate.yml must not reference the removed powershell-matrix.ps1 file.'

$legacyTokens = @('SSH_PORT','TASK_OUTCOME_MODE','SERVER_NAME','VM_USER','VM_PASS','NAMING_TEMPLATE_ACTIVE','az-vm config ','substep mode','--single-step','--from-step','--to-step')
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

Assert-True -Condition (-not ($readmeText -match [regex]::Escape('### `group`'))) -Message 'README.md must not document the removed group command.'
Assert-True -Condition (-not ($readmeText -match [regex]::Escape('.\az-vm.cmd group'))) -Message 'README.md must not keep removed group command examples.'
Assert-True -Condition (-not ($agentsText -match [regex]::Escape('Current public commands are: `configure`, `create`, `update`, `group`'))) -Message 'AGENTS.md must not keep the removed group command in the public command list.'

$oldHookInstallerPattern = [regex]::Escape('install-git-hooks.ps1')
Assert-True -Condition (-not ($readmeText -match $oldHookInstallerPattern)) -Message 'README.md must not mention install-git-hooks.ps1.'
Assert-True -Condition (-not ($agentsText -match $oldHookInstallerPattern)) -Message 'AGENTS.md must not mention install-git-hooks.ps1.'
Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'tools\install-git-hooks.ps1'))) -Message 'tools/install-git-hooks.ps1 must not remain in the repository.'

$maintainedEnglishDocs = @(
    $agentsPath,
    $readmePath,
    $licensePath,
    $contributingPath,
    $supportPath,
    $securityPath,
    $codeOfConductPath,
    $changelogPath,
    $releaseNotesPath,
    $roadmapPath,
    $promptHistoryPath
)
foreach ($docPath in @($maintainedEnglishDocs)) {
    $docText = Get-Content -LiteralPath $docPath -Raw
    Assert-True -Condition (-not (Test-ContainsTurkishLetters -Text $docText)) -Message ("Maintained document must stay English-only: {0}" -f [System.IO.Path]::GetFileName($docPath))
}

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
