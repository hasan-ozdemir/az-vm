# Shared task discovery helpers for portable task folders.

function Convert-AzVmTaskCatalogPriority {
    param(
        [AllowNull()]
        [object]$Value,
        [int]$DefaultValue
    )

    if ($null -eq $Value) {
        return [int]$DefaultValue
    }

    try {
        $priority = [int]$Value
    }
    catch {
        return [int]$DefaultValue
    }

    if ($priority -lt 1) {
        return [int]$DefaultValue
    }

    return [int]$priority
}

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
    if ([string]::IsNullOrWhiteSpace([string]$text)) {
        return [bool]$DefaultValue
    }

    switch ($text.Trim().ToLowerInvariant()) {
        '1' { return $true }
        'true' { return $true }
        'yes' { return $true }
        'y' { return $true }
        'on' { return $true }
        '0' { return $false }
        'false' { return $false }
        'no' { return $false }
        'n' { return $false }
        'off' { return $false }
        default { return [bool]$DefaultValue }
    }
}

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
    param([int]$TaskNumber)

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

function ConvertTo-AzVmTaskFolderStringArray {
    param([AllowNull()]$InputObject)

    $values = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in @(ConvertTo-ObjectArrayCompat -InputObject $InputObject)) {
        if ($null -eq $item) {
            continue
        }

        $text = [string]$item
        if ([string]::IsNullOrWhiteSpace([string]$text)) {
            continue
        }

        $values.Add($text) | Out-Null
    }

    return @($values.ToArray())
}

function ConvertTo-AzVmTaskFolderAssetSpecs {
    param(
        [AllowNull()]$Assets,
        [string]$TaskLabel
    )

    $assetSpecs = @()
    foreach ($asset in @(ConvertTo-ObjectArrayCompat -InputObject $Assets)) {
        if ($null -eq $asset) {
            continue
        }

        $localPath = ''
        $remotePath = ''
        if ($asset -is [System.Collections.IDictionary]) {
            if ($asset.Contains('local')) { $localPath = [string]$asset['local'] }
            if ($asset.Contains('remote')) { $remotePath = [string]$asset['remote'] }
        }
        else {
            if ($asset.PSObject.Properties.Match('local').Count -gt 0) { $localPath = [string]$asset.local }
            if ($asset.PSObject.Properties.Match('remote').Count -gt 0) { $remotePath = [string]$asset.remote }
        }

        if ([string]::IsNullOrWhiteSpace([string]$localPath) -or [string]::IsNullOrWhiteSpace([string]$remotePath)) {
            throw ("Invalid task.json assets entry for '{0}': each asset requires non-empty 'local' and 'remote' values." -f [string]$TaskLabel)
        }

        $assetSpecs += [pscustomobject]@{
            LocalPath = [string]$localPath
            RemotePath = [string]$remotePath
        }
    }

    return @($assetSpecs)
}

function ConvertTo-AzVmTaskFolderPathRule {
    param(
        [AllowNull()]$Rule,
        [string]$TaskLabel,
        [string]$CollectionName
    )

    if ($null -eq $Rule) {
        return $null
    }

    if ($Rule -is [string]) {
        if ([string]::IsNullOrWhiteSpace([string]$Rule)) {
            return $null
        }

        return [ordered]@{
            path = [string]$Rule
            targetProfiles = @()
            excludeNames = @()
            excludePathPatterns = @()
            excludeFilePatterns = @()
        }
    }

    $path = ''
    $targetProfiles = @()
    $excludeNames = @()
    $excludePathPatterns = @()
    $excludeFilePatterns = @()
    if ($Rule -is [System.Collections.IDictionary]) {
        if ($Rule.Contains('path')) { $path = [string]$Rule['path'] }
        if ($Rule.Contains('targetProfiles')) { $targetProfiles = ConvertTo-AzVmTaskFolderStringArray -InputObject $Rule['targetProfiles'] }
        if ($Rule.Contains('excludeNames')) { $excludeNames = ConvertTo-AzVmTaskFolderStringArray -InputObject $Rule['excludeNames'] }
        if ($Rule.Contains('excludePathPatterns')) { $excludePathPatterns = ConvertTo-AzVmTaskFolderStringArray -InputObject $Rule['excludePathPatterns'] }
        if ($Rule.Contains('excludeFilePatterns')) { $excludeFilePatterns = ConvertTo-AzVmTaskFolderStringArray -InputObject $Rule['excludeFilePatterns'] }
    }
    else {
        if ($Rule.PSObject.Properties.Match('path').Count -gt 0) { $path = [string]$Rule.path }
        if ($Rule.PSObject.Properties.Match('targetProfiles').Count -gt 0) { $targetProfiles = ConvertTo-AzVmTaskFolderStringArray -InputObject $Rule.targetProfiles }
        if ($Rule.PSObject.Properties.Match('excludeNames').Count -gt 0) { $excludeNames = ConvertTo-AzVmTaskFolderStringArray -InputObject $Rule.excludeNames }
        if ($Rule.PSObject.Properties.Match('excludePathPatterns').Count -gt 0) { $excludePathPatterns = ConvertTo-AzVmTaskFolderStringArray -InputObject $Rule.excludePathPatterns }
        if ($Rule.PSObject.Properties.Match('excludeFilePatterns').Count -gt 0) { $excludeFilePatterns = ConvertTo-AzVmTaskFolderStringArray -InputObject $Rule.excludeFilePatterns }
    }

    if ([string]::IsNullOrWhiteSpace([string]$path)) {
        throw ("Invalid task.json {0} entry for '{1}': each rule requires a non-empty 'path'." -f [string]$CollectionName, [string]$TaskLabel)
    }

    return [ordered]@{
        path = [string]$path
        targetProfiles = @($targetProfiles)
        excludeNames = @($excludeNames)
        excludePathPatterns = @($excludePathPatterns)
        excludeFilePatterns = @($excludeFilePatterns)
    }
}

function ConvertTo-AzVmTaskFolderRegistryRule {
    param(
        [AllowNull()]$Rule,
        [string]$TaskLabel,
        [string]$CollectionName
    )

    if ($null -eq $Rule) {
        return $null
    }

    if ($Rule -is [string]) {
        if ([string]::IsNullOrWhiteSpace([string]$Rule)) {
            return $null
        }

        return [ordered]@{
            path = [string]$Rule
            targetProfiles = @()
            distributionAllowList = @()
        }
    }

    $path = ''
    $targetProfiles = @()
    $distributionAllowList = @()
    if ($Rule -is [System.Collections.IDictionary]) {
        if ($Rule.Contains('path')) { $path = [string]$Rule['path'] }
        if ($Rule.Contains('targetProfiles')) { $targetProfiles = ConvertTo-AzVmTaskFolderStringArray -InputObject $Rule['targetProfiles'] }
        if ($Rule.Contains('distributionAllowList')) { $distributionAllowList = ConvertTo-AzVmTaskFolderStringArray -InputObject $Rule['distributionAllowList'] }
    }
    else {
        if ($Rule.PSObject.Properties.Match('path').Count -gt 0) { $path = [string]$Rule.path }
        if ($Rule.PSObject.Properties.Match('targetProfiles').Count -gt 0) { $targetProfiles = ConvertTo-AzVmTaskFolderStringArray -InputObject $Rule.targetProfiles }
        if ($Rule.PSObject.Properties.Match('distributionAllowList').Count -gt 0) { $distributionAllowList = ConvertTo-AzVmTaskFolderStringArray -InputObject $Rule.distributionAllowList }
    }

    if ([string]::IsNullOrWhiteSpace([string]$path)) {
        throw ("Invalid task.json {0} entry for '{1}': each rule requires a non-empty 'path'." -f [string]$CollectionName, [string]$TaskLabel)
    }

    return [ordered]@{
        path = [string]$path
        targetProfiles = @($targetProfiles)
        distributionAllowList = @($distributionAllowList)
    }
}

function ConvertTo-AzVmTaskFolderAppStateSpec {
    param(
        [AllowNull()]$AppState,
        [string]$TaskName,
        [string]$TaskLabel
    )

    if ($null -eq $AppState) {
        return $null
    }

    $spec = [ordered]@{
        taskName = [string]$TaskName
        machineDirectories = @()
        machineFiles = @()
        profileDirectories = @()
        profileFiles = @()
        machineRegistryKeys = @()
        userRegistryKeys = @()
    }

    $pathCollections = @('machineDirectories', 'machineFiles', 'profileDirectories', 'profileFiles')
    foreach ($collectionName in @($pathCollections)) {
        $rawRules = @()
        if ($AppState -is [System.Collections.IDictionary]) {
            if ($AppState.Contains($collectionName)) {
                $rawRules = @(ConvertTo-ObjectArrayCompat -InputObject $AppState[$collectionName])
            }
        }
        elseif ($AppState.PSObject.Properties.Match($collectionName).Count -gt 0) {
            $rawRules = @(ConvertTo-ObjectArrayCompat -InputObject $AppState.$collectionName)
        }

        $normalizedRules = @()
        foreach ($rawRule in @($rawRules)) {
            $rule = ConvertTo-AzVmTaskFolderPathRule -Rule $rawRule -TaskLabel $TaskLabel -CollectionName $collectionName
            if ($null -ne $rule) {
                $normalizedRules += $rule
            }
        }
        $spec[$collectionName] = @($normalizedRules)
    }

    $registryCollections = @('machineRegistryKeys', 'userRegistryKeys')
    foreach ($collectionName in @($registryCollections)) {
        $rawRules = @()
        if ($AppState -is [System.Collections.IDictionary]) {
            if ($AppState.Contains($collectionName)) {
                $rawRules = @(ConvertTo-ObjectArrayCompat -InputObject $AppState[$collectionName])
            }
        }
        elseif ($AppState.PSObject.Properties.Match($collectionName).Count -gt 0) {
            $rawRules = @(ConvertTo-ObjectArrayCompat -InputObject $AppState.$collectionName)
        }

        $normalizedRules = @()
        foreach ($rawRule in @($rawRules)) {
            $rule = ConvertTo-AzVmTaskFolderRegistryRule -Rule $rawRule -TaskLabel $TaskLabel -CollectionName $collectionName
            if ($null -ne $rule) {
                $normalizedRules += $rule
            }
        }
        $spec[$collectionName] = @($normalizedRules)
    }

    return [pscustomobject]$spec
}

function Get-AzVmTaskFolderMetadata {
    param(
        [string]$MetadataPath,
        [string]$TaskName,
        [int]$TaskNumber
    )

    $taskLabel = if ([string]::IsNullOrWhiteSpace([string]$TaskName)) { [string]$MetadataPath } else { [string]$TaskName }
    if (-not (Test-Path -LiteralPath $MetadataPath)) {
        throw ("task.json was not found: {0}" -f [string]$MetadataPath)
    }

    $metadataText = [string](Get-Content -LiteralPath $MetadataPath -Raw -ErrorAction Stop)
    if ([string]::IsNullOrWhiteSpace([string]$metadataText)) {
        throw ("task.json is empty: {0}" -f [string]$MetadataPath)
    }

    try {
        $metadata = ConvertFrom-JsonCompat -InputObject $metadataText
    }
    catch {
        throw ("task.json parse failed for '{0}': {1}" -f [string]$MetadataPath, $_.Exception.Message)
    }

    $priority = Convert-AzVmTaskCatalogPriority -Value $(if ($null -ne $metadata -and $metadata.PSObject.Properties.Match('priority').Count -gt 0) { $metadata.priority } else { $null }) -DefaultValue $TaskNumber
    $enabled = Convert-AzVmTaskCatalogBool -Value $(if ($null -ne $metadata -and $metadata.PSObject.Properties.Match('enabled').Count -gt 0) { $metadata.enabled } else { $null }) -DefaultValue $true
    $timeoutSeconds = Convert-AzVmTaskCatalogTimeout -Value $(if ($null -ne $metadata -and $metadata.PSObject.Properties.Match('timeout').Count -gt 0) { $metadata.timeout } else { $null }) -DefaultValue (Get-AzVmTaskDefaultTimeoutSeconds)
    $assets = @()
    if ($null -ne $metadata -and $metadata.PSObject.Properties.Match('assets').Count -gt 0 -and $null -ne $metadata.assets) {
        $assets = @(ConvertTo-AzVmTaskFolderAssetSpecs -Assets $metadata.assets -TaskLabel $taskLabel)
    }

    $appStateSpec = $null
    if ($null -ne $metadata -and $metadata.PSObject.Properties.Match('appState').Count -gt 0 -and $null -ne $metadata.appState) {
        $appStateSpec = ConvertTo-AzVmTaskFolderAppStateSpec -AppState $metadata.appState -TaskName $TaskName -TaskLabel $taskLabel
    }

    return [pscustomobject]@{
        Priority = [int]$priority
        Enabled = [bool]$enabled
        TimeoutSeconds = [int]$timeoutSeconds
        AssetSpecs = @($assets)
        AppStateSpec = $appStateSpec
    }
}

function Write-AzVmTaskFolderSkipWarning {
    param(
        [string]$RelativeFolderPath,
        [string]$Message
    )

    $label = if ([string]::IsNullOrWhiteSpace([string]$RelativeFolderPath)) { '(unknown-task-folder)' } else { [string]$RelativeFolderPath }
    Write-Warning ("Task folder skipped: {0} => {1}" -f $label, [string]$Message)
}

function Get-AzVmTaskFolderCandidates {
    param([string]$DirectoryPath)

    $rootPath = (Resolve-Path -LiteralPath $DirectoryPath).Path
    $candidates = New-Object 'System.Collections.Generic.List[object]'

    foreach ($folder in @(Get-ChildItem -LiteralPath $rootPath -Directory | Sort-Object Name)) {
        if ($folder.Name.StartsWith('.')) {
            continue
        }
        if ($folder.Name -in @('disabled', 'local', 'app-states')) {
            continue
        }

        $candidates.Add([pscustomobject]@{
            TaskRootPath = [string]$folder.FullName
            RelativeFolderPath = [string]$folder.Name
            IsDisabled = $false
            IsLocalOnly = $false
            Source = 'tracked'
        }) | Out-Null
    }

    $disabledRoot = Join-Path $rootPath 'disabled'
    if (Test-Path -LiteralPath $disabledRoot) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $disabledRoot -Directory | Sort-Object Name)) {
            if ($folder.Name.StartsWith('.')) {
                continue
            }

            $candidates.Add([pscustomobject]@{
                TaskRootPath = [string]$folder.FullName
                RelativeFolderPath = ("disabled/{0}" -f [string]$folder.Name)
                IsDisabled = $true
                IsLocalOnly = $false
                Source = 'tracked'
            }) | Out-Null
        }
    }

    $localRoot = Join-Path $rootPath 'local'
    if (Test-Path -LiteralPath $localRoot) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $localRoot -Directory | Sort-Object Name)) {
            if ($folder.Name.StartsWith('.')) {
                continue
            }
            if ([string]::Equals([string]$folder.Name, 'disabled', [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $candidates.Add([pscustomobject]@{
                TaskRootPath = [string]$folder.FullName
                RelativeFolderPath = ("local/{0}" -f [string]$folder.Name)
                IsDisabled = $false
                IsLocalOnly = $true
                Source = 'local'
            }) | Out-Null
        }

        $localDisabledRoot = Join-Path $localRoot 'disabled'
        if (Test-Path -LiteralPath $localDisabledRoot) {
            foreach ($folder in @(Get-ChildItem -LiteralPath $localDisabledRoot -Directory | Sort-Object Name)) {
                if ($folder.Name.StartsWith('.')) {
                    continue
                }

                $candidates.Add([pscustomobject]@{
                    TaskRootPath = [string]$folder.FullName
                    RelativeFolderPath = ("local/disabled/{0}" -f [string]$folder.Name)
                    IsDisabled = $true
                    IsLocalOnly = $true
                    Source = 'local'
                }) | Out-Null
            }
        }
    }

    return @($candidates.ToArray())
}

function Read-AzVmTaskFolderRow {
    param(
        [psobject]$Candidate,
        [string]$RootPath,
        [string]$ExpectedExtension
    )

    $taskRootPath = [string]$Candidate.TaskRootPath
    $relativeFolderPath = [string]$Candidate.RelativeFolderPath
    $folderName = [System.IO.Path]::GetFileName($taskRootPath.TrimEnd('\', '/'))
    if ([string]::IsNullOrWhiteSpace([string]$folderName)) {
        Write-AzVmTaskFolderSkipWarning -RelativeFolderPath $relativeFolderPath -Message 'folder name is empty.'
        return $null
    }

    $namePattern = '^(?<n>\d{2,5})-(?<words>[a-z0-9]+(?:-[a-z0-9]+){1,4})$'
    if ($folderName -notmatch $namePattern) {
        Write-AzVmTaskFolderSkipWarning -RelativeFolderPath $relativeFolderPath -Message ("folder name '{0}' does not match <task-number>-verb-noun-target format." -f [string]$folderName)
        return $null
    }

    $taskNumber = [int]$Matches.n
    $taskName = [string]$folderName
    $taskType = if ([bool]$Candidate.IsLocalOnly) { 'local' } else { Get-AzVmTrackedTaskTypeFromNumber -TaskNumber $taskNumber -TaskName $taskName }
    if ([bool]$Candidate.IsLocalOnly -and -not (Test-AzVmTaskNumberFitsLocalBand -TaskNumber $taskNumber)) {
        Write-AzVmTaskFolderSkipWarning -RelativeFolderPath $relativeFolderPath -Message ("local task '{0}' must use a 1001-9999 task number." -f [string]$taskName)
        return $null
    }

    $scriptPath = Join-Path $taskRootPath ("{0}{1}" -f [string]$taskName, [string]$ExpectedExtension)
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-AzVmTaskFolderSkipWarning -RelativeFolderPath $relativeFolderPath -Message ("main task script was not found: {0}" -f [System.IO.Path]::GetFileName($scriptPath))
        return $null
    }

    $metadataPath = Join-Path $taskRootPath 'task.json'
    $metadata = $null
    try {
        $metadata = Get-AzVmTaskFolderMetadata -MetadataPath $metadataPath -TaskName $taskName -TaskNumber $taskNumber
    }
    catch {
        Write-AzVmTaskFolderSkipWarning -RelativeFolderPath $relativeFolderPath -Message $_.Exception.Message
        return $null
    }

    $priority = [int]$metadata.Priority
    if (-not (Test-AzVmTaskPriorityFitsType -TaskType $taskType -Priority $priority)) {
        Write-AzVmTaskFolderSkipWarning -RelativeFolderPath $relativeFolderPath -Message ("priority '{0}' is outside the allowed {1} band." -f $priority, [string]$taskType)
        return $null
    }

    $script = [string](Get-Content -LiteralPath $scriptPath -Raw -ErrorAction Stop)
    $relativeScriptPath = ("{0}/{1}{2}" -f $relativeFolderPath.Trim('/'), [string]$taskName, [string]$ExpectedExtension)
    $isEnabled = [bool]$metadata.Enabled
    $disabledReason = ''
    if ([bool]$Candidate.IsDisabled) {
        $isEnabled = $false
        $disabledReason = 'disabled-by-location'
    }
    elseif (-not $isEnabled) {
        $disabledReason = 'disabled-in-task-json'
    }

    return [pscustomobject]@{
        Name = [string]$taskName
        Script = [string]$script
        Path = [string]$scriptPath
        TaskRootPath = [string]$taskRootPath
        TaskMetadataPath = [string]$metadataPath
        RelativePath = [string]$relativeScriptPath
        DirectoryPath = [string]$taskRootPath
        StageRootDirectoryPath = [string]$RootPath
        TimeoutSeconds = [int]$metadata.TimeoutSeconds
        Priority = [int]$priority
        AssetSpecs = @($metadata.AssetSpecs)
        AppStateSpec = $metadata.AppStateSpec
        TaskType = [string]$taskType
        Source = [string]$Candidate.Source
        TaskNumber = [int]$taskNumber
        Enabled = [bool]$isEnabled
        DisabledReason = [string]$disabledReason
    }
}

function Get-AzVmTaskBlocksFromDirectory {
    param(
        [string]$DirectoryPath,
        [ValidateSet('windows','linux')]
        [string]$Platform,
        [ValidateSet('init','update')]
        [string]$Stage,
        [switch]$SuppressSkipMessages
    )

    if ([string]::IsNullOrWhiteSpace([string]$DirectoryPath)) {
        throw ("Task directory for stage '{0}' is empty." -f [string]$Stage)
    }

    if (-not (Test-Path -LiteralPath $DirectoryPath)) {
        throw ("Task directory was not found: {0}" -f [string]$DirectoryPath)
    }

    $expectedExtension = if ([string]::Equals([string]$Platform, 'windows', [System.StringComparison]::OrdinalIgnoreCase)) { '.ps1' } else { '.sh' }
    $rootPath = (Resolve-Path -LiteralPath $DirectoryPath).Path
    $rows = @()
    foreach ($candidate in @(Get-AzVmTaskFolderCandidates -DirectoryPath $rootPath)) {
        try {
            $row = Read-AzVmTaskFolderRow -Candidate $candidate -RootPath $rootPath -ExpectedExtension $expectedExtension
            if ($null -ne $row) {
                $rows += $row
            }
        }
        catch {
            Write-AzVmTaskFolderSkipWarning -RelativeFolderPath ([string]$candidate.RelativeFolderPath) -Message $_.Exception.Message
        }
    }

    $nameMap = @{}
    foreach ($row in @($rows)) {
        if ($nameMap.ContainsKey([string]$row.Name)) {
            throw ("Task name '{0}' is duplicated between '{1}' and '{2}'." -f [string]$row.Name, [string]$nameMap[[string]$row.Name], [string]$row.RelativePath)
        }

        $nameMap[[string]$row.Name] = [string]$row.RelativePath
    }

    $priorityMap = @{}
    foreach ($row in @($rows)) {
        $priorityKey = [string]$row.Priority
        if ($priorityMap.ContainsKey($priorityKey)) {
            throw ("Tasks '{0}' and '{1}' resolve to the same priority '{2}'." -f [string]$priorityMap[$priorityKey], [string]$row.Name, [int]$row.Priority)
        }

        $priorityMap[$priorityKey] = [string]$row.Name
    }

    $sortedInventory = @(
        $rows |
            Sort-Object `
                @{ Expression = { [int]$_.Priority } }, `
                @{ Expression = { [int]$_.TaskNumber } }, `
                @{ Expression = { [string]$_.Name } }
    )

    $activeTasks = @()
    $disabledTasks = @()
    foreach ($task in @($sortedInventory)) {
        if (-not [bool]$task.Enabled) {
            if (-not $SuppressSkipMessages -and [string]::Equals([string]$task.DisabledReason, 'disabled-in-task-json', [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Host ("Task skipped (disabled in task.json): {0}" -f [string]$task.Name) -ForegroundColor DarkYellow
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
                TaskRootPath = [string]$task.TaskRootPath
                TaskMetadataPath = [string]$task.TaskMetadataPath
            }
            continue
        }

        $activeTasks += [pscustomobject]@{
            Name = [string]$task.Name
            Script = [string]$task.Script
            RelativePath = [string]$task.RelativePath
            DirectoryPath = [string]$task.DirectoryPath
            TaskRootPath = [string]$task.TaskRootPath
            TaskMetadataPath = [string]$task.TaskMetadataPath
            StageRootDirectoryPath = [string]$task.StageRootDirectoryPath
            TimeoutSeconds = [int]$task.TimeoutSeconds
            Priority = [int]$task.Priority
            AssetSpecs = @($task.AssetSpecs)
            AppStateSpec = $task.AppStateSpec
            TaskType = [string]$task.TaskType
            Source = [string]$task.Source
            TaskNumber = [int]$task.TaskNumber
        }
    }

    return [ordered]@{
        ActiveTasks = @($activeTasks)
        DisabledTasks = @($disabledTasks)
        InventoryTasks = @($sortedInventory)
    }
}
