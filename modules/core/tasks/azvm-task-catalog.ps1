# Shared task catalog and discovery helpers.

# Handles Get-AzVmTaskCatalogFileName.
function Get-AzVmTaskCatalogFileName {
    param(
        [ValidateSet('init','update')]
        [string]$Stage
    )

    if ($Stage -eq 'init') {
        return 'vm-init-task-catalog.json'
    }

    return 'vm-update-task-catalog.json'
}

# Handles Get-AzVmTaskCatalogPath.
function Get-AzVmTaskCatalogPath {
    param(
        [string]$DirectoryPath,
        [ValidateSet('init','update')]
        [string]$Stage
    )

    $catalogName = Get-AzVmTaskCatalogFileName -Stage $Stage
    return (Join-Path $DirectoryPath $catalogName)
}

# Handles Convert-AzVmTaskCatalogPriority.
function Convert-AzVmTaskCatalogPriority {
    param(
        [AllowNull()]
        [object]$Value,
        [int]$DefaultValue = 1000
    )

    if ($null -eq $Value) {
        return [int]$DefaultValue
    }

    try {
        $priority = [int]$Value
        if ($priority -lt 1) {
            return [int]$DefaultValue
        }
        return [int]$priority
    }
    catch {
        return [int]$DefaultValue
    }
}

# Handles Convert-AzVmTaskCatalogBool.
function Convert-AzVmTaskCatalogBool {
    param(
        [AllowNull()]
        [object]$Value,
        [bool]$DefaultValue = $true
    )

    if ($null -eq $Value) {
        return [bool]$DefaultValue
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [bool]$DefaultValue
    }

    $normalized = $text.Trim().ToLowerInvariant()
    if ($normalized -in @('1', 'true', 'yes', 'y', 'on')) {
        return $true
    }
    if ($normalized -in @('0', 'false', 'no', 'n', 'off')) {
        return $false
    }

    return [bool]$DefaultValue
}

# Handles Convert-AzVmTaskCatalogTimeout.
function Convert-AzVmTaskCatalogTimeout {
    param(
        [AllowNull()]
        [object]$Value,
        [int]$DefaultValue = 180
    )

    $timeoutSeconds = $DefaultValue
    try {
        if ($null -ne $Value -and -not [string]::IsNullOrWhiteSpace([string]$Value)) {
            $timeoutSeconds = [int]$Value
        }
    }
    catch {
        $timeoutSeconds = $DefaultValue
    }

    if ($timeoutSeconds -lt 5) {
        $timeoutSeconds = 5
    }
    if ($timeoutSeconds -gt 7200) {
        $timeoutSeconds = 7200
    }

    return [int]$timeoutSeconds
}

function Convert-AzVmTaskCatalogType {
    param(
        [AllowNull()]
        [object]$Value,
        [string]$DefaultValue = ''
    )

    if ($null -eq $Value) {
        return [string]$DefaultValue
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace([string]$text)) {
        return [string]$DefaultValue
    }

    $normalized = $text.Trim().ToLowerInvariant()
    if ($normalized -in @('initial','normal','final')) {
        return [string]$normalized
    }

    throw ("Invalid taskType value '{0}'. Expected one of: initial, normal, final." -f $text)
}

function Get-AzVmTrackedTaskDefaultPriority {
    return 1000
}

function Get-AzVmTaskDefaultTimeoutSeconds {
    return 180
}

function Test-AzVmTaskPriorityFitsType {
    param(
        [string]$TaskType,
        [int]$Priority
    )

    switch ([string]$TaskType) {
        'initial' { return ($Priority -ge 1 -and $Priority -le 99) }
        'normal' { return ($Priority -ge 101 -and $Priority -le 999) }
        'local' { return ($Priority -ge 1001 -and $Priority -le 9999) }
        'final' { return ($Priority -ge 10001 -and $Priority -le 10099) }
        default { return $false }
    }
}

function Test-AzVmTaskNumberFitsLocalBand {
    param(
        [int]$TaskNumber
    )

    return ($TaskNumber -ge 1001 -and $TaskNumber -le 9999)
}

function Get-AzVmTrackedTaskTypeFromNumber {
    param(
        [int]$TaskNumber,
        [string]$TaskName = ''
    )

    if ($TaskNumber -ge 1 -and $TaskNumber -le 99) {
        return 'initial'
    }
    if ($TaskNumber -ge 101 -and $TaskNumber -le 999) {
        return 'normal'
    }
    if ($TaskNumber -ge 10001 -and $TaskNumber -le 10099) {
        return 'final'
    }

    $label = if ([string]::IsNullOrWhiteSpace([string]$TaskName)) { [string]$TaskNumber } else { [string]$TaskName }
    throw ("Tracked task '{0}' must use an initial (01-99), normal (101-999), or final (10001-10099) task number." -f $label)
}

# Handles Get-AzVmTaskCatalogStateMap.
function Get-AzVmTaskCatalogStateMap {
    param(
        [string]$DirectoryPath,
        [ValidateSet('init','update')]
        [string]$Stage
    )

    $catalogPath = Get-AzVmTaskCatalogPath -DirectoryPath $DirectoryPath -Stage $Stage
    $taskMap = @{}
    if (-not (Test-Path -LiteralPath $catalogPath)) {
        return [pscustomobject]@{
            DefaultPriority = (Get-AzVmTrackedTaskDefaultPriority)
            DefaultTimeoutSeconds = (Get-AzVmTaskDefaultTimeoutSeconds)
            TaskMap = $taskMap
        }
    }

    $catalogText = [string](Get-Content -Path $catalogPath -Raw -ErrorAction Stop)
    if ([string]::IsNullOrWhiteSpace([string]$catalogText)) {
        return [pscustomobject]@{
            DefaultPriority = (Get-AzVmTrackedTaskDefaultPriority)
            DefaultTimeoutSeconds = (Get-AzVmTaskDefaultTimeoutSeconds)
            TaskMap = $taskMap
        }
    }

    $catalog = $null
    try {
        $catalog = ConvertFrom-JsonCompat -InputObject $catalogText
    }
    catch {
        throw ("Task catalog parse failed for '{0}': {1}" -f $catalogPath, $_.Exception.Message)
    }
    if ($null -eq $catalog -or $catalog.PSObject.Properties.Match('tasks').Count -eq 0) {
        return [pscustomobject]@{
            DefaultPriority = (Get-AzVmTrackedTaskDefaultPriority)
            DefaultTimeoutSeconds = (Get-AzVmTaskDefaultTimeoutSeconds)
            TaskMap = $taskMap
        }
    }

    $catalogDefaultPriority = Get-AzVmTrackedTaskDefaultPriority
    $catalogDefaultTimeout = Get-AzVmTaskDefaultTimeoutSeconds
    if ($catalog.PSObject.Properties.Match('defaults').Count -gt 0 -and $null -ne $catalog.defaults) {
        $defaults = $catalog.defaults
        if ($defaults.PSObject.Properties.Match('priority').Count -gt 0) {
            $catalogDefaultPriority = Convert-AzVmTaskCatalogPriority -Value $defaults.priority -DefaultValue (Get-AzVmTrackedTaskDefaultPriority)
        }
        if ($defaults.PSObject.Properties.Match('timeout').Count -gt 0) {
            $catalogDefaultTimeout = Convert-AzVmTaskCatalogTimeout -Value $defaults.timeout -DefaultValue (Get-AzVmTaskDefaultTimeoutSeconds)
        }
    }

    foreach ($entry in @(ConvertTo-ObjectArrayCompat -InputObject $catalog.tasks)) {
        if ($null -eq $entry) { continue }

        $entryName = ''
        if ($entry.PSObject.Properties.Match('name').Count -gt 0) {
            $entryName = [string]$entry.name
        }
        if ([string]::IsNullOrWhiteSpace([string]$entryName)) {
            continue
        }

        $priorityValue = $null
        if ($entry.PSObject.Properties.Match('priority').Count -gt 0) {
            $priorityValue = $entry.priority
        }

        $enabledValue = $null
        if ($entry.PSObject.Properties.Match('enabled').Count -gt 0) {
            $enabledValue = $entry.enabled
        }

        $timeoutValue = $null
        if ($entry.PSObject.Properties.Match('timeout').Count -gt 0) {
            $timeoutValue = $entry.timeout
        }

        $taskTypeValue = ''
        $hasTaskType = $false
        if ($entry.PSObject.Properties.Match('taskType').Count -gt 0) {
            $hasTaskType = $true
            $taskTypeValue = Convert-AzVmTaskCatalogType -Value $entry.taskType -DefaultValue ''
        }

        $taskMap[[string]$entryName] = [pscustomobject]@{
            HasPriority = ($null -ne $priorityValue)
            Priority = (Convert-AzVmTaskCatalogPriority -Value $priorityValue -DefaultValue $catalogDefaultPriority)
            HasEnabled = ($null -ne $enabledValue)
            Enabled = (Convert-AzVmTaskCatalogBool -Value $enabledValue -DefaultValue $true)
            HasTimeout = ($null -ne $timeoutValue)
            TimeoutSeconds = (Convert-AzVmTaskCatalogTimeout -Value $timeoutValue -DefaultValue $catalogDefaultTimeout)
            HasTaskType = [bool]$hasTaskType
            TaskType = [string]$taskTypeValue
        }
    }

    return [pscustomobject]@{
        DefaultPriority = [int]$catalogDefaultPriority
        DefaultTimeoutSeconds = [int]$catalogDefaultTimeout
        TaskMap = $taskMap
    }
}

# Handles Get-AzVmTaskScriptMetadata.
function Get-AzVmTaskScriptMetadata {
    param(
        [string]$ScriptText,
        [string]$TaskPath = ''
    )

    $result = [ordered]@{
        Priority = $null
        Enabled = $null
        TimeoutSeconds = $null
        AssetSpecs = @()
    }

    if ([string]::IsNullOrWhiteSpace([string]$ScriptText)) {
        return [pscustomobject]$result
    }

    foreach ($lineRaw in @($ScriptText -split "`r?`n")) {
        $line = [string]$lineRaw
        if ([string]::IsNullOrWhiteSpace([string]$line)) {
            continue
        }

        $trimmed = $line.Trim()
        if (-not $trimmed.StartsWith('#')) {
            return [pscustomobject]$result
        }

        if ($trimmed -notmatch '^#\s*az-vm-task-meta\s*:\s*(.+)$') {
            return [pscustomobject]$result
        }

        $metadataText = [string]$Matches[1]
        $metadata = $null
        try {
            $metadata = ConvertFrom-JsonCompat -InputObject $metadataText
        }
        catch {
            $label = if ([string]::IsNullOrWhiteSpace([string]$TaskPath)) { 'task script metadata' } else { ("task script metadata for '{0}'" -f $TaskPath) }
            throw ("Invalid {0}: {1}" -f $label, $_.Exception.Message)
        }

        if ($null -eq $metadata) {
            return [pscustomobject]$result
        }

        if ($metadata.PSObject.Properties.Match('priority').Count -gt 0) {
            try {
                $parsedPriority = [int]$metadata.priority
            }
            catch {
                $label = if ([string]::IsNullOrWhiteSpace([string]$TaskPath)) { 'task script metadata priority' } else { ("task script metadata priority for '{0}'" -f $TaskPath) }
                throw ("Invalid {0}: priority must be an integer." -f $label)
            }
            if ($parsedPriority -lt 1) {
                $label = if ([string]::IsNullOrWhiteSpace([string]$TaskPath)) { 'task script metadata priority' } else { ("task script metadata priority for '{0}'" -f $TaskPath) }
                throw ("Invalid {0}: priority must be >= 1." -f $label)
            }
            $result.Priority = [int]$parsedPriority
        }
        if ($metadata.PSObject.Properties.Match('enabled').Count -gt 0) {
            $result.Enabled = Convert-AzVmTaskCatalogBool -Value $metadata.enabled -DefaultValue $true
        }
        if ($metadata.PSObject.Properties.Match('timeout').Count -gt 0) {
            $result.TimeoutSeconds = Convert-AzVmTaskCatalogTimeout -Value $metadata.timeout -DefaultValue 180
        }

        $assetSpecs = @()
        if ($metadata.PSObject.Properties.Match('assets').Count -gt 0 -and $null -ne $metadata.assets) {
            foreach ($asset in @(ConvertTo-ObjectArrayCompat -InputObject $metadata.assets)) {
                $localPath = ''
                $remotePath = ''
                if ($null -ne $asset -and $asset.PSObject.Properties.Match('local').Count -gt 0) {
                    $localPath = [string]$asset.local
                }
                if ($null -ne $asset -and $asset.PSObject.Properties.Match('remote').Count -gt 0) {
                    $remotePath = [string]$asset.remote
                }
                if ([string]::IsNullOrWhiteSpace([string]$localPath) -or [string]::IsNullOrWhiteSpace([string]$remotePath)) {
                    $label = if ([string]::IsNullOrWhiteSpace([string]$TaskPath)) { 'task script metadata asset' } else { ("task script metadata asset for '{0}'" -f $TaskPath) }
                    throw ("Invalid {0}: each asset requires non-empty 'local' and 'remote' values." -f $label)
                }

                $assetSpecs += [pscustomobject]@{
                    LocalPath = [string]$localPath
                    RemotePath = [string]$remotePath
                }
            }
        }

        $result.AssetSpecs = @($assetSpecs)
        return [pscustomobject]$result
    }

    return [pscustomobject]$result
}

# Handles Get-AzVmTaskBlocksFromDirectory.
function Get-AzVmTaskBlocksFromDirectory {
    param(
        [string]$DirectoryPath,
        [ValidateSet('windows','linux')]
        [string]$Platform,
        [ValidateSet('init','update')]
        [string]$Stage,
        [switch]$SuppressSkipMessages
    )

    if ([string]::IsNullOrWhiteSpace($DirectoryPath)) {
        throw ("Task directory for stage '{0}' is empty." -f $Stage)
    }

    if (-not (Test-Path -LiteralPath $DirectoryPath)) {
        throw ("Task directory was not found: {0}" -f $DirectoryPath)
    }

    $expectedExt = if ($Platform -eq 'windows') { '.ps1' } else { '.sh' }
    $namePattern = '^(?<n>\d{2,5})-(?<words>[a-z0-9]+(?:-[a-z0-9]+){1,4})(?<ext>\.(ps1|sh))$'

    $rootPath = (Resolve-Path -LiteralPath $DirectoryPath).Path.TrimEnd('\', '/')
    $files = @(Get-ChildItem -LiteralPath $DirectoryPath -File -Recurse | Sort-Object FullName)

    $allRows = @()
    $trackedTaskPathByName = @{}
    $localTaskPathByName = @{}
    foreach ($file in $files) {
        $name = [string]$file.Name
        if ($name.StartsWith('.')) {
            continue
        }

        $fileExt = [System.IO.Path]::GetExtension($name)
        if (-not [string]::Equals($fileExt, $expectedExt, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        if (-not ($name -match $namePattern)) {
            throw ("Invalid task filename '{0}'. Expected 2-5 digit task number plus verb-noun-target format with 2-5 words." -f $name)
        }

        $taskOrder = [int]$Matches.n
        $ext = [string]$Matches.ext
        if (-not [string]::Equals($ext, $expectedExt, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ("Task file '{0}' has invalid extension for platform '{1}'. Expected '{2}'." -f $name, $Platform, $expectedExt)
        }

        $relativePath = [string]$file.FullName
        if ($relativePath.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relativePath = $relativePath.Substring($rootPath.Length).TrimStart('\', '/')
        }
        else {
            $relativePath = [string]$file.Name
        }
        $relativePath = $relativePath.Replace('\', '/')
        $isDisabled = $false
        $isLocalOnly = $false
        if (-not $relativePath.Contains('/')) {
            $isDisabled = $false
            $isLocalOnly = $false
        }
        elseif ($relativePath.StartsWith('disabled/', [System.StringComparison]::OrdinalIgnoreCase)) {
            $isDisabled = $true
            $isLocalOnly = $false
        }
        elseif ($relativePath.StartsWith('local/', [System.StringComparison]::OrdinalIgnoreCase)) {
            $localRelativePath = $relativePath.Substring('local/'.Length)
            if ([string]::IsNullOrWhiteSpace($localRelativePath)) {
                throw ("Task file '{0}' is under unsupported nested directory '{1}'. Only root files, disabled/*, local/*, and local/disabled/* are allowed." -f $name, $relativePath)
            }

            if ($localRelativePath.StartsWith('disabled/', [System.StringComparison]::OrdinalIgnoreCase)) {
                $localDisabledRelativePath = $localRelativePath.Substring('disabled/'.Length)
                if ([string]::IsNullOrWhiteSpace($localDisabledRelativePath) -or $localDisabledRelativePath.Contains('/')) {
                    throw ("Task file '{0}' is under unsupported nested directory '{1}'. Only root files, disabled/*, local/*, and local/disabled/* are allowed." -f $name, $relativePath)
                }

                $isDisabled = $true
                $isLocalOnly = $true
            }
            elseif ($localRelativePath.Contains('/')) {
                throw ("Task file '{0}' is under unsupported nested directory '{1}'. Only root files, disabled/*, local/*, and local/disabled/* are allowed." -f $name, $relativePath)
            }
            else {
                $isDisabled = $false
                $isLocalOnly = $true
            }
        }
        else {
            throw ("Task file '{0}' is under unsupported nested directory '{1}'. Only root files, disabled/*, local/*, and local/disabled/* are allowed." -f $name, $relativePath)
        }

        $content = Get-Content -Path $file.FullName -Raw
        $metadata = Get-AzVmTaskScriptMetadata -ScriptText ([string]$content) -TaskPath ([string]$relativePath)
        $taskName = [System.IO.Path]::GetFileNameWithoutExtension($name)
        $taskType = if ($isLocalOnly) { 'local' } else { Get-AzVmTrackedTaskTypeFromNumber -TaskNumber $taskOrder -TaskName $taskName }

        if ($isLocalOnly) {
            if ($trackedTaskPathByName.ContainsKey($taskName)) {
                throw ("Task name '{0}' is duplicated between tracked and local-only scripts ('{1}' and '{2}')." -f $taskName, [string]$trackedTaskPathByName[$taskName], $relativePath)
            }
            if ($localTaskPathByName.ContainsKey($taskName)) {
                throw ("Local-only task name '{0}' is duplicated between '{1}' and '{2}'." -f $taskName, [string]$localTaskPathByName[$taskName], $relativePath)
            }

            $localTaskPathByName[$taskName] = $relativePath
        }
        else {
            if ($localTaskPathByName.ContainsKey($taskName)) {
                throw ("Task name '{0}' is duplicated between tracked and local-only scripts ('{1}' and '{2}')." -f $taskName, $relativePath, [string]$localTaskPathByName[$taskName])
            }
            if ($trackedTaskPathByName.ContainsKey($taskName)) {
                throw ("Tracked task name '{0}' is duplicated between '{1}' and '{2}'." -f $taskName, [string]$trackedTaskPathByName[$taskName], $relativePath)
            }

            $trackedTaskPathByName[$taskName] = $relativePath
        }

        $row = [pscustomobject]@{
            Order = [int]$taskOrder
            Name = [string]$taskName
            Path = [string]$file.FullName
            RelativePath = [string]$relativePath
            Script = [string]$content
            Metadata = $metadata
            IsLocalOnly = [bool]$isLocalOnly
            IsDisabled = [bool]$isDisabled
            TaskType = [string]$taskType
            TaskNumber = [int]$taskOrder
            Source = $(if ($isLocalOnly) { 'local' } else { 'tracked' })
        }

        $allRows += $row
    }

    $catalogState = Get-AzVmTaskCatalogStateMap -DirectoryPath $DirectoryPath -Stage $Stage
    $taskMap = @{}
    if ($null -ne $catalogState -and $catalogState.PSObject.Properties.Match('TaskMap').Count -gt 0) {
        $taskMap = $catalogState.TaskMap
    }
    $catalogDefaultPriority = Get-AzVmTrackedTaskDefaultPriority
    if ($null -ne $catalogState -and $catalogState.PSObject.Properties.Match('DefaultPriority').Count -gt 0) {
        $catalogDefaultPriority = [int]$catalogState.DefaultPriority
    }
    $catalogDefaultTimeout = Get-AzVmTaskDefaultTimeoutSeconds
    if ($null -ne $catalogState -and $catalogState.PSObject.Properties.Match('DefaultTimeoutSeconds').Count -gt 0) {
        $catalogDefaultTimeout = [int]$catalogState.DefaultTimeoutSeconds
    }

    $localRows = @($allRows | Where-Object { [bool]$_.IsLocalOnly } | Sort-Object RelativePath, Name)
    $usedLocalPriorities = @{}
    foreach ($row in @($localRows)) {
        $metadata = $row.Metadata
        $localPriority = $null
        if ($null -ne $metadata -and $metadata.PSObject.Properties.Match('Priority').Count -gt 0 -and $null -ne $metadata.Priority) {
            $localPriority = [int]$metadata.Priority
            if (-not (Test-AzVmTaskPriorityFitsType -TaskType 'local' -Priority $localPriority)) {
                throw ("Local task '{0}' metadata priority '{1}' must stay in the local band 1001-9999." -f [string]$row.Name, $localPriority)
            }
        }
        elseif (Test-AzVmTaskNumberFitsLocalBand -TaskNumber ([int]$row.TaskNumber)) {
            $localPriority = [int]$row.TaskNumber
        }

        if ($null -ne $localPriority) {
            if ($usedLocalPriorities.ContainsKey([string]$localPriority)) {
                throw ("Local tasks '{0}' and '{1}' resolve to the same priority '{2}'." -f [string]$usedLocalPriorities[[string]$localPriority], [string]$row.Name, $localPriority)
            }

            $usedLocalPriorities[[string]$localPriority] = [string]$row.Name
            Add-Member -InputObject $row -MemberType NoteProperty -Name EffectiveLocalPriority -Value ([int]$localPriority) -Force
        }
    }

    $nextLocalPriority = 1001
    foreach ($row in @($localRows | Where-Object { $_.PSObject.Properties.Match('EffectiveLocalPriority').Count -eq 0 })) {
        while ($usedLocalPriorities.ContainsKey([string]$nextLocalPriority)) {
            $nextLocalPriority++
            if ($nextLocalPriority -gt 9999) {
                throw "Local task priority auto-detection exhausted the supported 1001-9999 range."
            }
        }

        $usedLocalPriorities[[string]$nextLocalPriority] = [string]$row.Name
        Add-Member -InputObject $row -MemberType NoteProperty -Name EffectiveLocalPriority -Value ([int]$nextLocalPriority) -Force
        $nextLocalPriority++
    }

    $inventoryTasks = @()
    foreach ($row in @($allRows)) {
        $taskName = [string]$row.Name
        $metadata = $row.Metadata
        $taskType = [string]$row.TaskType
        $taskPriority = $catalogDefaultPriority
        $taskTimeoutSeconds = Get-AzVmTaskDefaultTimeoutSeconds
        $isEnabled = $true
        $disabledReason = ''

        if ([bool]$row.IsLocalOnly) {
            $taskPriority = [int]$row.EffectiveLocalPriority
            $taskTimeoutSeconds = Get-AzVmTaskDefaultTimeoutSeconds
            if ($null -ne $metadata -and $metadata.PSObject.Properties.Match('TimeoutSeconds').Count -gt 0 -and $null -ne $metadata.TimeoutSeconds) {
                $taskTimeoutSeconds = [int]$metadata.TimeoutSeconds
            }
            if ($null -ne $metadata -and $metadata.PSObject.Properties.Match('Enabled').Count -gt 0 -and $null -ne $metadata.Enabled) {
                $isEnabled = [bool]$metadata.Enabled
            }
        }
        else {
            $taskTimeoutSeconds = [int]$catalogDefaultTimeout
            $hasExplicitTrackedPriority = $false
            if ($taskMap.ContainsKey($taskName)) {
                $entry = $taskMap[$taskName]
                if ($null -ne $entry -and $entry.PSObject.Properties.Match('HasTaskType').Count -gt 0 -and [bool]$entry.HasTaskType) {
                    if (-not [string]::Equals([string]$entry.TaskType, $taskType, [System.StringComparison]::OrdinalIgnoreCase)) {
                        throw ("Tracked task '{0}' is classified as '{1}' by filename but catalog taskType is '{2}'." -f $taskName, $taskType, [string]$entry.TaskType)
                    }
                }
                if ($null -ne $entry -and $entry.PSObject.Properties.Match('HasPriority').Count -gt 0 -and [bool]$entry.HasPriority) {
                    $taskPriority = [int]$entry.Priority
                    $hasExplicitTrackedPriority = $true
                }
                if ($null -ne $entry -and $entry.PSObject.Properties.Match('HasTimeout').Count -gt 0 -and [bool]$entry.HasTimeout) {
                    $taskTimeoutSeconds = [int]$entry.TimeoutSeconds
                }
                if ($null -ne $entry -and $entry.PSObject.Properties.Match('HasEnabled').Count -gt 0 -and [bool]$entry.HasEnabled) {
                    $isEnabled = [bool]$entry.Enabled
                }
            }

            if ($hasExplicitTrackedPriority -and -not (Test-AzVmTaskPriorityFitsType -TaskType $taskType -Priority ([int]$taskPriority))) {
                throw ("Tracked task '{0}' resolved invalid priority '{1}' for taskType '{2}'." -f $taskName, $taskPriority, $taskType)
            }
        }

        if ([bool]$row.IsDisabled) {
            $isEnabled = $false
            $disabledReason = 'disabled-by-location'
        }
        elseif (-not $isEnabled) {
            if ([bool]$row.IsLocalOnly) {
                $disabledReason = 'disabled-in-script-metadata'
            }
            else {
                $disabledReason = 'disabled-in-catalog'
            }
        }

        $assetSpecs = @()
        if ($null -ne $metadata -and $metadata.PSObject.Properties.Match('AssetSpecs').Count -gt 0 -and $null -ne $metadata.AssetSpecs) {
            $assetSpecs = @(ConvertTo-ObjectArrayCompat -InputObject $metadata.AssetSpecs)
        }

        $inventoryTasks += [pscustomobject]@{
            Name = [string]$taskName
            Script = [string]$row.Script
            RelativePath = [string]$row.RelativePath
            DirectoryPath = [string](Split-Path -Path $row.Path -Parent)
            TimeoutSeconds = [int]$taskTimeoutSeconds
            Priority = [int]$taskPriority
            AssetSpecs = @($assetSpecs)
            TaskType = [string]$taskType
            Source = [string]$row.Source
            TaskNumber = [int]$row.TaskNumber
            Enabled = [bool]$isEnabled
            DisabledReason = [string]$disabledReason
        }
    }

    $sortedInventory = @($inventoryTasks | Sort-Object `
        @{ Expression = { [int]$_.Priority } }, `
        @{ Expression = { [int]$_.TaskNumber } }, `
        @{ Expression = { [string]$_.Name } })

    $activeTasks = @()
    $disabledTasks = @()
    foreach ($task in @($sortedInventory)) {
        if (-not [bool]$task.Enabled) {
            if (-not $SuppressSkipMessages) {
                if ([string]::Equals([string]$task.DisabledReason, 'disabled-in-script-metadata', [System.StringComparison]::OrdinalIgnoreCase)) {
                    Write-Host ("Task skipped (disabled in script metadata): {0}" -f [string]$task.Name) -ForegroundColor DarkYellow
                }
                elseif ([string]::Equals([string]$task.DisabledReason, 'disabled-in-catalog', [System.StringComparison]::OrdinalIgnoreCase)) {
                    Write-Host ("Task skipped (disabled in catalog): {0}" -f [string]$task.Name) -ForegroundColor DarkYellow
                }
            }

            $disabledTasks += [pscustomobject]@{
                Name = [string]$task.Name
                RelativePath = [string]$task.RelativePath
                Priority = [int]$task.Priority
                TimeoutSeconds = [int]$task.TimeoutSeconds
                TaskType = [string]$task.TaskType
                Source = [string]$task.Source
                DisabledReason = [string]$task.DisabledReason
                TaskNumber = [int]$task.TaskNumber
            }
            continue
        }

        $activeTasks += [pscustomobject]@{
            Name = [string]$task.Name
            Script = [string]$task.Script
            RelativePath = [string]$task.RelativePath
            DirectoryPath = [string]$task.DirectoryPath
            TimeoutSeconds = [int]$task.TimeoutSeconds
            Priority = [int]$task.Priority
            AssetSpecs = @($task.AssetSpecs)
            TaskType = [string]$task.TaskType
            Source = [string]$task.Source
            TaskNumber = [int]$task.TaskNumber
        }
    }

    return [ordered]@{
        ActiveTasks = $activeTasks
        DisabledTasks = $disabledTasks
        InventoryTasks = $sortedInventory
    }
}
