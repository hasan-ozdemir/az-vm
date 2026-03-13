param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$CommitMessagePath = "",
    [switch]$SkipRepoAudit,
    [switch]$SkipHistoryAudit
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Get-SensitiveContentPatterns {
    param(
        [switch]$IncludeCommitOnlyPatterns
    )

    $patterns = @(
        [pscustomobject]@{
            Name = 'email-address'
            Regex = '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b'
        },
        [pscustomobject]@{
            Name = 'mailto-or-tel-link'
            Regex = ('(?i)\b(?:mail' + 'to:|te' + 'l:)\S+')
        }
    )

    if ($IncludeCommitOnlyPatterns) {
        $patterns += [pscustomobject]@{
            Name = 'concrete-windows-user-home'
            Regex = '(?i)C:\\Users\\(?!<user-home>\\|operator\\|Public\\|Default\\|Default User\\|%USERNAME%\\|\{0\}\\)[^\\/\r\n]+\\'
        }
    }

    return $patterns
}

function Get-TrackedAuditPaths {
    param(
        [string]$RepositoryRoot
    )

    $allowedExtensions = @(
        '.ps1', '.psm1', '.psd1', '.cmd', '.sh', '.py', '.md', '.yml', '.yaml', '.json', '.txt'
    )
    $explicitFileNames = @(
        '.env.example', '.gitignore', '.gitattributes'
    )

    $trackedPaths = @(& git -C $RepositoryRoot ls-files)
    foreach ($trackedPath in @($trackedPaths)) {
        $normalized = ([string]$trackedPath).Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            continue
        }

        if ($normalized.StartsWith('tools/pyssh/.venv/', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $leafName = [System.IO.Path]::GetFileName($normalized)
        $extension = [System.IO.Path]::GetExtension($normalized).ToLowerInvariant()
        if ($allowedExtensions -contains $extension -or
            $explicitFileNames -contains $leafName -or
            $normalized.StartsWith('.githooks/', [System.StringComparison]::OrdinalIgnoreCase)) {
            Join-Path $RepositoryRoot $normalized
        }
    }
}

function Test-LineMatches {
    param(
        [string]$Text,
        [string]$Regex
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return [regex]::IsMatch($Text, $Regex)
}

function Get-TextFindings {
    param(
        [string]$Label,
        [string[]]$Lines,
        [object[]]$Patterns
    )

    $findings = @()
    $lineNumber = 0
    foreach ($line in @($Lines)) {
        $lineNumber++
        foreach ($pattern in @($Patterns)) {
            if (Test-LineMatches -Text ([string]$line) -Regex ([string]$pattern.Regex)) {
                $findings += ("{0}:{1}: matched {2}" -f $Label, $lineNumber, [string]$pattern.Name)
            }
        }
    }

    return @($findings)
}

function Assert-NoSensitiveMatchesInRepoFiles {
    param(
        [string]$RepositoryRoot
    )

    $patterns = @(Get-SensitiveContentPatterns)
    $findings = @()
    foreach ($path in @(Get-TrackedAuditPaths -RepositoryRoot $RepositoryRoot)) {
        $lines = @(Get-Content -LiteralPath $path -ErrorAction Stop)
        $findings += @(Get-TextFindings -Label $path -Lines $lines -Patterns $patterns)
    }

    if (@($findings).Count -gt 0) {
        throw ("Sensitive-content audit found tracked text matches: {0}" -f ((@($findings) | Select-Object -First 10) -join '; '))
    }
}

function Assert-EnvExampleSensitivePlaceholders {
    param(
        [string]$RepositoryRoot
    )

    $envExamplePath = Join-Path $RepositoryRoot '.env.example'
    if (-not (Test-Path -LiteralPath $envExamplePath)) {
        throw ".env.example was not found."
    }

    $envMap = @{}
    foreach ($line in @(Get-Content -LiteralPath $envExamplePath -ErrorAction Stop)) {
        if ($line -match '^\s*#' -or -not ($line -match '=')) {
            continue
        }

        $parts = $line -split '=', 2
        $key = ([string]$parts[0]).Trim()
        $value = if ($parts.Count -gt 1) { [string]$parts[1] } else { '' }
        $envMap[$key] = $value.Trim()
    }

    if ([string]$envMap['VM_ADMIN_PASS'] -ne '<CHANGE_ME_STRONG_ADMIN_PASSWORD>') {
        throw ".env.example must keep VM_ADMIN_PASS as the committed placeholder."
    }
    if ([string]$envMap['VM_ASSISTANT_PASS'] -ne '<CHANGE_ME_STRONG_ASSISTANT_PASSWORD>') {
        throw ".env.example must keep VM_ASSISTANT_PASS as the committed placeholder."
    }
    if ([string]$envMap['employee_email_address'] -ne '<email>') {
        throw ".env.example must keep employee_email_address as the committed placeholder."
    }
    if ([string]$envMap['employee_full_name'] -ne '<person-name>') {
        throw ".env.example must keep employee_full_name as the committed placeholder."
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$envMap['azure_subscription_id'])) {
        throw ".env.example must not commit a concrete azure_subscription_id value."
    }
}

function Assert-NoSensitiveMatchesInReachableCommitMessages {
    param(
        [string]$RepositoryRoot
    )

    $patterns = @(Get-SensitiveContentPatterns -IncludeCommitOnlyPatterns)
    $messageText = [string](& git -C $RepositoryRoot log --all --format=%B)
    $findings = @()
    foreach ($pattern in @($patterns)) {
        if (Test-LineMatches -Text $messageText -Regex ([string]$pattern.Regex)) {
            $findings += [string]$pattern.Name
        }
    }

    if (@($findings).Count -gt 0) {
        throw ("Sensitive-content audit found reachable commit-message matches: {0}" -f ((@($findings) | Sort-Object -Unique) -join ', '))
    }
}

function Assert-NoSensitiveMatchesInCommitMessageFile {
    param(
        [string]$MessagePath
    )

    if ([string]::IsNullOrWhiteSpace($MessagePath)) {
        return
    }
    if (-not (Test-Path -LiteralPath $MessagePath)) {
        throw ("Commit message file was not found: {0}" -f $MessagePath)
    }

    $patterns = @(Get-SensitiveContentPatterns -IncludeCommitOnlyPatterns)
    $lines = @(Get-Content -LiteralPath $MessagePath -ErrorAction Stop | Where-Object { -not ([string]$_).StartsWith('#') })
    $findings = @(Get-TextFindings -Label $MessagePath -Lines $lines -Patterns $patterns)
    if (@($findings).Count -gt 0) {
        throw ("Sensitive-content audit found commit-message matches: {0}" -f ((@($findings) | Select-Object -First 10) -join '; '))
    }
}

if (-not $SkipRepoAudit) {
    Assert-NoSensitiveMatchesInRepoFiles -RepositoryRoot $RepoRoot
    Assert-EnvExampleSensitivePlaceholders -RepositoryRoot $RepoRoot
}

if (-not $SkipHistoryAudit) {
    Assert-NoSensitiveMatchesInReachableCommitMessages -RepositoryRoot $RepoRoot
}

if (-not [string]::IsNullOrWhiteSpace($CommitMessagePath)) {
    Assert-NoSensitiveMatchesInCommitMessageFile -MessagePath $CommitMessagePath
}

Write-Host 'Sensitive-content checks passed.' -ForegroundColor Green
