param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    [int]$TopEntries = 5,
    [double]$MinimumReportSizeMb = 5,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Initialize-AppStateAuditZipSupport {
    if (-not ([System.Management.Automation.PSTypeName]'System.IO.Compression.ZipArchive').Type) {
        Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
        Add-Type -AssemblyName 'System.IO.Compression' -ErrorAction SilentlyContinue
    }
}

function Get-AppStateAuditZipPaths {
    param([string]$RepositoryRoot)

    $roots = @(
        'windows\init\app-states',
        'windows\update\app-states',
        'linux\init\app-states',
        'linux\update\app-states'
    )

    foreach ($relativeRoot in @($roots)) {
        $fullRoot = Join-Path $RepositoryRoot $relativeRoot
        if (-not (Test-Path -LiteralPath $fullRoot)) {
            continue
        }

        foreach ($zipPath in @(Get-ChildItem -LiteralPath $fullRoot -Recurse -Filter 'app-state.zip' -File -ErrorAction SilentlyContinue | Sort-Object FullName)) {
            if ($null -ne $zipPath) {
                $zipPath.FullName
            }
        }
    }
}

function Convert-AppStateAuditPathToStageLabel {
    param(
        [string]$RepositoryRoot,
        [string]$ZipPath
    )

    $relative = [string]$ZipPath.Substring($RepositoryRoot.TrimEnd('\').Length).TrimStart('\')
    $parts = @($relative -split '[\\/]')
    if ($parts.Count -lt 4) {
        return ''
    }

    return ('{0}/{1}' -f [string]$parts[0], [string]$parts[1])
}

function Get-AppStateAuditReport {
    param(
        [string]$RepositoryRoot,
        [string]$ZipPath,
        [int]$TopCount
    )

    Initialize-AppStateAuditZipSupport

    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        $manifest = $null
        $manifestEntry = @($archive.Entries | Where-Object { [string]::Equals([string]$_.FullName, 'app-state.manifest.json', [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
        if ($null -ne $manifestEntry) {
            $reader = New-Object System.IO.StreamReader($manifestEntry.Open())
            try {
                $manifestText = [string]$reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$manifestText)) {
                $manifest = ConvertFrom-Json -InputObject $manifestText -ErrorAction SilentlyContinue
            }
        }

        $taskName = ''
        if ($null -ne $manifest -and $manifest.PSObject.Properties.Match('taskName').Count -gt 0) {
            $taskName = [string]$manifest.taskName
        }
        if ([string]::IsNullOrWhiteSpace([string]$taskName)) {
            $taskName = [System.IO.Path]::GetFileName((Split-Path -Path $ZipPath -Parent))
        }

        $foreignTargets = New-Object 'System.Collections.Generic.List[string]'
        foreach ($collectionName in @('profileDirectories', 'profileFiles', 'registryImports')) {
            foreach ($entry in @($manifest.$collectionName)) {
                if ($null -eq $entry -or $entry.PSObject.Properties.Match('targetProfiles').Count -lt 1) {
                    continue
                }

                foreach ($targetProfile in @($entry.targetProfiles)) {
                    $normalized = if ($null -eq $targetProfile) { '' } else { [string]$targetProfile }
                    if ([string]::IsNullOrWhiteSpace([string]$normalized)) {
                        continue
                    }
                    $normalized = $normalized.Trim().ToLowerInvariant()
                    if ($normalized -in @('manager', 'assistant')) {
                        continue
                    }
                    if ($foreignTargets -notcontains $normalized) {
                        $foreignTargets.Add($normalized) | Out-Null
                    }
                }
            }
        }

        $largestEntries = @(
            $archive.Entries |
                Sort-Object Length -Descending |
                Select-Object -First $TopCount |
                ForEach-Object {
                    [pscustomobject]@{
                        Path = [string]$_.FullName
                        SizeMb = [math]::Round(([double]$_.Length / 1MB), 2)
                    }
                }
        )

        return [pscustomobject]@{
            TaskName = [string]$taskName
            Stage = Convert-AppStateAuditPathToStageLabel -RepositoryRoot $RepositoryRoot -ZipPath $ZipPath
            ZipPath = [string]$ZipPath
            SizeMb = [math]::Round(((Get-Item -LiteralPath $ZipPath).Length / 1MB), 2)
            ForeignTargets = @($foreignTargets.ToArray())
            LargestEntries = @($largestEntries)
        }
    }
    finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
    }
}

$zipPaths = @(Get-AppStateAuditZipPaths -RepositoryRoot $RepoRoot)
if (@($zipPaths).Count -lt 1) {
    Write-Host 'No app-state zip payloads were found.'
    return
}

$reports = @(
    foreach ($zipPath in @($zipPaths)) {
        Get-AppStateAuditReport -RepositoryRoot $RepoRoot -ZipPath $zipPath -TopCount $TopEntries
    }
) | Sort-Object SizeMb -Descending

foreach ($report in @($reports)) {
    Write-Host ("[{0}] {1} => {2} MB" -f [string]$report.Stage, [string]$report.TaskName, [string]$report.SizeMb)
    if (@($report.ForeignTargets).Count -gt 0) {
        Write-Host ("  foreign-targets: {0}" -f ((@($report.ForeignTargets) | Sort-Object) -join ', '))
    }

    if ([double]$report.SizeMb -ge [double]$MinimumReportSizeMb) {
        foreach ($entry in @($report.LargestEntries)) {
            Write-Host ("  top-entry: {0} => {1} MB" -f [string]$entry.Path, [string]$entry.SizeMb)
        }
    }
}

if ($PassThru) {
    $reports
}
