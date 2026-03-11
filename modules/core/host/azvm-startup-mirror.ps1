# Host startup mirror helpers.

# Handles Convert-AzVmStartupMirrorMatchText.
function Convert-AzVmStartupMirrorMatchText {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return ''
    }

    $builder = New-Object System.Text.StringBuilder
    foreach ($ch in ([string]$Value).ToLowerInvariant().ToCharArray()) {
        if ([char]::IsLetterOrDigit($ch)) {
            [void]$builder.Append($ch)
        }
    }

    return [string]$builder.ToString()
}

# Handles Get-AzVmStartupMirrorAppCatalog.
function Get-AzVmStartupMirrorAppCatalog {
    return @(
        [pscustomobject]@{
            Key = 'docker-desktop'
            DisplayName = 'Docker Desktop'
            MatchNames = @('Docker Desktop')
            MatchCommandFragments = @('Docker Desktop.exe')
        },
        [pscustomobject]@{
            Key = 'ollama'
            DisplayName = 'Ollama'
            MatchNames = @('Ollama', 'Ollama.lnk')
            MatchCommandFragments = @('ollama app.exe', 'ollama.exe')
        },
        [pscustomobject]@{
            Key = 'onedrive'
            DisplayName = 'OneDrive'
            MatchNames = @('OneDrive')
            MatchCommandFragments = @('OneDrive.exe', 'OneDrive.Sync.Service.exe')
        },
        [pscustomobject]@{
            Key = 'teams'
            DisplayName = 'Teams'
            MatchNames = @('Teams')
            MatchCommandFragments = @('ms-teams.exe', 'msteams:system-initiated')
        },
        [pscustomobject]@{
            Key = 'private local accessibility'
            DisplayName = 'private local accessibility'
            MatchNames = @('private local accessibility')
            MatchCommandFragments = @('local-accessibility.exe')
        },
        [pscustomobject]@{
            Key = 'itunes-helper'
            DisplayName = 'iTunesHelper'
            MatchNames = @('iTunesHelper')
            MatchCommandFragments = @('iTunesHelper.exe')
        },
        [pscustomobject]@{
            Key = 'google-drive'
            DisplayName = 'Google Drive'
            MatchNames = @('Google Drive', 'GoogleDriveFS')
            MatchCommandFragments = @('GoogleDriveFS.exe')
        },
        [pscustomobject]@{
            Key = 'windscribe'
            DisplayName = 'Windscribe'
            MatchNames = @('Windscribe')
            MatchCommandFragments = @('Windscribe.exe')
        },
        [pscustomobject]@{
            Key = 'anydesk'
            DisplayName = 'AnyDesk'
            MatchNames = @('AnyDesk')
            MatchCommandFragments = @('AnyDesk.exe')
        },
        [pscustomobject]@{
            Key = 'codex-app'
            DisplayName = 'Codex App'
            MatchNames = @('Codex')
            MatchCommandFragments = @('Codex.exe', 'OpenAI.Codex')
        }
    )
}

# Handles Test-AzVmStartupMirrorAppMatch.
function Test-AzVmStartupMirrorAppMatch {
    param(
        [psobject]$Entry,
        [psobject]$Definition
    )

    if ($null -eq $Entry -or $null -eq $Definition) {
        return $false
    }

    $entryNameText = Convert-AzVmStartupMirrorMatchText -Value ([string]$Entry.Name)
    $entryCommandText = Convert-AzVmStartupMirrorMatchText -Value ([string]$Entry.Command)

    foreach ($matchName in @($Definition.MatchNames)) {
        $normalized = Convert-AzVmStartupMirrorMatchText -Value ([string]$matchName)
        if (-not [string]::IsNullOrWhiteSpace([string]$normalized) -and $entryNameText.Contains($normalized)) {
            return $true
        }
    }

    foreach ($fragment in @($Definition.MatchCommandFragments)) {
        $normalized = Convert-AzVmStartupMirrorMatchText -Value ([string]$fragment)
        if (-not [string]::IsNullOrWhiteSpace([string]$normalized) -and $entryCommandText.Contains($normalized)) {
            return $true
        }
    }

    return $false
}

# Handles Resolve-AzVmHostStartupMirrorProfileFromEntries.
function Resolve-AzVmHostStartupMirrorProfileFromEntries {
    param([object[]]$Entries)

    $enabledEntries = @(
        @($Entries) |
            Where-Object {
                if ($null -eq $_) { return $false }
                if ($_.PSObject.Properties.Match('Enabled').Count -eq 0) { return $true }
                return [bool]$_.Enabled
            }
    )

    $profile = @()
    foreach ($definition in @(Get-AzVmStartupMirrorAppCatalog)) {
        $match = @($enabledEntries | Where-Object {
            Test-AzVmStartupMirrorAppMatch -Entry $_ -Definition $definition
        } | Select-Object -First 1)

        if (@($match).Count -eq 0) {
            continue
        }

        $entry = $match[0]
        $profile += [pscustomobject]@{
            Key = [string]$definition.Key
            DisplayName = [string]$definition.DisplayName
            LocalEntryName = [string]$entry.Name
            EntryType = if ($entry.PSObject.Properties.Match('EntryType').Count -gt 0) { [string]$entry.EntryType } else { '' }
            Scope = if ($entry.PSObject.Properties.Match('Scope').Count -gt 0) { [string]$entry.Scope } else { '' }
            Command = if ($entry.PSObject.Properties.Match('Command').Count -gt 0) { [string]$entry.Command } else { '' }
        }
    }

    return @($profile)
}

# Handles Get-AzVmStartupApprovedStateCode.
function Get-AzVmStartupApprovedStateCode {
    param(
        [object]$ApprovalItem,
        [string]$ValueName
    )

    if ($null -eq $ApprovalItem -or [string]::IsNullOrWhiteSpace([string]$ValueName)) {
        return -1
    }

    $property = @($ApprovalItem.PSObject.Properties | Where-Object { [string]$_.Name -eq $ValueName } | Select-Object -First 1)
    if (@($property).Count -eq 0 -or $null -eq $property[0].Value) {
        return -1
    }

    $bytes = @($property[0].Value)
    if (@($bytes).Count -eq 0) {
        return -1
    }

    return [int]$bytes[0]
}

# Handles Resolve-AzVmStartupShortcutCommand.
function Resolve-AzVmStartupShortcutCommand {
    param([string]$ShortcutPath)

    if ([string]::IsNullOrWhiteSpace([string]$ShortcutPath) -or -not (Test-Path -LiteralPath $ShortcutPath)) {
        return ''
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $targetPath = [string]$shortcut.TargetPath
        $arguments = [string]$shortcut.Arguments
        if ([string]::IsNullOrWhiteSpace([string]$targetPath)) {
            return [string]$ShortcutPath
        }

        if ([string]::IsNullOrWhiteSpace([string]$arguments)) {
            return [string]$targetPath
        }

        return ("{0} {1}" -f $targetPath, $arguments).Trim()
    }
    catch {
        return [string]$ShortcutPath
    }
}

# Handles Get-AzVmHostStartupEntries.
function Get-AzVmHostStartupEntries {
    $entries = @()

    $runDefinitions = @(
        @{ Scope = 'CurrentUser'; EntryType = 'Run'; RunPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; ApprovalPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
        @{ Scope = 'CurrentUser'; EntryType = 'Run32'; RunPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run32'; ApprovalPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' },
        @{ Scope = 'LocalMachine'; EntryType = 'Run'; RunPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; ApprovalPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
        @{ Scope = 'LocalMachine'; EntryType = 'Run32'; RunPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run32'; ApprovalPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
    )

    foreach ($definition in @($runDefinitions)) {
        $runPath = [string]$definition.RunPath
        if (-not (Test-Path -LiteralPath $runPath)) {
            continue
        }

        $runItem = Get-ItemProperty -Path $runPath -ErrorAction SilentlyContinue
        $approvalItem = $null
        if (Test-Path -LiteralPath ([string]$definition.ApprovalPath)) {
            $approvalItem = Get-ItemProperty -Path ([string]$definition.ApprovalPath) -ErrorAction SilentlyContinue
        }

        foreach ($property in @($runItem.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS(ParentPath|Path|ChildName|Drive|Provider)$' })) {
            $stateCode = Get-AzVmStartupApprovedStateCode -ApprovalItem $approvalItem -ValueName ([string]$property.Name)
            $entries += [pscustomobject]@{
                Name = [string]$property.Name
                Command = [string]$property.Value
                EntryType = [string]$definition.EntryType
                Scope = [string]$definition.Scope
                Enabled = ($stateCode -lt 0 -or $stateCode -eq 2)
                StateCode = [int]$stateCode
            }
        }
    }

    $startupFolders = @(
        @{ Scope = 'CurrentUser'; FolderPath = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'); ApprovalPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' },
        @{ Scope = 'LocalMachine'; FolderPath = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'); ApprovalPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
    )

    foreach ($definition in @($startupFolders)) {
        $folderPath = [string]$definition.FolderPath
        if ([string]::IsNullOrWhiteSpace([string]$folderPath) -or -not (Test-Path -LiteralPath $folderPath)) {
            continue
        }

        $approvalItem = $null
        if (Test-Path -LiteralPath ([string]$definition.ApprovalPath)) {
            $approvalItem = Get-ItemProperty -Path ([string]$definition.ApprovalPath) -ErrorAction SilentlyContinue
        }

        foreach ($file in @(Get-ChildItem -LiteralPath $folderPath -File -ErrorAction SilentlyContinue | Where-Object { -not [string]::Equals([string]$_.Name, 'desktop.ini', [System.StringComparison]::OrdinalIgnoreCase) })) {
            $stateCode = Get-AzVmStartupApprovedStateCode -ApprovalItem $approvalItem -ValueName ([string]$file.Name)
            $entries += [pscustomobject]@{
                Name = [string]$file.Name
                Command = Resolve-AzVmStartupShortcutCommand -ShortcutPath ([string]$file.FullName)
                EntryType = 'StartupFolder'
                Scope = [string]$definition.Scope
                Enabled = ($stateCode -lt 0 -or $stateCode -eq 2)
                StateCode = [int]$stateCode
            }
        }
    }

    return @($entries)
}

# Handles Get-AzVmHostStartupMirrorProfile.
function Get-AzVmHostStartupMirrorProfile {
    try {
        $entries = @(Get-AzVmHostStartupEntries)
        return @(Resolve-AzVmHostStartupMirrorProfileFromEntries -Entries $entries)
    }
    catch {
        return @()
    }
}

# Handles Get-AzVmHostStartupMirrorProfileJsonBase64.
function Get-AzVmHostStartupMirrorProfileJsonBase64 {
    $profile = @(Get-AzVmHostStartupMirrorProfile)
    $json = [string](ConvertTo-Json -InputObject @($profile) -Depth 6 -Compress)
    if ([string]::IsNullOrWhiteSpace([string]$json)) {
        $json = '[]'
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    return [Convert]::ToBase64String($bytes)
}
