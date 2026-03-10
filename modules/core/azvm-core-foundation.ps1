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

        $suppressAzStderrEcho = $false
        if ($script:SuppressAzCliStderrEcho) {
            $suppressAzStderrEcho = $true
        }
        if ((-not $suppressAzStderrEcho) -and -not [string]::IsNullOrWhiteSpace($stderrText)) {
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

# Handles Invoke-AzVmWithSuppressedAzCliStderr.
function Invoke-AzVmWithSuppressedAzCliStderr {
    param(
        [scriptblock]$Action
    )

    $previousValue = $false
    if ($script:SuppressAzCliStderrEcho) {
        $previousValue = $true
    }

    $script:SuppressAzCliStderrEcho = $true
    try {
        return (& $Action)
    }
    finally {
        $script:SuppressAzCliStderrEcho = $previousValue
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
            VmNameDefault = ''
            VmImageDefault = 'MicrosoftWindowsDesktop:office-365:win11-25h2-avd-m365:latest'
            VmSizeDefault = 'Standard_B4as_v2'
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
        VmNameDefault = ''
        VmImageDefault = 'Canonical:ubuntu-24_04-lts:server:latest'
        VmSizeDefault = 'Standard_B2as_v2'
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

# Handles Get-AzVmDefaultTcpPortsCsv.
function Get-AzVmDefaultSshPortText {
    return '444'
}

# Handles Get-AzVmDefaultRdpPortText.
function Get-AzVmDefaultRdpPortText {
    return '3389'
}

# Handles Get-AzVmDefaultTcpPortsCsv.
function Get-AzVmDefaultTcpPortsCsv {
    return '80,443,8444,389,5173,3000,3001,8080,5432,3306,6837,4000,4001,5000,5001,6000,6001,6060,7000,7001,7070,8000,8001,9000,9001,9090,2222,3333,4444,5555,6666,7777,8888,9999,11434'
}

# Handles Get-AzVmDefaultPySshClientPathText.
function Get-AzVmDefaultPySshClientPathText {
    return 'tools/pyssh/ssh_client.py'
}

# Handles Test-AzVmConfigPlaceholderValue.
function Test-AzVmConfigPlaceholderValue {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return $false
    }

    $normalized = $Value.Trim().ToLowerInvariant()
    return (
        $normalized.Contains('change_me') -or
        $normalized.Contains('changeme') -or
        $normalized.Contains('replace_me') -or
        $normalized.Contains('set_me') -or
        $normalized.Contains('todo') -or
        $normalized.StartsWith('<') -or
        $normalized.EndsWith('>')
    )
}

# Handles Get-AzVmResolvedConfigValue.
function Get-AzVmResolvedConfigValue {
    param(
        [hashtable]$ConfigMap,
        [string]$Key,
        [hashtable]$Tokens = @{},
        [string]$DefaultValue = ''
    )

    $rawValue = [string](Get-ConfigValue -Config $ConfigMap -Key $Key -DefaultValue $DefaultValue)
    return [string](Resolve-AzVmTemplate -Template $rawValue -Tokens $Tokens)
}

# Handles Get-AzVmRequiredResolvedConfigValue.
function Get-AzVmRequiredResolvedConfigValue {
    param(
        [hashtable]$ConfigMap,
        [string]$Key,
        [hashtable]$Tokens = @{},
        [string]$Summary,
        [string]$Hint,
        [int]$Code = 14,
        [string]$DefaultValue = ''
    )

    $resolvedValue = [string](Get-AzVmResolvedConfigValue -ConfigMap $ConfigMap -Key $Key -Tokens $Tokens -DefaultValue $DefaultValue)
    if ([string]::IsNullOrWhiteSpace([string]$resolvedValue)) {
        Throw-FriendlyError `
            -Detail ("Required config value '{0}' is not set." -f $Key) `
            -Code $Code `
            -Summary $Summary `
            -Hint $Hint
    }

    if (Test-AzVmConfigPlaceholderValue -Value $resolvedValue) {
        Throw-FriendlyError `
            -Detail ("Config value '{0}' still uses a placeholder value: '{1}'." -f $Key, $resolvedValue) `
            -Code $Code `
            -Summary $Summary `
            -Hint $Hint
    }

    return $resolvedValue
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
        RDP_PORT = [string]$Context.RdpPort
        TCP_PORTS_BASH = [string]$tcpPortsBash
        TCP_PORTS_REGEX = [string]$tcpRegex
        TCP_PORTS_PS_ARRAY = [string]$tcpPortsPsArray
        RESOURCE_GROUP = [string]$Context.ResourceGroup
        VM_NAME = [string]$Context.VmName
        COMPANY_NAME = [string]$Context.CompanyName
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



# Handles Get-AzVmTaskTimeoutSeconds.
function Get-AzVmTaskTimeoutSeconds {
    param(
        [psobject]$TaskBlock,
        [int]$DefaultTimeoutSeconds = 180
    )

    $taskTimeout = $DefaultTimeoutSeconds
    if ($null -ne $TaskBlock -and $TaskBlock.PSObject.Properties.Match('TimeoutSeconds').Count -gt 0) {
        $taskTimeout = [int](Convert-AzVmTaskCatalogTimeout -Value $TaskBlock.TimeoutSeconds -DefaultValue $DefaultTimeoutSeconds)
    }
    else {
        $taskTimeout = [int](Convert-AzVmTaskCatalogTimeout -Value $DefaultTimeoutSeconds -DefaultValue 180)
    }

    return [int]$taskTimeout
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
    $successfulTasks = @()
    $failedTasks = @()
    $rebootRequestedTasks = @()

    try {
        Write-Host 'VM update stage mode: tasks run one-by-one over a persistent SSH session.'
        Write-Host ("Task outcome policy: {0}" -f $TaskOutcomeMode)
        Write-Host ("SSH timeouts: task={0}s, connect={1}s" -f $SshTaskTimeoutSeconds, $SshConnectTimeoutSeconds) -ForegroundColor DarkCyan

        $session = Start-AzVmPersistentSshSession -PySshPythonPath ([string]$pySsh.PythonPath) -PySshClientPath ([string]$pySsh.ClientPath) -HostName $SshHost -UserName $SshUser -Password $SshPassword -Port $SshPort -Shell $shell -ConnectTimeoutSeconds $SshConnectTimeoutSeconds -DefaultTaskTimeoutSeconds $SshTaskTimeoutSeconds

        foreach ($task in @($TaskBlocks)) {
            $taskName = [string]$task.Name
            $taskScript = [string]$task.Script
            $taskTimeoutSeconds = Get-AzVmTaskTimeoutSeconds -TaskBlock $task -DefaultTimeoutSeconds $SshTaskTimeoutSeconds
            $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $taskResult = $null
            $taskInvocationError = $null

            Write-Host ("Task started: {0} (max {1}s)" -f $taskName, $taskTimeoutSeconds)

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
            if ($null -ne $taskResult) {
                $taskResult.DurationSeconds = [double]$taskElapsedSeconds
            }
            if ($script:PerfMode) {
                Write-AzVmPerfTiming -Category $PerfTaskCategory -Label $taskName -Seconds $taskElapsedSeconds
            }

            if ($null -ne $taskInvocationError) {
                $failedTasks += $taskName
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
                $successfulTasks += $taskName
                Write-Host ("Task completed: {0} ({1:N1}s) - success" -f $taskName, $taskElapsedSeconds)
            }
            else {
                $failedTasks += $taskName
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
                $rebootCount++
                $rebootRequestedTasks += $taskName
                Write-Host ("Task '{0}' requested a VM restart. The request was recorded and deferred until the vm-update stage completes." -f $taskName) -ForegroundColor Yellow
                if ($TaskOutcomeMode -eq 'continue' -and [int]$taskResult.ExitCode -eq 0) {
                    $totalWarnings++
                }
            }
        }

        $uniqueSuccessfulTasks = @($successfulTasks | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
        $uniqueFailedTasks = @($failedTasks | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

        Write-Host ("VM update stage summary: success={0}, failed={1}, warning={2}, error={3}, reboot={4}" -f @($uniqueSuccessfulTasks).Count, @($uniqueFailedTasks).Count, $totalWarnings, $totalErrors, $rebootCount)
        if (@($uniqueFailedTasks).Count -gt 0) {
            Write-Host 'Failed tasks:' -ForegroundColor Yellow
            foreach ($failedTaskName in @($uniqueFailedTasks)) {
                Write-Host ("- {0}" -f [string]$failedTaskName) -ForegroundColor Yellow
            }
        }
        if ($rebootCount -gt 0) {
            $rebootTaskList = @(
                $rebootRequestedTasks |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                    Select-Object -Unique
            )
            if (@($rebootTaskList).Count -eq 0) {
                $rebootTaskList = @('(task names unavailable)')
            }
            Write-Host 'VM restart requirement detected after vm-update.' -ForegroundColor Yellow
            Write-Host 'Tasks requesting restart:' -ForegroundColor Yellow
            foreach ($rebootTaskName in @($rebootTaskList)) {
                Write-Host ("- {0}" -f [string]$rebootTaskName) -ForegroundColor Yellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$ResourceGroup) -and -not [string]::IsNullOrWhiteSpace([string]$VmName)) {
                Write-Host ("Hint: restart the VM after step 6 finishes: az vm restart --resource-group {0} --name {1}" -f $ResourceGroup, $VmName) -ForegroundColor Cyan
            }
            else {
                Write-Host "Hint: restart the VM after step 6 finishes before relying on newly installed components." -ForegroundColor Cyan
            }
        }
        if ($TaskOutcomeMode -eq 'strict' -and ($totalWarnings -gt 0 -or $totalErrors -gt 0)) {
            throw ("VM update strict task outcome mode blocked continuation: warning={0}, error={1}" -f $totalWarnings, $totalErrors)
        }

        return [pscustomobject]@{
            SuccessCount = $totalSuccess
            SuccessTasks = @($uniqueSuccessfulTasks)
            FailedCount = @($uniqueFailedTasks).Count
            FailedTasks = @($uniqueFailedTasks)
            WarningCount = $totalWarnings
            ErrorCount = $totalErrors
            RebootCount = $rebootCount
            RebootRequired = ($rebootCount -gt 0)
            RebootRequestedTasks = @($rebootRequestedTasks | Select-Object -Unique)
        }
    }
    finally {
        if ($null -ne $session) {
            Stop-AzVmPersistentSshSession -Session $session
        }
    }
}

