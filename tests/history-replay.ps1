param(
    [int]$Days = 2,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$TempRoot = "",
    [switch]$KeepWorktrees
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Resolves the available PowerShell host for replaying checks against worktrees.
function Resolve-PowerShellHost {
    $windowsPowerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($windowsPowerShell) {
        return $windowsPowerShell.Source
    }

    $powerShellCore = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($powerShellCore) {
        return $powerShellCore.Source
    }

    throw "Neither powershell.exe nor pwsh was found."
}

# Resolves the quality-check entrypoint that exists inside the target historical worktree.
function Resolve-WorktreeQualityScript {
    param(
        [string]$WorktreePath
    )

    $candidates = @(
        "tests\code-quality-check.ps1",
        "tests\quality-audit.ps1",
        "tests\run-quality-audit.ps1"
    )

    foreach ($relativePath in $candidates) {
        $fullPath = Join-Path $WorktreePath $relativePath
        if (Test-Path -LiteralPath $fullPath) {
            return $fullPath
        }
    }

    throw "No supported quality-check entrypoint was found in the target worktree."
}

if ($Days -lt 1) {
    $Days = 1
}

if ([string]::IsNullOrWhiteSpace([string]$TempRoot)) {
    $TempRoot = Join-Path $RepoRoot ".tmp\history-replay"
}

if (-not (Test-Path -LiteralPath $TempRoot)) {
    New-Item -Path $TempRoot -ItemType Directory -Force | Out-Null
}

$sinceText = "{0} days ago" -f $Days
$commitList = @(
    git -C $RepoRoot rev-list --since="$sinceText" --reverse HEAD |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
)

if ($commitList.Count -eq 0) {
    Write-Host ("No commits found for the last {0} day(s)." -f $Days) -ForegroundColor Yellow
    exit 0
}

$powerShellHost = Resolve-PowerShellHost

$results = @()
for ($i = 0; $i -lt $commitList.Count; $i++) {
    $commit = [string]$commitList[$i]
    $short = if ($commit.Length -gt 8) { $commit.Substring(0, 8) } else { $commit }
    $worktreePath = Join-Path $TempRoot ("wt-{0:000}-{1}" -f ($i + 1), $short)
    $started = Get-Date
    $passed = $false
    $detail = "ok"

    Write-Host ""
    Write-Host ("[{0}/{1}] replay commit {2}" -f ($i + 1), $commitList.Count, $commit) -ForegroundColor Cyan

    try {
        & git -C $RepoRoot worktree add --detach $worktreePath $commit | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "git worktree add failed."
        }

        $qualityCheckScript = Resolve-WorktreeQualityScript -WorktreePath $worktreePath
        $scriptName = Split-Path -Path $qualityCheckScript -Leaf
        $args = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $qualityCheckScript, "-RepoRoot", $worktreePath)
        if ($scriptName -ne 'code-quality-check.ps1') {
            $args += @("-SkipHelpSmoke", "-SkipMatrix", "-SkipLinuxShellSyntax")
        }

        & $powerShellHost @args
        if ($LASTEXITCODE -ne 0) {
            throw ("quality replay failed with exit code {0} via {1}" -f $LASTEXITCODE, $scriptName)
        }

        $passed = $true
    }
    catch {
        $detail = $_.Exception.Message
    }
    finally {
        if (-not $KeepWorktrees) {
            & git -C $RepoRoot worktree remove --force $worktreePath | Out-Null
        }
    }

    $duration = [int]([DateTime]::UtcNow - $started.ToUniversalTime()).TotalSeconds
    $results += [pscustomobject]@{
        Commit = $commit
        ShortCommit = $short
        Passed = $passed
        DurationSeconds = $duration
        Detail = $detail
    }
}

Write-Host ""
Write-Host "History replay summary:" -ForegroundColor Cyan
$results | ForEach-Object {
    $status = if ($_.Passed) { "PASS" } else { "FAIL" }
    Write-Host ("- [{0}] {1} ({2}s) {3}" -f $status, $_.ShortCommit, $_.DurationSeconds, $_.Detail)
}

$failed = @($results | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host ("Replay failed for {0} commit(s)." -f $failed.Count) -ForegroundColor Red
    exit 1
}
