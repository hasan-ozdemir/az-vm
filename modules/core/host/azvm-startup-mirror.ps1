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
            MatchCommandFragments = @('ms-teams.exe', 'msteams:system-initiated', 'shell:AppsFolder\\MSTeams_', 'MSTeams_8wekyb3d8bbwe!')
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

# Handles Get-AzVmHostAccessibilityConfigurationValue.
function Get-AzVmHostAccessibilityConfigurationValue {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace([string]$Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    $item = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.PSObject.Properties.Match('Configuration').Count -eq 0) {
        return ''
    }

    return [string]$item.Configuration
}

# Handles Get-AzVmHostAccessibilityAssistiveTechnologyEntries.
function Get-AzVmHostAccessibilityAssistiveTechnologyEntries {
    $entries = @()
    $atRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Accessibility\ATs'
    if (-not (Test-Path -LiteralPath $atRoot)) {
        return @()
    }

    foreach ($key in @(Get-ChildItem -LiteralPath $atRoot -ErrorAction SilentlyContinue | Sort-Object PSChildName)) {
        if ($null -eq $key) {
            continue
        }

        $item = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            continue
        }

        $entries += [pscustomobject]@{
            Key = [string]$key.PSChildName
            ApplicationName = if ($item.PSObject.Properties.Match('ApplicationName').Count -gt 0) { [string]$item.ApplicationName } else { '' }
            Description = if ($item.PSObject.Properties.Match('Description').Count -gt 0) { [string]$item.Description } else { '' }
            SimpleProfile = if ($item.PSObject.Properties.Match('SimpleProfile').Count -gt 0) { [string]$item.SimpleProfile } else { '' }
            StartExe = if ($item.PSObject.Properties.Match('StartExe').Count -gt 0) { [string]$item.StartExe } else { '' }
            TerminateOnDesktopSwitch = if ($item.PSObject.Properties.Match('TerminateOnDesktopSwitch').Count -gt 0) { [string]$item.TerminateOnDesktopSwitch } else { '' }
            Profile = if ($item.PSObject.Properties.Match('Profile').Count -gt 0) { [string]$item.Profile } else { '' }
        }
    }

    return @($entries)
}

# Handles Get-AzVmHostAutostartScheduledTasks.
function Get-AzVmHostAutostartScheduledTasks {
    $results = @()

    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        return @()
    }

    try {
        $scheduledTasks = @(Get-ScheduledTask -ErrorAction Stop)
    }
    catch {
        return @()
    }

    foreach ($task in @($scheduledTasks)) {
        if ($null -eq $task) {
            continue
        }

        $triggerSummaries = @()
        foreach ($trigger in @($task.Triggers)) {
            if ($null -eq $trigger) {
                continue
            }

            $triggerType = ''
            if ($trigger.PSObject.Properties.Match('TriggerType').Count -gt 0) {
                $triggerType = [string]$trigger.TriggerType
            }
            if ([string]::IsNullOrWhiteSpace([string]$triggerType)) {
                $triggerType = [string]$trigger.GetType().Name
            }
            if ($triggerType -notmatch 'Logon|Boot') {
                continue
            }

            $triggerSummaries += [pscustomobject]@{
                TriggerType = [string]$triggerType
                UserId = if ($trigger.PSObject.Properties.Match('UserId').Count -gt 0) { [string]$trigger.UserId } else { '' }
                Enabled = if ($trigger.PSObject.Properties.Match('Enabled').Count -gt 0) { [string]$trigger.Enabled } else { '' }
            }
        }

        if (@($triggerSummaries).Count -eq 0) {
            continue
        }

        $actionSummaries = @()
        foreach ($action in @($task.Actions)) {
            if ($null -eq $action) {
                continue
            }

            $actionSummaries += [pscustomobject]@{
                Execute = if ($action.PSObject.Properties.Match('Execute').Count -gt 0) { [string]$action.Execute } else { '' }
                Arguments = if ($action.PSObject.Properties.Match('Arguments').Count -gt 0) { [string]$action.Arguments } else { '' }
                WorkingDirectory = if ($action.PSObject.Properties.Match('WorkingDirectory').Count -gt 0) { [string]$action.WorkingDirectory } else { '' }
            }
        }

        $results += [pscustomobject]@{
            TaskName = if ($task.PSObject.Properties.Match('TaskName').Count -gt 0) { [string]$task.TaskName } else { '' }
            TaskPath = if ($task.PSObject.Properties.Match('TaskPath').Count -gt 0) { [string]$task.TaskPath } else { '' }
            State = if ($task.PSObject.Properties.Match('State').Count -gt 0) { [string]$task.State } else { '' }
            Enabled = if ($task.PSObject.Properties.Match('State').Count -gt 0) { -not [string]::Equals([string]$task.State, 'Disabled', [System.StringComparison]::OrdinalIgnoreCase) } else { $true }
            UserId = if ($task.PSObject.Properties.Match('Principal').Count -gt 0 -and $null -ne $task.Principal -and $task.Principal.PSObject.Properties.Match('UserId').Count -gt 0) { [string]$task.Principal.UserId } else { '' }
            RunLevel = if ($task.PSObject.Properties.Match('Principal').Count -gt 0 -and $null -ne $task.Principal -and $task.Principal.PSObject.Properties.Match('RunLevel').Count -gt 0) { [string]$task.Principal.RunLevel } else { '' }
            Triggers = @($triggerSummaries)
            Actions = @($actionSummaries)
        }
    }

    return @($results)
}

# Handles Get-AzVmHostAutostartDiscovery.
function Get-AzVmHostAutostartDiscovery {
    return [pscustomobject]@{
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        StartupEntries = @(Get-AzVmHostStartupEntries)
        ScheduledTasks = @(Get-AzVmHostAutostartScheduledTasks)
        Accessibility = [pscustomobject]@{
            LocalMachineConfiguration = (Get-AzVmHostAccessibilityConfigurationValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Accessibility')
            CurrentUserConfiguration = (Get-AzVmHostAccessibilityConfigurationValue -Path 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Accessibility')
            AssistiveTechnologies = @(Get-AzVmHostAccessibilityAssistiveTechnologyEntries)
        }
    }
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

# Handles Get-AzVmHostAutostartDiscoveryJsonBase64.
function Get-AzVmHostAutostartDiscoveryJsonBase64 {
    $discovery = Get-AzVmHostAutostartDiscovery
    $json = [string](ConvertTo-Json -InputObject $discovery -Depth 8 -Compress)
    if ([string]::IsNullOrWhiteSpace([string]$json)) {
        $json = '{}'
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    return [Convert]::ToBase64String($bytes)
}
