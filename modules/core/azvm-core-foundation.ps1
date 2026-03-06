# Core foundation utilities and shared helpers.

# Handles Get-AzVmRepoRoot.
function Get-AzVmRepoRoot {
    if (-not [string]::IsNullOrWhiteSpace([string]$script:AzVmRepoRoot) -and (Test-Path -LiteralPath ([string]$script:AzVmRepoRoot))) {
        return [string]$script:AzVmRepoRoot
    }

    $repoRootCandidate = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:AzVmRepoRoot = [string]$repoRootCandidate
    return [string]$script:AzVmRepoRoot
}

# Handles Convert-AzVmPerfSecondsText.
function Convert-AzVmPerfSecondsText {
    param(
        [double]$Seconds
    )

    if ($Seconds -lt 0) {
        $Seconds = 0
    }

    return ("{0:N1} seconds" -f [double]$Seconds)
}

# Handles Write-AzVmPerfTiming.
function Write-AzVmPerfTiming {
    param(
        [string]$Category,
        [string]$Label,
        [double]$Seconds
    )

    if (-not $script:PerfMode) {
        return
    }

    $categoryText = if ([string]::IsNullOrWhiteSpace([string]$Category)) { "metric" } else { ([string]$Category).Trim() }
    $labelText = if ([string]::IsNullOrWhiteSpace([string]$Label)) { "operation" } else { ([string]$Label).Trim() }
    if ($labelText.Length -gt 240) {
        $labelText = $labelText.Substring(0, 237) + "..."
    }

    $durationText = Convert-AzVmPerfSecondsText -Seconds $Seconds
    Write-Host ("perf: {0} -> {1} ({2})" -f $categoryText, $labelText, $durationText) -ForegroundColor DarkGray
}

# Handles Get-AzVmAzCliExecutable.
function Get-AzVmAzCliExecutable {
    if (-not [string]::IsNullOrWhiteSpace([string]$script:AzCliExecutable)) {
        return [string]$script:AzCliExecutable
    }

    $azApps = @(Get-Command az -All -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' -and -not [string]::IsNullOrWhiteSpace([string]$_.Source) })
    $azApp = $null
    if ($azApps.Count -gt 0) {
        $azApp = @($azApps | Where-Object { -not ([string]$_.Source).ToLowerInvariant().EndsWith('.cmd') -and -not ([string]$_.Source).ToLowerInvariant().EndsWith('.bat') } | Select-Object -First 1)
        if ($null -eq $azApp -or @($azApp).Count -eq 0) {
            $azApp = @($azApps | Select-Object -First 1)
        }
        if ($azApp -is [System.Array]) {
            $azApp = [object]$azApp[0]
        }
    }
    if ($null -eq $azApp -or [string]::IsNullOrWhiteSpace([string]$azApp.Source)) {
        throw "Azure CLI executable could not be resolved from PATH."
    }

    $script:AzCliExecutable = [string]$azApp.Source
    return [string]$script:AzCliExecutable
}

# Handles Invoke-AzVmAzCliCommand.
function Invoke-AzVmAzCliCommand {
    param(
        [string[]]$Arguments
    )

    $argValues = @($Arguments | ForEach-Object { [string]$_ })
    $perfWatch = $null
    $perfLabel = ''
    $shouldEmitPerf = $script:PerfMode -and ([int]$script:PerfSuppressAzTimingDepth -le 0)
    if ($shouldEmitPerf) {
        $perfLabel = "az " + ($argValues -join " ")
        $perfWatch = [System.Diagnostics.Stopwatch]::StartNew()
    }

    try {
        $azExecutable = Get-AzVmAzCliExecutable
        $timeoutSeconds = [int]$script:AzCommandTimeoutSeconds
        if ($timeoutSeconds -lt 0) { $timeoutSeconds = 0 }
        $azExecutableText = [string]$azExecutable
        $useCmdHost = -not $azExecutableText.ToLowerInvariant().EndsWith('.exe')
        $cmdHost = if ([string]::IsNullOrWhiteSpace([string]$env:ComSpec)) { 'cmd.exe' } else { [string]$env:ComSpec }

        if ($timeoutSeconds -eq 0) {
            if ($useCmdHost) {
                & $cmdHost /d /c $azExecutableText @argValues
            }
            else {
                & $azExecutableText @argValues
            }
            return
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        if ($useCmdHost) {
            $psi.FileName = $cmdHost
            $cmdArgs = @('/d', '/c', $azExecutableText)
            $cmdArgs += $argValues
            $psi.Arguments = ($cmdArgs | ForEach-Object { Convert-AzVmProcessArgument -Value ([string]$_) }) -join ' '
        }
        else {
            $psi.FileName = $azExecutableText
            $psi.Arguments = ($argValues | ForEach-Object { Convert-AzVmProcessArgument -Value ([string]$_) }) -join ' '
        }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()

        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $waitMs = [int][Math]::Min([double][int]::MaxValue, [double]$timeoutSeconds * 1000.0)
        $completed = $proc.WaitForExit($waitMs)
        if (-not $completed) {
            try { $proc.Kill() } catch { }
            try { [void]$proc.WaitForExit() } catch { }
            $global:LASTEXITCODE = 124
            throw ("az command timed out after {0} second(s)." -f $timeoutSeconds)
        }

        [void]$proc.WaitForExit()
        $stdoutText = ""
        $stderrText = ""
        try { $stdoutText = [string]$stdoutTask.Result } catch { }
        try { $stderrText = [string]$stderrTask.Result } catch { }
        $global:LASTEXITCODE = [int]$proc.ExitCode

        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            Write-Host ($stderrText.TrimEnd())
        }

        if ([string]::IsNullOrWhiteSpace($stdoutText)) {
            return @()
        }

        $stdoutLines = @($stdoutText -split "`r?`n" | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($stdoutLines.Count -eq 0) {
            return @()
        }
        if ($stdoutLines.Count -eq 1) {
            return [string]$stdoutLines[0]
        }

        return $stdoutLines
    }
    finally {
        if ($null -ne $perfWatch -and $perfWatch.IsRunning) {
            $perfWatch.Stop()
        }
        if ($null -ne $perfWatch -and $shouldEmitPerf) {
            Write-AzVmPerfTiming -Category "az" -Label $perfLabel -Seconds $perfWatch.Elapsed.TotalSeconds
        }
    }
}

# Handles az.
function az {
    $argList = @()
    foreach ($arg in @($args)) {
        $argList += [string]$arg
    }

    return (Invoke-AzVmAzCliCommand -Arguments $argList)
}

# Handles Invoke-AzVmHttpRestMethod.
function Invoke-AzVmHttpRestMethod {
    param(
        [ValidateSet("Get","Post","Put","Delete","Patch","Head","Options")]
        [string]$Method = "Get",
        [string]$Uri,
        [hashtable]$Headers,
        [AllowNull()]
        [object]$Body,
        [string]$PerfLabel = "http request"
    )

    if ([string]::IsNullOrWhiteSpace([string]$Uri)) {
        throw "HTTP request URI is required."
    }

    $watch = $null
    if ($script:PerfMode) {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
    }

    try {
        $invokeParams = @{
            Method = [string]$Method
            Uri = [string]$Uri
            ErrorAction = 'Stop'
        }
        if ($null -ne $Headers) {
            $invokeParams['Headers'] = $Headers
        }
        if ($PSBoundParameters.ContainsKey('Body')) {
            $invokeParams['Body'] = $Body
        }

        return Invoke-RestMethod @invokeParams
    }
    finally {
        if ($null -ne $watch -and $watch.IsRunning) {
            $watch.Stop()
        }
        if ($null -ne $watch) {
            Write-AzVmPerfTiming -Category "http" -Label $PerfLabel -Seconds $watch.Elapsed.TotalSeconds
        }
    }
}

# Handles Get-AzVmPlatformDefaults.
function Get-AzVmPlatformDefaults {
    param(
        [ValidateSet('windows','linux')]
        [string]$Platform
    )

    if ($Platform -eq 'windows') {
        return [ordered]@{
            PlatformLabel = 'windows'
            WindowTitle = 'az vm'
            ServerNameDefault = 'examplevm'
            VmImageDefault = 'MicrosoftWindowsDesktop:office-365:win11-25h2-avd-m365:latest'
            VmDiskSizeDefault = '128'
            VmInitTaskDirDefault = 'windows\init'
            VmUpdateTaskDirDefault = 'windows\update'
            RunCommandId = 'RunPowerShellScript'
            SshShell = 'powershell'
            IncludeRdp = $true
        }
    }

    return [ordered]@{
        PlatformLabel = 'linux'
        WindowTitle = 'az vm'
        ServerNameDefault = 'otherexamplevm'
        VmImageDefault = 'Canonical:ubuntu-24_04-lts:server:latest'
        VmDiskSizeDefault = '40'
        VmInitTaskDirDefault = 'linux\init'
        VmUpdateTaskDirDefault = 'linux\update'
        RunCommandId = 'RunShellScript'
        SshShell = 'bash'
        IncludeRdp = $false
    }
}

# Handles Get-AzVmPlatformVmConfigKey.
function Get-AzVmPlatformVmConfigKey {
    param(
        [ValidateSet('windows','linux')]
        [string]$Platform,
        [ValidateSet('VM_IMAGE','VM_SIZE','VM_DISK_SIZE_GB')]
        [string]$BaseKey
    )

    $prefix = if ($Platform -eq 'windows') { 'WIN_' } else { 'LIN_' }
    return ($prefix + $BaseKey)
}

# Handles Get-AzVmPlatformTaskCatalogConfigKey.
function Get-AzVmPlatformTaskCatalogConfigKey {
    param(
        [ValidateSet('windows','linux')]
        [string]$Platform,
        [ValidateSet('init','update')]
        [string]$Stage
    )

    if ($Platform -eq 'windows') {
        if ($Stage -eq 'init') {
            return 'WIN_VM_INIT_TASK_DIR'
        }

        return 'WIN_VM_UPDATE_TASK_DIR'
    }

    if ($Stage -eq 'init') {
        return 'LIN_VM_INIT_TASK_DIR'
    }

    return 'LIN_VM_UPDATE_TASK_DIR'
}

# Handles Resolve-AzVmPlatformConfigMap.
function Resolve-AzVmPlatformConfigMap {
    param(
        [hashtable]$ConfigMap,
        [ValidateSet('windows','linux')]
        [string]$Platform
    )

    $resolved = @{}
    if ($ConfigMap) {
        foreach ($key in @($ConfigMap.Keys)) {
            $resolved[[string]$key] = [string]$ConfigMap[$key]
        }
    }

    foreach ($baseKey in @('VM_IMAGE','VM_SIZE','VM_DISK_SIZE_GB')) {
        $platformKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey ([string]$baseKey)
        $genericValue = [string](Get-ConfigValue -Config $resolved -Key ([string]$baseKey) -DefaultValue '')
        $platformValue = [string](Get-ConfigValue -Config $resolved -Key ([string]$platformKey) -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace([string]$genericValue)) {
            $resolved[[string]$baseKey] = [string]$genericValue
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$platformValue)) {
            $resolved[[string]$baseKey] = [string]$platformValue
            continue
        }
        if ($resolved.ContainsKey([string]$baseKey)) {
            $resolved.Remove([string]$baseKey)
        }
    }

    $resolved['VM_OS_TYPE'] = $Platform
    return $resolved
}

# Handles Resolve-AzVmPlatformSelection.
function Resolve-AzVmPlatformSelection {
    param(
        [hashtable]$ConfigMap,
        [string]$EnvFilePath,
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag,
        [hashtable]$ConfigOverrides
    )

    if ($WindowsFlag -and $LinuxFlag) {
        Throw-FriendlyError -Detail 'Both --windows and --linux were provided. Select only one.' -Code 11 -Summary 'Conflicting OS selection flags were provided.' -Hint 'Use only one of --windows or --linux.'
    }

    $selected = ''
    if ($WindowsFlag) {
        $selected = 'windows'
    }
    elseif ($LinuxFlag) {
        $selected = 'linux'
    }
    else {
        $fromEnv = [string](Get-ConfigValue -Config $ConfigMap -Key 'VM_OS_TYPE' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
            $candidate = $fromEnv.Trim().ToLowerInvariant()
            if ($candidate -eq 'windows' -or $candidate -eq 'linux') {
                $selected = $candidate
            }
            else {
                Write-Warning ("Invalid VM_OS_TYPE '{0}' in .env. Expected windows|linux." -f $fromEnv)
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($selected)) {
        if ($AutoMode) {
            Throw-FriendlyError -Detail 'VM OS type is unresolved in auto mode.' -Code 12 -Summary 'Auto mode requires VM_OS_TYPE.' -Hint 'Set VM_OS_TYPE=windows|linux in .env, or pass --windows/--linux.'
        }

        while ($true) {
            $raw = Read-Host 'Select VM OS type (windows/linux, default=windows)'
            if ([string]::IsNullOrWhiteSpace($raw)) {
                $selected = 'windows'
                break
            }

            $candidate = $raw.Trim().ToLowerInvariant()
            if ($candidate -eq 'w') { $candidate = 'windows' }
            if ($candidate -eq 'l') { $candidate = 'linux' }
            if ($candidate -eq 'windows' -or $candidate -eq 'linux') {
                $selected = $candidate
                break
            }

            Write-Host "Please enter 'windows' or 'linux'." -ForegroundColor Yellow
        }
    }

    if ($ConfigOverrides) {
        $ConfigOverrides['VM_OS_TYPE'] = $selected
    }

    if (-not $AutoMode) {
        Set-DotEnvValue -Path $EnvFilePath -Key 'VM_OS_TYPE' -Value $selected
    }

    Write-Host ("VM OS type '{0}' will be used." -f $selected) -ForegroundColor Green
    return $selected
}

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
        [int]$DefaultValue = 10
    )

    if ($null -eq $Value) {
        return [int]$DefaultValue
    }

    try {
        return [int]$Value
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

# Handles Sync-AzVmTaskCatalogPriority.
function Sync-AzVmTaskCatalogPriority {
    param(
        [string]$DirectoryPath,
        [ValidateSet('init','update')]
        [string]$Stage,
        [object[]]$ActiveRows
    )

    $catalogPath = Get-AzVmTaskCatalogPath -DirectoryPath $DirectoryPath -Stage $Stage
    $activeRowsSortedByPrefix = @($ActiveRows | Sort-Object Order, Name)
    $activeTaskNames = @(@($activeRowsSortedByPrefix | ForEach-Object { [string]$_.Name }) | Sort-Object -Unique)

    $catalogBeforeText = ''
    $catalog = $null
    if (Test-Path -LiteralPath $catalogPath) {
        $catalogBeforeText = [string](Get-Content -Path $catalogPath -Raw -ErrorAction Stop)
        if (-not [string]::IsNullOrWhiteSpace([string]$catalogBeforeText)) {
            try {
                $catalog = ConvertFrom-JsonCompat -InputObject $catalogBeforeText
            }
            catch {
                throw ("Task catalog parse failed for '{0}': {1}" -f $catalogPath, $_.Exception.Message)
            }
        }
    }

    $existingMap = @{}
    $catalogTasks = @()
    if ($null -ne $catalog -and $catalog.PSObject.Properties.Match('tasks').Count -gt 0) {
        $catalogTasks = @($catalog.tasks)
    }
    foreach ($entry in @($catalogTasks)) {
        if ($null -eq $entry) { continue }
        $entryName = ''
        if ($entry.PSObject.Properties.Match('name').Count -gt 0) {
            $entryName = [string]$entry.name
        }
        if ([string]::IsNullOrWhiteSpace([string]$entryName)) {
            continue
        }

        $existingMap[[string]$entryName] = [pscustomobject]@{
            Name = [string]$entryName
            Priority = (Convert-AzVmTaskCatalogPriority -Value $entry.priority -DefaultValue 10)
            Enabled = (Convert-AzVmTaskCatalogBool -Value $entry.enabled -DefaultValue $true)
        }
    }

    $activeNameSet = @{}
    foreach ($name in @($activeTaskNames)) {
        $activeNameSet[[string]$name] = $true
        if (-not $existingMap.ContainsKey([string]$name)) {
            Write-Warning ("Task catalog update: task '{0}' was missing and is added with priority=10 enabled=true." -f [string]$name)
            $existingMap[[string]$name] = [pscustomobject]@{
                Name = [string]$name
                Priority = 10
                Enabled = $true
            }
        }
    }

    foreach ($name in @($existingMap.Keys)) {
        if (-not $activeNameSet.ContainsKey([string]$name)) {
            Write-Warning ("Task catalog update: stale task '{0}' was removed because it does not exist on disk." -f [string]$name)
            [void]$existingMap.Remove([string]$name)
        }
    }

    $finalTasks = @()
    foreach ($row in @($activeRowsSortedByPrefix)) {
        $taskName = [string]$row.Name
        if (-not $existingMap.ContainsKey($taskName)) {
            continue
        }
        $taskState = $existingMap[$taskName]
        $finalTasks += [ordered]@{
            name = [string]$taskName
            priority = [int](Convert-AzVmTaskCatalogPriority -Value $taskState.Priority -DefaultValue 10)
            enabled = [bool](Convert-AzVmTaskCatalogBool -Value $taskState.Enabled -DefaultValue $true)
        }
    }

    $finalCatalog = [ordered]@{
        tasks = @($finalTasks)
    }

    $newCatalogText = [string](ConvertTo-Json -InputObject $finalCatalog -Depth 10)
    $normalize = {
        param([string]$Text)
        if ($null -eq $Text) { return '' }
        return (($Text -replace "`r`n", "`n") -replace "`r", "`n").Trim()
    }

    if (-not (Test-Path -LiteralPath $catalogPath) -or (& $normalize $catalogBeforeText) -ne (& $normalize $newCatalogText)) {
        Write-TextFileNormalized -Path $catalogPath -Content $newCatalogText -Encoding "utf8NoBom" -LineEnding "crlf" -EnsureTrailingNewline
    }

    $taskMap = @{}
    foreach ($row in @($finalTasks)) {
        $taskMap[[string]$row.name] = [pscustomobject]@{
            Priority = [int]$row.priority
            Enabled = [bool]$row.enabled
        }
    }

    return [ordered]@{
        CatalogPath = [string]$catalogPath
        TaskMap = $taskMap
    }
}

# Handles Get-AzVmTaskBlocksFromDirectory.
function Get-AzVmTaskBlocksFromDirectory {
    param(
        [string]$DirectoryPath,
        [ValidateSet('windows','linux')]
        [string]$Platform,
        [ValidateSet('init','update')]
        [string]$Stage
    )

    if ([string]::IsNullOrWhiteSpace($DirectoryPath)) {
        throw ("Task directory for stage '{0}' is empty." -f $Stage)
    }

    if (-not (Test-Path -LiteralPath $DirectoryPath)) {
        throw ("Task directory was not found: {0}" -f $DirectoryPath)
    }

    $expectedExt = if ($Platform -eq 'windows') { '.ps1' } else { '.sh' }
    $namePattern = '^(?<n>\d{2})-(?<words>[a-z0-9]+(?:-[a-z0-9]+){1,4})(?<ext>\.(ps1|sh))$'

    $rootPath = (Resolve-Path -LiteralPath $DirectoryPath).Path.TrimEnd('\', '/')
    $files = @(Get-ChildItem -LiteralPath $DirectoryPath -File -Recurse | Sort-Object FullName)

    $activeRows = @()
    $disabledRows = @()
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
            throw ("Invalid task filename '{0}'. Expected NN-verb-topic format with 2-5 words." -f $name)
        }

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
        $isDisabled = $relativePath.StartsWith('disabled/', [System.StringComparison]::OrdinalIgnoreCase)
        if ((-not $isDisabled) -and $relativePath.Contains('/')) {
            throw ("Task file '{0}' is under unsupported nested directory '{1}'. Only root files and disabled/* are allowed." -f $name, $relativePath)
        }

        $row = [pscustomobject]@{
            Order = [int]$Matches.n
            Name = [System.IO.Path]::GetFileNameWithoutExtension($name)
            Path = [string]$file.FullName
            RelativePath = [string]$relativePath
        }

        if ($isDisabled) {
            $disabledRows += $row
        }
        else {
            $activeRows += $row
        }
    }

    $syncInfo = Sync-AzVmTaskCatalogPriority -DirectoryPath $DirectoryPath -Stage $Stage -ActiveRows $activeRows
    $taskMap = @{}
    if ($syncInfo -and $syncInfo.PSObject.Properties.Match('TaskMap').Count -gt 0 -and $null -ne $syncInfo.TaskMap) {
        $taskMap = $syncInfo.TaskMap
    }

    $activeTasks = @()
    $sortedActiveRows = @(
        $activeRows | Sort-Object `
            @{ Expression = { if ($taskMap.ContainsKey([string]$_.Name)) { [int]$taskMap[[string]$_.Name].Priority } else { 10 } } }, `
            @{ Expression = { [int]$_.Order } }, `
            @{ Expression = { [string]$_.Name } }
    )
    foreach ($row in @($sortedActiveRows)) {
        $taskName = [string]$row.Name
        $isEnabled = $true
        if ($taskMap.ContainsKey($taskName)) {
            $isEnabled = [bool](Convert-AzVmTaskCatalogBool -Value $taskMap[$taskName].Enabled -DefaultValue $true)
        }
        if (-not $isEnabled) {
            Write-Host ("Task skipped (disabled in catalog): {0}" -f $taskName) -ForegroundColor DarkYellow
            continue
        }

        $content = Get-Content -Path $row.Path -Raw
        $activeTasks += [pscustomobject]@{
            Name = $taskName
            Script = [string]$content
            RelativePath = [string]$row.RelativePath
            DirectoryPath = [string](Split-Path -Path $row.Path -Parent)
        }
    }

    $disabledTasks = @()
    foreach ($row in @($disabledRows | Sort-Object Order, Name)) {
        $disabledTasks += [pscustomobject]@{
            Name = [string]$row.Name
            RelativePath = [string]$row.RelativePath
        }
    }

    return [ordered]@{
        ActiveTasks = $activeTasks
        DisabledTasks = $disabledTasks
    }
}

# Handles Get-AzVmTaskTokenReplacements.
function Get-AzVmTaskTokenReplacements {
    param(
        [hashtable]$Context
    )

    $tcpPorts = @(@($Context.TcpPorts) | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^\d+$' })
    $tcpPortsBash = $tcpPorts -join ' '
    $tcpRegex = (($tcpPorts | ForEach-Object { [regex]::Escape([string]$_) }) -join '|')
    $tcpPortsPsArray = $tcpPorts -join ','

    return @{
        VM_ADMIN_USER = [string]$Context.VmUser
        VM_ADMIN_PASS = [string]$Context.VmPass
        ASSISTANT_USER = [string]$Context.VmAssistantUser
        ASSISTANT_PASS = [string]$Context.VmAssistantPass
        SSH_PORT = [string]$Context.SshPort
        TCP_PORTS_BASH = [string]$tcpPortsBash
        TCP_PORTS_REGEX = [string]$tcpRegex
        TCP_PORTS_PS_ARRAY = [string]$tcpPortsPsArray
        SERVER_NAME = [string]$Context.ServerName
        RESOURCE_GROUP = [string]$Context.ResourceGroup
        VM_NAME = [string]$Context.VmName
        AZ_LOCATION = [string]$Context.AzLocation
        VM_SIZE = [string]$Context.VmSize
        VM_IMAGE = [string]$Context.VmImage
        VM_DISK_NAME = [string]$Context.VmDiskName
        VM_DISK_SIZE = [string]$Context.VmDiskSize
        VM_STORAGE_SKU = [string]$Context.VmStorageSku
    }
}

# Handles Resolve-AzVmRuntimeTaskBlocks.
function Resolve-AzVmRuntimeTaskBlocks {
    param(
        [object[]]$TemplateTaskBlocks,
        [hashtable]$Context
    )

    if (-not $TemplateTaskBlocks -or @($TemplateTaskBlocks).Count -eq 0) {
        throw 'Task template block list is empty.'
    }

    $replacements = Get-AzVmTaskTokenReplacements -Context $Context
    return @(Apply-AzVmTaskBlockReplacements -TaskBlocks $TemplateTaskBlocks -Replacements $replacements)
}



# Handles Resolve-AzVmTaskTimeoutSeconds.
function Resolve-AzVmTaskTimeoutSeconds {
    param(
        [string]$TaskName,
        [string]$TaskScript,
        [int]$DefaultTimeoutSeconds
    )

    $resolved = [int]$DefaultTimeoutSeconds
    if ($resolved -lt 5) { $resolved = 5 }
    if ($resolved -gt 7200) { $resolved = 7200 }

    if ([string]::IsNullOrWhiteSpace([string]$TaskScript)) {
        return $resolved
    }

    $pattern = '(?im)^\s*(?:#|//)\s*AZ_VM_TASK_TIMEOUT_SECONDS\s*=\s*(?<value>\d{1,5})\s*$'
    $match = [regex]::Match([string]$TaskScript, $pattern)
    if (-not $match.Success) {
        return $resolved
    }

    $candidate = [int]$match.Groups['value'].Value
    if ($candidate -lt 5) { $candidate = 5 }
    if ($candidate -gt 7200) { $candidate = 7200 }

    if ($candidate -ne $resolved) {
        Write-Host ("Task timeout override detected: {0} -> {1}s (default {2}s)." -f $TaskName, $candidate, $resolved) -ForegroundColor DarkCyan
    }

    return [int]$candidate
}

# Handles Invoke-AzVmSshTaskBlocks.
function Invoke-AzVmSshTaskBlocks {
    param(
        [ValidateSet('windows','linux')]
        [string]$Platform,
        [string]$RepoRoot,
        [string]$SshHost,
        [string]$SshUser,
        [string]$SshPassword,
        [string]$SshPort,
        [string]$ResourceGroup = '',
        [string]$VmName = '',
        [object[]]$TaskBlocks,
        [ValidateSet('continue','strict')]
        [string]$TaskOutcomeMode = 'continue',
        [ValidateSet('vm-update-task','exec-task')]
        [string]$PerfTaskCategory = 'vm-update-task',
        [int]$SshMaxRetries = 3,
        [int]$SshTaskTimeoutSeconds = 180,
        [int]$SshConnectTimeoutSeconds = 30,
        [string]$ConfiguredPySshClientPath = ''
    )

    if (-not $TaskBlocks -or @($TaskBlocks).Count -eq 0) {
        throw 'SSH task block list is empty.'
    }

    $SshMaxRetries = Resolve-AzVmSshRetryCount -RetryText ([string]$SshMaxRetries) -DefaultValue 3
    if ($SshTaskTimeoutSeconds -lt 30) { $SshTaskTimeoutSeconds = 30 }
    if ($SshTaskTimeoutSeconds -gt 7200) { $SshTaskTimeoutSeconds = 7200 }
    if ($SshConnectTimeoutSeconds -lt 5) { $SshConnectTimeoutSeconds = 5 }
    if ($SshConnectTimeoutSeconds -gt 300) { $SshConnectTimeoutSeconds = 300 }
    $pySsh = Ensure-AzVmPySshTools -RepoRoot $RepoRoot -ConfiguredPySshClientPath $ConfiguredPySshClientPath

    $bootstrap = Initialize-AzVmSshHostKey -PySshPythonPath ([string]$pySsh.PythonPath) -PySshClientPath ([string]$pySsh.ClientPath) -HostName $SshHost -UserName $SshUser -Password $SshPassword -Port $SshPort -ConnectTimeoutSeconds $SshConnectTimeoutSeconds
    if (-not [string]::IsNullOrWhiteSpace([string]$bootstrap.Output)) {
        Write-Host ([string]$bootstrap.Output)
    }
    Write-Host ("Resolved SSH host key for batch transport: {0}" -f [string]$bootstrap.HostKey)

    $shell = if ($Platform -eq 'windows') { 'powershell' } else { 'bash' }
    $session = $null
    $totalSuccess = 0
    $totalWarnings = 0
    $totalErrors = 0
    $rebootCount = 0
    $maxReboots = 3

    try {
        Write-Host 'VM update stage mode: tasks run one-by-one over a persistent SSH session.'
        Write-Host ("Task outcome policy: {0}" -f $TaskOutcomeMode)
        Write-Host ("SSH timeouts: task={0}s, connect={1}s" -f $SshTaskTimeoutSeconds, $SshConnectTimeoutSeconds) -ForegroundColor DarkCyan

        $session = Start-AzVmPersistentSshSession -PySshPythonPath ([string]$pySsh.PythonPath) -PySshClientPath ([string]$pySsh.ClientPath) -HostName $SshHost -UserName $SshUser -Password $SshPassword -Port $SshPort -Shell $shell -ConnectTimeoutSeconds $SshConnectTimeoutSeconds -DefaultTaskTimeoutSeconds $SshTaskTimeoutSeconds

        foreach ($task in @($TaskBlocks)) {
            $taskName = [string]$task.Name
            $taskScript = [string]$task.Script
            $taskTimeoutSeconds = Resolve-AzVmTaskTimeoutSeconds -TaskName $taskName -TaskScript $taskScript -DefaultTimeoutSeconds $SshTaskTimeoutSeconds
            $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $taskResult = $null
            $taskInvocationError = $null

            Write-Host ("Task started: {0}" -f $taskName)

            $assetCopies = @()
            if ($task.PSObject.Properties.Match('AssetCopies').Count -gt 0 -and $null -ne $task.AssetCopies) {
                $assetCopies = @(ConvertTo-ObjectArrayCompat -InputObject $task.AssetCopies)
            }
            foreach ($asset in @($assetCopies)) {
                $assetLocalPath = [string]$asset.LocalPath
                $assetRemotePath = [string]$asset.RemotePath
                if ([string]::IsNullOrWhiteSpace([string]$assetLocalPath) -or [string]::IsNullOrWhiteSpace([string]$assetRemotePath)) {
                    continue
                }

                Write-Host ("Task asset copy started: {0} -> {1}" -f $assetLocalPath, $assetRemotePath)
                Copy-AzVmAssetToVm `
                    -PySshPythonPath ([string]$pySsh.PythonPath) `
                    -PySshClientPath ([string]$pySsh.ClientPath) `
                    -HostName $SshHost `
                    -UserName $SshUser `
                    -Password $SshPassword `
                    -Port $SshPort `
                    -LocalPath $assetLocalPath `
                    -RemotePath $assetRemotePath `
                    -ConnectTimeoutSeconds $SshConnectTimeoutSeconds
                Write-Host ("Task asset copy completed: {0}" -f $assetRemotePath)
            }

            for ($attempt = 1; $attempt -le $SshMaxRetries; $attempt++) {
                $taskInvocationError = $null
                try {
                    $taskResult = Invoke-AzVmPersistentSshTask -Session $session -TaskName $taskName -TaskScript $taskScript -TimeoutSeconds $taskTimeoutSeconds
                    break
                }
                catch {
                    $taskInvocationError = $_
                    if ($attempt -lt $SshMaxRetries) {
                        Write-Warning ("Persistent SSH task execution failed for '{0}' (attempt {1}/{2}): {3}" -f $taskName, $attempt, $SshMaxRetries, $_.Exception.Message)
                        Stop-AzVmPersistentSshSession -Session $session
                        $session = Start-AzVmPersistentSshSession -PySshPythonPath ([string]$pySsh.PythonPath) -PySshClientPath ([string]$pySsh.ClientPath) -HostName $SshHost -UserName $SshUser -Password $SshPassword -Port $SshPort -Shell $shell -ConnectTimeoutSeconds $SshConnectTimeoutSeconds -DefaultTaskTimeoutSeconds $SshTaskTimeoutSeconds
                    }
                }
            }

            if ($taskWatch.IsRunning) { $taskWatch.Stop() }
            $taskElapsedSeconds = $taskWatch.Elapsed.TotalSeconds
            if ($script:PerfMode) {
                Write-AzVmPerfTiming -Category $PerfTaskCategory -Label $taskName -Seconds $taskElapsedSeconds
            }

            if ($null -ne $taskInvocationError) {
                if ($TaskOutcomeMode -eq 'continue') {
                    $totalWarnings++
                    Write-Warning ("Task warning: {0} failed in persistent session => {1}" -f $taskName, $taskInvocationError.Exception.Message)
                    Write-Host ("Task completed: {0} ({1:N1}s) - warning" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
                    continue
                }

                $totalErrors++
                Write-Host ("Task failed: {0}" -f $taskName) -ForegroundColor Red
                throw ("VM update task failed in persistent session: {0} => {1}" -f $taskName, $taskInvocationError.Exception.Message)
            }

            if ([int]$taskResult.ExitCode -eq 0) {
                $totalSuccess++
                Write-Host ("Task completed: {0} ({1:N1}s) - success" -f $taskName, $taskElapsedSeconds)
            }
            else {
                if ($TaskOutcomeMode -eq 'continue') {
                    $totalWarnings++
                    Write-Warning ("Task warning: {0} exited with code {1}" -f $taskName, $taskResult.ExitCode)
                    Write-Host ("Task completed: {0} ({1:N1}s) - warning" -f $taskName, $taskElapsedSeconds)
                }
                else {
                    $totalErrors++
                    Write-Host ("Task failed: {0}" -f $taskName) -ForegroundColor Red
                    throw ("VM update task failed: {0} (exit {1})" -f $taskName, $taskResult.ExitCode)
                }
            }

            $taskRequestedReboot = $false
            if ($taskResult -and $taskResult.PSObject.Properties.Match('Output').Count -gt 0) {
                $taskRequestedReboot = Test-AzVmOutputIndicatesRebootRequired -MessageText ([string]$taskResult.Output)
            }
            if ($taskRequestedReboot) {
                if ([string]::IsNullOrWhiteSpace([string]$ResourceGroup) -or [string]::IsNullOrWhiteSpace([string]$VmName)) {
                    throw ("Task '{0}' requested reboot but ResourceGroup/VmName was not provided." -f $taskName)
                }

                $rebootCount++
                if ($rebootCount -gt $maxReboots) {
                    throw ("VM update stage reboot limit exceeded ({0}). Last task requesting reboot: {1}" -f $maxReboots, $taskName)
                }

                Write-Host ("Task '{0}' requested reboot. Reboot workflow started ({1}/{2})." -f $taskName, $rebootCount, $maxReboots) -ForegroundColor Yellow
                if ($null -ne $session) {
                    Stop-AzVmPersistentSshSession -Session $session
                    $session = $null
                }

                Invoke-TrackedAction -Label ("az vm restart -g {0} -n {1}" -f $ResourceGroup, $VmName) -Action {
                    az vm restart --resource-group $ResourceGroup --name $VmName -o none
                    Assert-LastExitCode "az vm restart"
                } | Out-Null

                $running = Wait-AzVmVmRunningState -ResourceGroup $ResourceGroup -VmName $VmName -MaxAttempts 3 -DelaySeconds 10
                if (-not $running) {
                    throw ("VM '{0}' did not return to running state after reboot request from task '{1}'." -f $VmName, $taskName)
                }

                Write-Host 'Waiting 25 seconds for SSH service to stabilize after reboot...'
                Start-Sleep -Seconds 25

                $bootstrap = Initialize-AzVmSshHostKey -PySshPythonPath ([string]$pySsh.PythonPath) -PySshClientPath ([string]$pySsh.ClientPath) -HostName $SshHost -UserName $SshUser -Password $SshPassword -Port $SshPort -ConnectTimeoutSeconds $SshConnectTimeoutSeconds
                if (-not [string]::IsNullOrWhiteSpace([string]$bootstrap.Output)) {
                    Write-Host ([string]$bootstrap.Output)
                }

                $session = Start-AzVmPersistentSshSession -PySshPythonPath ([string]$pySsh.PythonPath) -PySshClientPath ([string]$pySsh.ClientPath) -HostName $SshHost -UserName $SshUser -Password $SshPassword -Port $SshPort -Shell $shell -ConnectTimeoutSeconds $SshConnectTimeoutSeconds -DefaultTaskTimeoutSeconds $SshTaskTimeoutSeconds
                Write-Host ("Persistent SSH task session resumed after reboot triggered by '{0}'." -f $taskName) -ForegroundColor DarkCyan
            }
        }

        Write-Host ("VM update stage summary: success={0}, warning={1}, error={2}, reboot={3}" -f $totalSuccess, $totalWarnings, $totalErrors, $rebootCount)
        if ($TaskOutcomeMode -eq 'strict' -and ($totalWarnings -gt 0 -or $totalErrors -gt 0)) {
            throw ("VM update strict task outcome mode blocked continuation: warning={0}, error={1}" -f $totalWarnings, $totalErrors)
        }

        return [pscustomobject]@{ SuccessCount = $totalSuccess; WarningCount = $totalWarnings; ErrorCount = $totalErrors; RebootCount = $rebootCount }
    }
    finally {
        if ($null -ne $session) {
            Stop-AzVmPersistentSshSession -Session $session
        }
    }
}

