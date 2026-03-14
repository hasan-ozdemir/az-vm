function ConvertTo-AzVmShortcutLauncherBase64 {
    param([string]$Value)

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    return [Convert]::ToBase64String($bytes)
}

function ConvertFrom-AzVmShortcutLauncherBase64 {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return ''
    }

    try {
        $bytes = [Convert]::FromBase64String([string]$Value)
        return [string][System.Text.Encoding]::UTF8.GetString($bytes)
    }
    catch {
        return ''
    }
}

function Get-AzVmShortcutLauncherRoot {
    param([string]$Subdirectory = 'public-desktop')

    $root = 'C:\ProgramData\az-vm\shortcut-launchers'
    if ([string]::IsNullOrWhiteSpace([string]$Subdirectory)) {
        return $root
    }

    return (Join-Path $root $Subdirectory)
}

function Get-AzVmShortcutLauncherFilePath {
    param(
        [string]$ShortcutName,
        [string]$Subdirectory = 'public-desktop'
    )

    $safeName = ([regex]::Replace(([string]$ShortcutName).ToLowerInvariant(), '[^a-z0-9]+', '-')).Trim('-')
    if ([string]::IsNullOrWhiteSpace([string]$safeName)) {
        $safeName = 'shortcut'
    }

    return (Join-Path (Get-AzVmShortcutLauncherRoot -Subdirectory $Subdirectory) ($safeName + '.cmd'))
}

function Get-AzVmShortcutEffectiveCommandText {
    param(
        [string]$TargetPath,
        [string]$Arguments = ''
    )

    $targetText = [string]$TargetPath
    $argumentsText = [string]$Arguments
    if ([string]::IsNullOrWhiteSpace([string]$targetText)) {
        return ''
    }

    if ([string]::IsNullOrWhiteSpace([string]$argumentsText)) {
        return [string]$targetText
    }

    return ('{0} {1}' -f [string]$targetText, [string]$argumentsText).Trim()
}

function Test-AzVmShortcutNeedsManagedLauncher {
    param(
        [string]$TargetPath,
        [string]$Arguments = '',
        [int]$Threshold = 259
    )

    if ($Threshold -lt 1) {
        $Threshold = 1
    }

    $effectiveCommandText = Get-AzVmShortcutEffectiveCommandText -TargetPath $TargetPath -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace([string]$effectiveCommandText)) {
        return $false
    }

    return ($effectiveCommandText.Length -gt $Threshold)
}

function Get-AzVmShortcutLauncherInvocationArguments {
    param([string]$LauncherPath)

    if ([string]::IsNullOrWhiteSpace([string]$LauncherPath)) {
        return ''
    }

    return ('/c "{0}"' -f [string]$LauncherPath)
}

function Write-AzVmShortcutLauncherFile {
    param(
        [string]$LauncherPath,
        [string]$TargetPath,
        [string]$Arguments = '',
        [string]$WorkingDirectory = ''
    )

    if ([string]::IsNullOrWhiteSpace([string]$LauncherPath)) {
        throw 'LauncherPath is required.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$TargetPath)) {
        throw 'TargetPath is required for shortcut launcher generation.'
    }

    $launcherDirectory = Split-Path -Path $LauncherPath -Parent
    if (-not (Test-Path -LiteralPath $launcherDirectory)) {
        New-Item -Path $launcherDirectory -ItemType Directory -Force | Out-Null
    }

    $effectiveTargetPath = [string]$TargetPath
    $effectiveArguments = [string]$Arguments
    $effectiveWorkingDirectory = [string]$WorkingDirectory
    if ([string]::IsNullOrWhiteSpace([string]$effectiveWorkingDirectory)) {
        $effectiveWorkingDirectory = [string](Split-Path -Path $effectiveTargetPath -Parent)
    }

    $quotedTarget = '"{0}"' -f $effectiveTargetPath
    $commandLine = if ([string]::IsNullOrWhiteSpace([string]$effectiveArguments)) {
        $quotedTarget
    }
    else {
        ('{0} {1}' -f $quotedTarget, [string]$effectiveArguments).Trim()
    }

    $launcherLines = New-Object 'System.Collections.Generic.List[string]'
    [void]$launcherLines.Add('@echo off')
    [void]$launcherLines.Add('setlocal')
    [void]$launcherLines.Add(':: az-vm-shortcut-launcher=1')
    [void]$launcherLines.Add((':: az-vm-target-b64={0}' -f (ConvertTo-AzVmShortcutLauncherBase64 -Value $effectiveTargetPath)))
    [void]$launcherLines.Add((':: az-vm-arguments-b64={0}' -f (ConvertTo-AzVmShortcutLauncherBase64 -Value $effectiveArguments)))
    [void]$launcherLines.Add((':: az-vm-working-directory-b64={0}' -f (ConvertTo-AzVmShortcutLauncherBase64 -Value $effectiveWorkingDirectory)))
    if (-not [string]::IsNullOrWhiteSpace([string]$effectiveWorkingDirectory)) {
        [void]$launcherLines.Add(('cd /d "{0}"' -f $effectiveWorkingDirectory))
    }
    [void]$launcherLines.Add($commandLine)
    [void]$launcherLines.Add('endlocal')

    Set-Content -LiteralPath $LauncherPath -Value $launcherLines -Encoding ASCII
    return [string]$LauncherPath
}

function Test-AzVmShortcutLauncherFile {
    param([string]$LauncherPath)

    if ([string]::IsNullOrWhiteSpace([string]$LauncherPath) -or -not (Test-Path -LiteralPath $LauncherPath)) {
        return $false
    }

    try {
        $firstLine = [string](Get-Content -LiteralPath $LauncherPath -TotalCount 3 -ErrorAction Stop | Select-Object -Skip 2 -First 1)
        return [string]::Equals($firstLine.Trim(), ':: az-vm-shortcut-launcher=1', [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Get-AzVmShortcutLauncherMetadata {
    param([string]$LauncherPath)

    if (-not (Test-AzVmShortcutLauncherFile -LauncherPath $LauncherPath)) {
        return $null
    }

    try {
        $lines = @(Get-Content -LiteralPath $LauncherPath -ErrorAction Stop)
    }
    catch {
        return $null
    }

    $targetText = ''
    $argumentsText = ''
    $workingDirectoryText = ''
    foreach ($line in @($lines)) {
        if ([string]$line -like ':: az-vm-target-b64=*') {
            $targetText = ConvertFrom-AzVmShortcutLauncherBase64 -Value ([string]$line.Substring(':: az-vm-target-b64='.Length))
            continue
        }
        if ([string]$line -like ':: az-vm-arguments-b64=*') {
            $argumentsText = ConvertFrom-AzVmShortcutLauncherBase64 -Value ([string]$line.Substring(':: az-vm-arguments-b64='.Length))
            continue
        }
        if ([string]$line -like ':: az-vm-working-directory-b64=*') {
            $workingDirectoryText = ConvertFrom-AzVmShortcutLauncherBase64 -Value ([string]$line.Substring(':: az-vm-working-directory-b64='.Length))
        }
    }

    return [pscustomobject]@{
        LauncherPath = [string]$LauncherPath
        TargetPath = [string]$targetText
        Arguments = [string]$argumentsText
        WorkingDirectory = [string]$workingDirectoryText
    }
}

function Get-AzVmShortcutLauncherPathFromInvocation {
    param(
        [string]$TargetPath,
        [string]$Arguments
    )

    $targetText = [string]$TargetPath
    if ([string]::IsNullOrWhiteSpace([string]$targetText)) {
        return ''
    }

    $targetLeaf = [System.IO.Path]::GetFileName([string]$targetText)
    if (-not [string]::Equals($targetLeaf, 'cmd.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
        return ''
    }

    $argumentsText = [string][Environment]::ExpandEnvironmentVariables([string]$Arguments)
    if ([string]::IsNullOrWhiteSpace([string]$argumentsText)) {
        return ''
    }

    foreach ($pattern in @(
        '^(?i)/(?:c|k)\s+"([^"]+\.cmd)"$',
        '^(?i)/(?:c|k)\s+call\s+"([^"]+\.cmd)"$',
        '^(?i)/(?:c|k)\s+("?[^"\s]+\.cmd"?)$'
    )) {
        $match = [regex]::Match($argumentsText.Trim(), $pattern)
        if (-not $match.Success) {
            continue
        }

        $candidate = [string]$match.Groups[1].Value.Trim('"', ' ')
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }

        $expandedCandidate = [Environment]::ExpandEnvironmentVariables($candidate)
        if (Test-AzVmShortcutLauncherFile -LauncherPath $expandedCandidate) {
            return [string]$expandedCandidate
        }

        $launcherRoot = Get-AzVmShortcutLauncherRoot
        if (-not [string]::IsNullOrWhiteSpace([string]$launcherRoot) -and
            $expandedCandidate.StartsWith($launcherRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([System.IO.Path]::GetExtension([string]$expandedCandidate), '.cmd', [System.StringComparison]::OrdinalIgnoreCase)) {
            return [string]$expandedCandidate
        }
    }

    return ''
}

function Get-AzVmShortcutResolvedInvocation {
    param(
        [string]$TargetPath,
        [string]$Arguments,
        [string]$WorkingDirectory = ''
    )

    $launcherPath = Get-AzVmShortcutLauncherPathFromInvocation -TargetPath $TargetPath -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace([string]$launcherPath)) {
        return [pscustomobject]@{
            UsesManagedLauncher = $false
            LauncherPath = ''
            TargetPath = [string]$TargetPath
            Arguments = [string]$Arguments
            WorkingDirectory = [string]$WorkingDirectory
        }
    }

    $metadata = Get-AzVmShortcutLauncherMetadata -LauncherPath $launcherPath
    if ($null -eq $metadata) {
        return [pscustomobject]@{
            UsesManagedLauncher = $true
            LauncherPath = [string]$launcherPath
            TargetPath = ''
            Arguments = ''
            WorkingDirectory = ''
        }
    }

    return [pscustomobject]@{
        UsesManagedLauncher = $true
        LauncherPath = [string]$launcherPath
        TargetPath = [string]$metadata.TargetPath
        Arguments = [string]$metadata.Arguments
        WorkingDirectory = [string]$metadata.WorkingDirectory
    }
}

Export-ModuleMember -Function ConvertTo-AzVmShortcutLauncherBase64, ConvertFrom-AzVmShortcutLauncherBase64, Get-AzVmShortcutLauncherRoot, Get-AzVmShortcutLauncherFilePath, Get-AzVmShortcutEffectiveCommandText, Test-AzVmShortcutNeedsManagedLauncher, Get-AzVmShortcutLauncherInvocationArguments, Write-AzVmShortcutLauncherFile, Test-AzVmShortcutLauncherFile, Get-AzVmShortcutLauncherMetadata, Get-AzVmShortcutLauncherPathFromInvocation, Get-AzVmShortcutResolvedInvocation
