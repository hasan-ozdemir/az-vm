<#
Script Filename: az-vm.ps1
Script Description:
- Unified Azure VM provisioning flow for Windows and Linux.
- OS selection: --windows or --linux (or VM_OS_TYPE from .env).
- Windows init tasks run once on first VM creation via Custom Script Extension.
- Update tasks run via persistent pyssh task-by-task.
#>

param(
    [Alias('a','NonInteractive')]
    [switch]$Auto,
    [Alias('u')]
    [switch]$Update,
    [Alias('r')]
    [switch]$destructive rebuild,
    [Alias('p')]
    [switch]$Perf,
    [switch]$Windows,
    [switch]$Linux
)

$script:AutoMode = [bool]$Auto
$script:UpdateMode = [bool]$Update
$script:RenewMode = [bool]$destructive rebuild
$script:PerfMode = [bool]$Perf
$script:TranscriptStarted = $false
$script:HadError = $false
$script:ExitCode = 0
$script:ConfigOverrides = @{}
$script:ExecutionMode = if ($script:RenewMode) { 'destructive rebuild' } elseif ($script:UpdateMode) { 'update' } else { 'default' }
$script:AzCommandTimeoutSeconds = 1800
$script:SshTaskTimeoutSeconds = 180
$script:SshConnectTimeoutSeconds = 30
$script:AzCliExecutable = $null

$script:DefaultErrorSummary = 'An unexpected error occurred.'
$script:DefaultErrorHint = 'Review the error line and check script parameters and Azure connectivity.'

function Get-CoVmAzCliExecutable {
    if (-not [string]::IsNullOrWhiteSpace([string]$script:AzCliExecutable)) {
        return [string]$script:AzCliExecutable
    }

    $azApp = Get-Command az -All -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' } | Select-Object -First 1
    if ($null -eq $azApp -or [string]::IsNullOrWhiteSpace([string]$azApp.Source)) {
        throw "Azure CLI executable could not be resolved from PATH."
    }

    $script:AzCliExecutable = [string]$azApp.Source
    return [string]$script:AzCliExecutable
}

function Invoke-CoVmAzCliCommand {
    param(
        [string[]]$Arguments
    )

    $azExecutable = Get-CoVmAzCliExecutable
    $argValues = @($Arguments | ForEach-Object { [string]$_ })
    $timeoutSeconds = [int]$script:AzCommandTimeoutSeconds
    if ($timeoutSeconds -lt 0) { $timeoutSeconds = 0 }

    if ($timeoutSeconds -eq 0) {
        & $azExecutable @argValues
        return
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $azExecutable
    $psi.Arguments = ($argValues | ForEach-Object { Convert-CoVmProcessArgument -Value ([string]$_) }) -join ' '
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

function az {
    $argList = @()
    foreach ($arg in @($args)) {
        $argList += [string]$arg
    }

    return (Invoke-CoVmAzCliCommand -Arguments $argList)
}

function Get-CoVmPlatformDefaults {
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

function Resolve-CoVmPlatformConfigMap {
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

    $prefix = if ($Platform -eq 'windows') { 'WIN_' } else { 'LIN_' }
    foreach ($key in @($resolved.Keys)) {
        $keyText = [string]$key
        if (-not $keyText.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $genericKey = $keyText.Substring($prefix.Length)
        if ([string]::IsNullOrWhiteSpace($genericKey)) {
            continue
        }

        $genericValue = ''
        if ($resolved.ContainsKey($genericKey)) {
            $genericValue = [string]$resolved[$genericKey]
        }

        if ([string]::IsNullOrWhiteSpace($genericValue)) {
            $resolved[$genericKey] = [string]$resolved[$keyText]
        }
    }

    $resolved['VM_OS_TYPE'] = $Platform
    return $resolved
}

function Resolve-CoVmPlatformSelection {
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

function Get-CoVmTaskBlocksFromDirectory {
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
    if ($files.Count -eq 0) {
        return [ordered]@{
            ActiveTasks = @()
            DisabledTasks = @()
        }
    }

    $activeRows = @()
    $disabledRows = @()
    foreach ($file in $files) {
        $name = [string]$file.Name
        if ($name.StartsWith('.')) {
            continue
        }

        $fileExt = [System.IO.Path]::GetExtension($name)
        if (-not [string]::Equals($fileExt, $expectedExt, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ("Task file '{0}' has invalid extension for platform '{1}'. Expected '{2}'." -f $name, $Platform, $expectedExt)
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

    $activeTasks = @()
    foreach ($row in @($activeRows | Sort-Object Order, Name)) {
        $content = Get-Content -Path $row.Path -Raw
        $activeTasks += [pscustomobject]@{
            Name = [string]$row.Name
            Script = [string]$content
            RelativePath = [string]$row.RelativePath
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

function Get-CoVmTaskTokenReplacements {
    param(
        [hashtable]$Context
    )

    $tcpPorts = @(@($Context.TcpPorts) | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^\d+$' })
    $tcpPortsBash = $tcpPorts -join ' '
    $tcpRegex = (($tcpPorts | ForEach-Object { [regex]::Escape([string]$_) }) -join '|')
    $tcpPortsPsArray = $tcpPorts -join ','

    return @{
        VM_USER = [string]$Context.VmUser
        VM_PASS = [string]$Context.VmPass
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

function Resolve-CoVmRuntimeTaskBlocks {
    param(
        [object[]]$TemplateTaskBlocks,
        [hashtable]$Context
    )

    if (-not $TemplateTaskBlocks -or @($TemplateTaskBlocks).Count -eq 0) {
        throw 'Task template block list is empty.'
    }

    $replacements = Get-CoVmTaskTokenReplacements -Context $Context
    return @(Apply-CoVmTaskBlockReplacements -TaskBlocks $TemplateTaskBlocks -Replacements $replacements)
}



function Resolve-CoVmTaskTimeoutSeconds {
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

    $pattern = '(?im)^\s*(?:#|//)\s*CO_VM_TASK_TIMEOUT_SECONDS\s*=\s*(?<value>\d{1,5})\s*$'
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

function Invoke-CoVmSshTaskBlocks {
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
        [int]$SshMaxRetries = 3,
        [int]$SshTaskTimeoutSeconds = 180,
        [int]$SshConnectTimeoutSeconds = 30,
        [string]$ConfiguredPySshClientPath = ''
    )

    if (-not $TaskBlocks -or @($TaskBlocks).Count -eq 0) {
        throw 'SSH task block list is empty.'
    }

    $SshMaxRetries = Resolve-CoVmSshRetryCount -RetryText ([string]$SshMaxRetries) -DefaultValue 3
    if ($SshTaskTimeoutSeconds -lt 30) { $SshTaskTimeoutSeconds = 30 }
    if ($SshTaskTimeoutSeconds -gt 7200) { $SshTaskTimeoutSeconds = 7200 }
    if ($SshConnectTimeoutSeconds -lt 5) { $SshConnectTimeoutSeconds = 5 }
    if ($SshConnectTimeoutSeconds -gt 300) { $SshConnectTimeoutSeconds = 300 }
    $pySsh = Ensure-CoVmPySshTools -RepoRoot $RepoRoot -ConfiguredPySshClientPath $ConfiguredPySshClientPath

    $bootstrap = Initialize-CoVmSshHostKey -PySshClientPath ([string]$pySsh.ClientPath) -HostName $SshHost -UserName $SshUser -Password $SshPassword -Port $SshPort -ConnectTimeoutSeconds $SshConnectTimeoutSeconds
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
        Write-Host 'Task-by-task mode is enabled: Step 8 tasks are executed one-by-one over SSH.'
        Write-Host 'Persistent SSH task session is enabled: one SSH connection will be reused for Step 8 tasks.' -ForegroundColor DarkCyan
        Write-Host ("Task outcome mode: {0}" -f $TaskOutcomeMode)
        Write-Host ("SSH task timeout: {0}s | SSH connect timeout: {1}s" -f $SshTaskTimeoutSeconds, $SshConnectTimeoutSeconds) -ForegroundColor DarkCyan

        $session = Start-CoVmPersistentSshSession -PySshClientPath ([string]$pySsh.ClientPath) -HostName $SshHost -UserName $SshUser -Password $SshPassword -Port $SshPort -Shell $shell -ConnectTimeoutSeconds $SshConnectTimeoutSeconds -DefaultTaskTimeoutSeconds $SshTaskTimeoutSeconds

        foreach ($task in @($TaskBlocks)) {
            $taskName = [string]$task.Name
            $taskScript = [string]$task.Script
            $taskTimeoutSeconds = Resolve-CoVmTaskTimeoutSeconds -TaskName $taskName -TaskScript $taskScript -DefaultTimeoutSeconds $SshTaskTimeoutSeconds
            $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $taskResult = $null
            $taskInvocationError = $null

            Write-Host ("TASK started: {0}" -f $taskName)

            for ($attempt = 1; $attempt -le $SshMaxRetries; $attempt++) {
                $taskInvocationError = $null
                try {
                    $taskResult = Invoke-CoVmPersistentSshTask -Session $session -TaskName $taskName -TaskScript $taskScript -TimeoutSeconds $taskTimeoutSeconds
                    break
                }
                catch {
                    $taskInvocationError = $_
                    if ($attempt -lt $SshMaxRetries) {
                        Write-Warning ("Persistent SSH task execution failed for '{0}' (attempt {1}/{2}): {3}" -f $taskName, $attempt, $SshMaxRetries, $_.Exception.Message)
                        Stop-CoVmPersistentSshSession -Session $session
                        $session = Start-CoVmPersistentSshSession -PySshClientPath ([string]$pySsh.ClientPath) -HostName $SshHost -UserName $SshUser -Password $SshPassword -Port $SshPort -Shell $shell -ConnectTimeoutSeconds $SshConnectTimeoutSeconds -DefaultTaskTimeoutSeconds $SshTaskTimeoutSeconds
                    }
                }
            }

            if ($taskWatch.IsRunning) { $taskWatch.Stop() }

            if ($null -ne $taskInvocationError) {
                if ($TaskOutcomeMode -eq 'continue') {
                    $totalWarnings++
                    Write-Warning ("TASK warning: {0} failed in persistent session => {1}" -f $taskName, $taskInvocationError.Exception.Message)
                    Write-Host ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
                    Write-Host 'TASK result: warning'
                    Write-Host ("TASK_STATUS:{0}:warning" -f $taskName)
                    continue
                }

                $totalErrors++
                Write-Host ("TASK result: failure ({0})" -f $taskName) -ForegroundColor Red
                Write-Host ("TASK_STATUS:{0}:error" -f $taskName)
                throw ("Step 8 SSH task failed in persistent session: {0} => {1}" -f $taskName, $taskInvocationError.Exception.Message)
            }

            if ([int]$taskResult.ExitCode -eq 0) {
                $totalSuccess++
                Write-Host ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
                Write-Host 'TASK result: success'
                Write-Host ("TASK_STATUS:{0}:success" -f $taskName)
            }
            else {
                if ($TaskOutcomeMode -eq 'continue') {
                    $totalWarnings++
                    Write-Warning ("TASK warning: {0} exited with code {1}" -f $taskName, $taskResult.ExitCode)
                    Write-Host ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
                    Write-Host 'TASK result: warning'
                    Write-Host ("TASK_STATUS:{0}:warning" -f $taskName)
                }
                else {
                    $totalErrors++
                    Write-Host ("TASK result: failure ({0})" -f $taskName) -ForegroundColor Red
                    Write-Host ("TASK_STATUS:{0}:error" -f $taskName)
                    throw ("Step 8 SSH task failed: {0} (exit {1})" -f $taskName, $taskResult.ExitCode)
                }
            }

            $taskRequestedReboot = $false
            if ($taskResult -and $taskResult.PSObject.Properties.Match('Output').Count -gt 0) {
                $taskRequestedReboot = Test-CoVmOutputIndicatesRebootRequired -MessageText ([string]$taskResult.Output)
            }
            if ($taskRequestedReboot) {
                if ([string]::IsNullOrWhiteSpace([string]$ResourceGroup) -or [string]::IsNullOrWhiteSpace([string]$VmName)) {
                    throw ("Task '{0}' requested reboot but ResourceGroup/VmName was not provided." -f $taskName)
                }

                $rebootCount++
                if ($rebootCount -gt $maxReboots) {
                    throw ("Step 8 reboot limit exceeded ({0}). Last task requesting reboot: {1}" -f $maxReboots, $taskName)
                }

                Write-Host ("Task '{0}' requested reboot. Reboot workflow started ({1}/{2})." -f $taskName, $rebootCount, $maxReboots) -ForegroundColor Yellow
                if ($null -ne $session) {
                    Stop-CoVmPersistentSshSession -Session $session
                    $session = $null
                }

                Invoke-TrackedAction -Label ("az vm restart -g {0} -n {1}" -f $ResourceGroup, $VmName) -Action {
                    az vm restart --resource-group $ResourceGroup --name $VmName -o none
                    Assert-LastExitCode "az vm restart"
                } | Out-Null

                $running = Wait-CoVmVmRunningState -ResourceGroup $ResourceGroup -VmName $VmName -MaxAttempts 90 -DelaySeconds 10
                if (-not $running) {
                    throw ("VM '{0}' did not return to running state after reboot request from task '{1}'." -f $VmName, $taskName)
                }

                Write-Host 'Waiting 25 seconds for SSH service to stabilize after reboot...'
                Start-Sleep -Seconds 25

                $bootstrap = Initialize-CoVmSshHostKey -PySshClientPath ([string]$pySsh.ClientPath) -HostName $SshHost -UserName $SshUser -Password $SshPassword -Port $SshPort -ConnectTimeoutSeconds $SshConnectTimeoutSeconds
                if (-not [string]::IsNullOrWhiteSpace([string]$bootstrap.Output)) {
                    Write-Host ([string]$bootstrap.Output)
                }

                $session = Start-CoVmPersistentSshSession -PySshClientPath ([string]$pySsh.ClientPath) -HostName $SshHost -UserName $SshUser -Password $SshPassword -Port $SshPort -Shell $shell -ConnectTimeoutSeconds $SshConnectTimeoutSeconds -DefaultTaskTimeoutSeconds $SshTaskTimeoutSeconds
                Write-Host ("Persistent SSH task session resumed after reboot triggered by '{0}'." -f $taskName) -ForegroundColor DarkCyan
            }
        }

        Write-Host ("STEP8_SUMMARY:success={0};warning={1};error={2};reboot={3}" -f $totalSuccess, $totalWarnings, $totalErrors, $rebootCount)
        if ($TaskOutcomeMode -eq 'strict' -and ($totalWarnings -gt 0 -or $totalErrors -gt 0)) {
            throw ("Step 8 strict task outcome mode blocked continuation: warning={0}, error={1}" -f $totalWarnings, $totalErrors)
        }

        return [pscustomobject]@{ SuccessCount = $totalSuccess; WarningCount = $totalWarnings; ErrorCount = $totalErrors; RebootCount = $rebootCount }
    }
    finally {
        if ($null -ne $session) {
            Stop-CoVmPersistentSshSession -Session $session
        }
    }
}

function Invoke-AzVmMain {
    param(
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    try {
        chcp 65001 | Out-Null
        $Host.UI.RawUI.WindowTitle = 'az vm'

        Write-Host 'script filename: az-vm.ps1'
        Write-Host "script description:
- A unified Linux/Windows virtual machine deployment flow is executed.
- OS type is selected by --windows/--linux or VM_OS_TYPE from .env.
- Windows init tasks run once on first VM creation via Custom Script Extension.
- Update tasks run via persistent pyssh task-by-task.
- SSH (default 444) and RDP (Windows) access are prepared.
- Run mode: interactive (default), auto (--auto / -a).
- Performance timing mode: --perf / -p.
- Default mode: existing resources are kept and skipped; missing resources are created.
- Update mode: --update / -u (creation commands always run; no delete flow).
- destructive rebuild mode: explicit destructive rebuild flow / -r (interactive delete confirmation, auto delete in --auto mode, then creation commands always run)."
        if ($script:RenewMode -and $script:UpdateMode) {
            Write-Host 'Both explicit destructive rebuild flow and --update were provided. destructive rebuild mode takes precedence.' -ForegroundColor Yellow
        }

        if (-not $script:AutoMode) {
            Read-Host -Prompt 'Press Enter to start...' | Out-Null
        }

        $envFilePath = Join-Path $PSScriptRoot '.env'
        $configMap = Read-DotEnvFile -Path $envFilePath

        $platform = Resolve-CoVmPlatformSelection -ConfigMap $configMap -EnvFilePath $envFilePath -AutoMode:$script:AutoMode -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -ConfigOverrides $script:ConfigOverrides
        $platformDefaults = Get-CoVmPlatformDefaults -Platform $platform
        $effectiveConfigMap = Resolve-CoVmPlatformConfigMap -ConfigMap $configMap -Platform $platform

        $logTimestamp = (Get-Date).ToString('ddMMMyy-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture).ToLowerInvariant()
        $logPath = Join-Path $PSScriptRoot ("az-vm-log-{0}.txt" -f $logTimestamp)

        Start-Transcript -Path $logPath -Force
        $script:TranscriptStarted = $true

        Invoke-Step 'Step 1/9 - initial parameters will be configured...' {
            $step1Context = Invoke-CoVmStep1Common `
                -ConfigMap $effectiveConfigMap `
                -EnvFilePath $envFilePath `
                -AutoMode:$script:AutoMode `
                -ScriptRoot $PSScriptRoot `
                -ServerNameDefault ([string]$platformDefaults.ServerNameDefault) `
                -VmImageDefault ([string]$platformDefaults.VmImageDefault) `
                -VmDiskSizeDefault ([string]$platformDefaults.VmDiskSizeDefault) `
                -VmUpdateConfigKey 'VM_UPDATE_TASK_DIR' `
                -VmUpdateDefault ([string]$platformDefaults.VmUpdateTaskDirDefault) `
                -ConfigOverrides $script:ConfigOverrides

            $serverName = [string]$step1Context.ServerName
            $resourceGroup = [string]$step1Context.ResourceGroup
            $defaultAzLocation = [string]$step1Context.DefaultAzLocation
            $VNET = [string]$step1Context.VNET
            $SUBNET = [string]$step1Context.SUBNET
            $NSG = [string]$step1Context.NSG
            $nsgRule = [string]$step1Context.NsgRule
            $IP = [string]$step1Context.IP
            $NIC = [string]$step1Context.NIC
            $vmName = [string]$step1Context.VmName
            $vmImage = [string]$step1Context.VmImage
            $vmStorageSku = [string]$step1Context.VmStorageSku
            $defaultVmSize = [string]$step1Context.DefaultVmSize
            $azLocation = [string]$step1Context.AzLocation
            $vmSize = [string]$step1Context.VmSize
            $vmDiskName = [string]$step1Context.VmDiskName
            $vmDiskSize = [string]$step1Context.VmDiskSize
            $vmUser = [string]$step1Context.VmUser
            $vmPass = [string]$step1Context.VmPass
            $vmAssistantUser = [string]$step1Context.VmAssistantUser
            $vmAssistantPass = [string]$step1Context.VmAssistantPass
            $sshPort = [string]$step1Context.SshPort
            $tcpPorts = @($step1Context.TcpPorts)

            $vmInitTaskDirName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $effectiveConfigMap -Key 'VM_INIT_TASK_DIR' -DefaultValue ([string]$platformDefaults.VmInitTaskDirDefault)) -ServerName $serverName
            $vmUpdateTaskDirName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $effectiveConfigMap -Key 'VM_UPDATE_TASK_DIR' -DefaultValue ([string]$platformDefaults.VmUpdateTaskDirDefault)) -ServerName $serverName
            $vmInitTaskDir = Resolve-ConfigPath -PathValue $vmInitTaskDirName -RootPath $PSScriptRoot
            $vmUpdateTaskDir = Resolve-ConfigPath -PathValue $vmUpdateTaskDirName -RootPath $PSScriptRoot

            $step1Context['VmInitTaskDir'] = $vmInitTaskDir
            $step1Context['VmUpdateTaskDir'] = $vmUpdateTaskDir
            $step1Context['VmOsType'] = $platform

            $taskOutcomeModeRaw = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'TASK_OUTCOME_MODE' -DefaultValue 'continue')
            if ([string]::IsNullOrWhiteSpace($taskOutcomeModeRaw)) { $taskOutcomeModeRaw = 'continue' }
            $taskOutcomeMode = $taskOutcomeModeRaw.Trim().ToLowerInvariant()
            if ($taskOutcomeMode -ne 'continue' -and $taskOutcomeMode -ne 'strict') {
                Write-Warning ("Invalid TASK_OUTCOME_MODE '{0}'. Falling back to 'continue'." -f $taskOutcomeModeRaw)
                $taskOutcomeMode = 'continue'
            }

            $sshMaxRetriesText = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'SSH_MAX_RETRIES' -DefaultValue '3')
            $sshMaxRetries = 1
            if ($sshMaxRetriesText -match '^\d+$') {
                $sshMaxRetries = [int]$sshMaxRetriesText
                if ($sshMaxRetries -lt 1) { $sshMaxRetries = 1 }
                if ($sshMaxRetries -gt 3) { $sshMaxRetries = 3 }
            }
            if ($platform -eq 'windows') {
                $taskOutcomeMode = 'strict'
                $sshMaxRetries = 1
            }
            $configuredPySshClientPath = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'PYSSH_CLIENT_PATH' -DefaultValue '')
            $sshTaskTimeoutText = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'SSH_TASK_TIMEOUT_SECONDS' -DefaultValue ([string]$script:SshTaskTimeoutSeconds))
            $sshTaskTimeoutSeconds = $script:SshTaskTimeoutSeconds
            if ($sshTaskTimeoutText -match '^\d+$') {
                $sshTaskTimeoutSeconds = [int]$sshTaskTimeoutText
            }
            if ($sshTaskTimeoutSeconds -lt 30) { $sshTaskTimeoutSeconds = 30 }
            if ($sshTaskTimeoutSeconds -gt 7200) { $sshTaskTimeoutSeconds = 7200 }

            $sshConnectTimeoutText = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'SSH_CONNECT_TIMEOUT_SECONDS' -DefaultValue ([string]$script:SshConnectTimeoutSeconds))
            $sshConnectTimeoutSeconds = $script:SshConnectTimeoutSeconds
            if ($sshConnectTimeoutText -match '^\d+$') {
                $sshConnectTimeoutSeconds = [int]$sshConnectTimeoutText
            }
            if ($sshConnectTimeoutSeconds -lt 5) { $sshConnectTimeoutSeconds = 5 }
            if ($sshConnectTimeoutSeconds -gt 300) { $sshConnectTimeoutSeconds = 300 }

            $azCommandTimeoutText = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'AZ_COMMAND_TIMEOUT_SECONDS' -DefaultValue ([string]$script:AzCommandTimeoutSeconds))
            $azCommandTimeoutSeconds = $script:AzCommandTimeoutSeconds
            if ($azCommandTimeoutText -match '^\d+$') {
                $azCommandTimeoutSeconds = [int]$azCommandTimeoutText
            }
            if ($azCommandTimeoutSeconds -lt 30) { $azCommandTimeoutSeconds = 30 }
            if ($azCommandTimeoutSeconds -gt 7200) { $azCommandTimeoutSeconds = 7200 }

            $script:AzCommandTimeoutSeconds = $azCommandTimeoutSeconds
            $script:SshTaskTimeoutSeconds = $sshTaskTimeoutSeconds
            $script:SshConnectTimeoutSeconds = $sshConnectTimeoutSeconds
            $step1Context['AzCommandTimeoutSeconds'] = $azCommandTimeoutSeconds
            $step1Context['SshTaskTimeoutSeconds'] = $sshTaskTimeoutSeconds
            $step1Context['SshConnectTimeoutSeconds'] = $sshConnectTimeoutSeconds

            if ($script:AutoMode) {
                Show-CoVmRuntimeConfigurationSnapshot -Platform $platform -ScriptName 'az-vm.ps1' -ScriptRoot $PSScriptRoot -AutoMode:$script:AutoMode -UpdateMode:$script:UpdateMode -RenewMode:$script:RenewMode -ConfigMap $effectiveConfigMap -ConfigOverrides $script:ConfigOverrides -Context $step1Context
            }
        }

        Invoke-Step 'Step 2/9 - region, image, and VM size availability will be checked...' {
            Invoke-CoVmPrecheckStep -Context $step1Context
        }

        Invoke-Step 'Step 3/9 - resource group will be checked...' {
            Invoke-CoVmResourceGroupStep -Context $step1Context -AutoMode:$script:AutoMode -UpdateMode:$script:UpdateMode -ExecutionMode $script:ExecutionMode
        }

        Invoke-Step 'Step 4/9 - VNet, subnet, NSG, NSG rules, public IP, and NIC will be created...' {
            Invoke-CoVmNetworkStep -Context $step1Context -ExecutionMode $script:ExecutionMode
        }

        Invoke-Step 'Step 5/9 - VM init task files will be prepared...' {
            Show-CoVmStepFirstUseValues -StepLabel 'Step 5/9 - init task catalog' -Context $step1Context -ExtraValues @{ Platform = $platform; VmInitTaskDir = $vmInitTaskDir }
            $initTaskCatalog = Get-CoVmTaskBlocksFromDirectory -DirectoryPath $vmInitTaskDir -Platform $platform -Stage 'init'
            $initTaskTemplates = @($initTaskCatalog.ActiveTasks)
            $initDisabledTasks = @($initTaskCatalog.DisabledTasks)
            if (@($initTaskTemplates).Count -gt 0) {
                $initTaskBlocks = @(Resolve-CoVmRuntimeTaskBlocks -TemplateTaskBlocks $initTaskTemplates -Context $step1Context)
            }
            else {
                $initTaskBlocks = @()
            }
            Show-CoVmStepFirstUseValues -StepLabel 'Step 5/9 - init task catalog' -Context $step1Context -ExtraValues @{
                InitTaskCount = @($initTaskBlocks).Count
                InitDisabledTaskCount = @($initDisabledTasks).Count
            }
            if (@($initDisabledTasks).Count -gt 0) {
                $initDisabledNames = @($initDisabledTasks | ForEach-Object { [string]$_.Name })
                Write-Host ("Disabled init tasks (ignored): {0}" -f ($initDisabledNames -join ', ')) -ForegroundColor Yellow
            }
        }

        Invoke-Step 'Step 6/9 - VM update task files will be prepared...' {
            Show-CoVmStepFirstUseValues -StepLabel 'Step 6/9 - update task catalog' -Context $step1Context -ExtraValues @{ Platform = $platform; VmUpdateTaskDir = $vmUpdateTaskDir }
            $updateTaskCatalog = Get-CoVmTaskBlocksFromDirectory -DirectoryPath $vmUpdateTaskDir -Platform $platform -Stage 'update'
            $updateTaskTemplates = @($updateTaskCatalog.ActiveTasks)
            $updateDisabledTasks = @($updateTaskCatalog.DisabledTasks)
            if (@($updateTaskTemplates).Count -gt 0) {
                $updateTaskBlocks = @(Resolve-CoVmRuntimeTaskBlocks -TemplateTaskBlocks $updateTaskTemplates -Context $step1Context)
            }
            else {
                $updateTaskBlocks = @()
            }
            Show-CoVmStepFirstUseValues -StepLabel 'Step 6/9 - update task catalog' -Context $step1Context -ExtraValues @{
                UpdateTaskCount = @($updateTaskBlocks).Count
                UpdateDisabledTaskCount = @($updateDisabledTasks).Count
                TaskOutcomeMode = $taskOutcomeMode
            }
            if (@($updateDisabledTasks).Count -gt 0) {
                $updateDisabledNames = @($updateDisabledTasks | ForEach-Object { [string]$_.Name })
                Write-Host ("Disabled update tasks (ignored): {0}" -f ($updateDisabledNames -join ', ')) -ForegroundColor Yellow
            }
        }

        Invoke-Step 'Step 7/9 - virtual machine will be created...' {
            if ($platform -eq 'windows') {
                $step7VmCreateResult = Invoke-CoVmVmCreateStep -Context $step1Context -AutoMode:$script:AutoMode -UpdateMode:$script:UpdateMode -ExecutionMode $script:ExecutionMode -CreateVmAction {
                    az vm create --resource-group $resourceGroup --name $vmName --image $vmImage --size $vmSize --storage-sku $vmStorageSku --os-disk-name $vmDiskName --os-disk-size-gb $vmDiskSize --admin-username $vmUser --admin-password $vmPass --authentication-type password --nics $NIC -o json
                }
            }
            else {
                $step7VmCreateResult = Invoke-CoVmVmCreateStep -Context $step1Context -AutoMode:$script:AutoMode -UpdateMode:$script:UpdateMode -ExecutionMode $script:ExecutionMode -CreateVmAction {
                    az vm create --resource-group $resourceGroup --name $vmName --image $vmImage --size $vmSize --storage-sku $vmStorageSku --os-disk-name $vmDiskName --os-disk-size-gb $vmDiskSize --admin-username $vmUser --admin-password $vmPass --authentication-type password --nics $NIC -o json
                }
            }
        }

        Invoke-Step 'Step 8/9 - VM init and update tasks will be executed...' {
            $vmCreatedThisRun = $false
            if ($step7VmCreateResult -and $step7VmCreateResult.PSObject.Properties.Match('VmCreatedThisRun').Count -gt 0) {
                $vmCreatedThisRun = [bool]$step7VmCreateResult.VmCreatedThisRun
            }
            $shouldRunInitTasks = ($vmCreatedThisRun -or $script:UpdateMode -or $script:RenewMode)

            $initExecutorLabel = 'az-vm-run-command'
            Show-CoVmStepFirstUseValues -StepLabel 'Step 8/9 - guest execution' -Context $step1Context -ExtraValues @{
                Platform = $platform
                InitExecutor = $initExecutorLabel
                UpdateExecutor = 'pyssh-persistent'
                RunCommandId = [string]$platformDefaults.RunCommandId
                InitTaskCount = @($initTaskBlocks).Count
                UpdateTaskCount = @($updateTaskBlocks).Count
                TaskOutcomeMode = $taskOutcomeMode
                SshMaxRetries = $sshMaxRetries
                SshTaskTimeoutSeconds = $sshTaskTimeoutSeconds
                SshConnectTimeoutSeconds = $sshConnectTimeoutSeconds
                PySshClientPath = $configuredPySshClientPath
                VmCreatedThisRun = $vmCreatedThisRun
                ShouldRunInitTasks = $shouldRunInitTasks
            }

            if ($shouldRunInitTasks -and @($initTaskBlocks).Count -gt 0) {
                $combinedShell = if ($platform -eq 'linux') { 'bash' } else { 'powershell' }
                Invoke-VmRunCommandBlocks -ResourceGroup $resourceGroup -VmName $vmName -CommandId ([string]$platformDefaults.RunCommandId) -TaskBlocks $initTaskBlocks -CombinedShell $combinedShell | Out-Null
            }
            elseif (-not $shouldRunInitTasks) {
                Write-Host 'Default mode with existing VM: init tasks are skipped; proceeding directly to update tasks.' -ForegroundColor Yellow
            }
            else {
                Write-Host 'Init task catalog is empty; Step 8 init stage is skipped.' -ForegroundColor Yellow
            }

            if ($shouldRunInitTasks) {
                Write-Host 'Waiting 20 seconds for SSH service to settle after init...'
                Start-Sleep -Seconds 20
            }

            $vmRuntimeDetails = Get-CoVmVmDetails -Context $step1Context
            $sshHost = [string]$vmRuntimeDetails.VmFqdn
            if ([string]::IsNullOrWhiteSpace($sshHost)) {
                $sshHost = [string]$vmRuntimeDetails.PublicIP
            }
            if ([string]::IsNullOrWhiteSpace($sshHost)) {
                throw 'Step 8 could not resolve VM SSH host (FQDN/Public IP).'
            }

            $step8SshUser = [string]$vmUser
            $step8SshPassword = [string]$vmPass

            Show-CoVmStepFirstUseValues -StepLabel 'Step 8/9 - guest execution' -Context $step1Context -ExtraValues @{ Step8SshHost = $sshHost; Step8SshUser = $step8SshUser; Step8SshPort = $sshPort }

            if (@($updateTaskBlocks).Count -eq 0) {
                Write-Host 'Update task catalog is empty; Step 8 update stage is skipped.' -ForegroundColor Yellow
            }
            else {
                Invoke-CoVmSshTaskBlocks -Platform $platform -RepoRoot $PSScriptRoot -SshHost $sshHost -SshUser $step8SshUser -SshPassword $step8SshPassword -SshPort $sshPort -ResourceGroup $resourceGroup -VmName $vmName -TaskBlocks $updateTaskBlocks -TaskOutcomeMode $taskOutcomeMode -SshMaxRetries $sshMaxRetries -SshTaskTimeoutSeconds $sshTaskTimeoutSeconds -SshConnectTimeoutSeconds $sshConnectTimeoutSeconds -ConfiguredPySshClientPath $configuredPySshClientPath | Out-Null
            }
        }

        Invoke-Step 'Step 9/9 - VM connection details will be printed...' {
            Show-CoVmStepFirstUseValues -StepLabel 'Step 9/9 - connection output' -Context $step1Context -ExtraValues @{ Platform = $platform; ManagerUser = $vmUser; AssistantUser = $vmAssistantUser }

            if ([bool]$platformDefaults.IncludeRdp) {
                $connectionModel = Get-CoVmConnectionDisplayModel -Context $step1Context -ManagerUser $vmUser -AssistantUser $vmAssistantUser -SshPort $sshPort -IncludeRdp
            }
            else {
                $connectionModel = Get-CoVmConnectionDisplayModel -Context $step1Context -ManagerUser $vmUser -AssistantUser $vmAssistantUser -SshPort $sshPort
            }

            Write-Host 'VM Public IP Address:'
            Write-Host ([string]$connectionModel.PublicIP)
            Write-Host 'SSH Connection Commands:'
            foreach ($sshConnection in @($connectionModel.SshConnections)) {
                Write-Host ("- {0}: {1}" -f ([string]$sshConnection.User), ([string]$sshConnection.Command))
            }

            if ([bool]$platformDefaults.IncludeRdp) {
                Write-Host 'RDP Connection Commands:'
                foreach ($rdpConnection in @($connectionModel.RdpConnections)) {
                    Write-Host ("- {0}: {1}" -f ([string]$rdpConnection.User), ([string]$rdpConnection.Command))
                    Write-Host ("  username: {0}" -f ([string]$rdpConnection.Username))
                }
            }
            else {
                Write-Host 'RDP note: Linux flow does not configure an RDP service by default.' -ForegroundColor Yellow
            }
        }

        Write-Host ("All console output was saved to '{0}'." -f [System.IO.Path]::GetFileName($logPath))
    }
    catch {
        $resolvedError = Resolve-CoVmFriendlyError -ErrorRecord $_ -DefaultErrorSummary $script:DefaultErrorSummary -DefaultErrorHint $script:DefaultErrorHint

        Write-Host ''
        Write-Host 'Script exited gracefully.' -ForegroundColor Yellow
        Write-Host ("Reason: {0}" -f $resolvedError.Summary) -ForegroundColor Red
        Write-Host ("Detail: {0}" -f $resolvedError.ErrorMessage)
        Write-Host ("Suggested action: {0}" -f $resolvedError.Hint) -ForegroundColor Cyan
        $script:HadError = $true
        $script:ExitCode = [int]$resolvedError.Code
    }
    finally {
        if ($script:TranscriptStarted) {
            Stop-Transcript | Out-Null
            $script:TranscriptStarted = $false
        }
        if (-not $script:AutoMode) {
            Read-Host -Prompt 'Press Enter to exit.' | Out-Null
        }
    }

    if ($script:HadError) {
        exit $script:ExitCode
    }
}

#region Imported:test-core
function Invoke-Step {
    param(
        [string] $prompt,
        [scriptblock] $Action
    )

    function Publish-NewStepVariables {
        param(
            [object[]]$BeforeVariables,
            [object[]]$AfterVariables
        )

        $beforeNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($beforeVar in $BeforeVariables) {
            [void]$beforeNames.Add([string]$beforeVar.Name)
        }

        foreach ($var in $AfterVariables) {
            $varName = [string]$var.Name
            if ($beforeNames.Contains($varName)) {
                continue
            }

            if (($var.Options -band [System.Management.Automation.ScopedItemOptions]::Constant) -ne 0) {
                continue
            }

            try {
                Set-Variable -Name $varName -Value $var.Value -Scope Script -Force -ErrorAction Stop
            }
            catch {
                # Skip transient or restricted variables safely.
            }
        }
    }

    $before = @(Get-Variable)
    if ($script:AutoMode) {
        Write-Host "$prompt (mode: auto)" -ForegroundColor Cyan
        $stepWatch = [System.Diagnostics.Stopwatch]::StartNew()
        . $Action
        if ($stepWatch.IsRunning) { $stepWatch.Stop() }
        if ($script:PerfMode) {
            Write-Host ("perf: step elapsed -> {0} ({1:N3}s)" -f $prompt, $stepWatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
        }
        $after = @(Get-Variable)
        Publish-NewStepVariables -BeforeVariables $before -AfterVariables $after
        return
    }
    do {
        $response = Read-Host "$prompt (mode: interactive) (yes/no)?"
    } until ($response -match '^[yYnN]$')
    if ($response -match '^[yY]$') {
        $stepWatch = [System.Diagnostics.Stopwatch]::StartNew()
        . $Action
        if ($stepWatch.IsRunning) { $stepWatch.Stop() }
        if ($script:PerfMode) {
            Write-Host ("perf: step elapsed -> {0} ({1:N3}s)" -f $prompt, $stepWatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
        }
        $after = @(Get-Variable)
        Publish-NewStepVariables -BeforeVariables $before -AfterVariables $after
    }
    else {
        Write-Host "Skipping this step." -ForegroundColor Cyan
    }
}

function Confirm-YesNo {
    param(
        [string]$PromptText,
        [bool]$DefaultYes = $false
    )

    $hintText = if ($DefaultYes) { " [Y/n]" } else { " [y/N]" }
    while ($true) {
        $raw = Read-Host ($PromptText + $hintText)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $DefaultYes
        }

        $value = $raw.Trim().ToLowerInvariant()
        if ($value -eq "y" -or $value -eq "yes") {
            return $true
        }
        if ($value -eq "n" -or $value -eq "no") {
            return $false
        }

        Write-Host "Please answer yes or no." -ForegroundColor Yellow
    }
}

function Invoke-TrackedAction {
    param(
        [string]$Label,
        [scriptblock]$Action
    )

    if ([string]::IsNullOrWhiteSpace($Label)) {
        $Label = "action"
    }

    Write-Host ("running: {0}" -f $Label) -ForegroundColor DarkCyan
    if ($script:PerfMode) {
        Write-Host ("perf: start -> {0}" -f $Label) -ForegroundColor DarkGray
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = . $Action
        if ($null -ne $result) {
            return $result
        }
    }
    finally {
        if ($watch.IsRunning) {
            $watch.Stop()
        }
        Write-Host ("finished: {0} ({1:N1}s)" -f $Label, $watch.Elapsed.TotalSeconds) -ForegroundColor DarkCyan
        if ($script:PerfMode) {
            Write-Host ("perf: elapsed -> {0} ({1:N3}s)" -f $Label, $watch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
        }
    }
}

function Assert-LastExitCode {
    param(
        [string]$Context
    )
    if ($LASTEXITCODE -ne 0) {
        throw "$Context failed with exit code $LASTEXITCODE."
    }
}

function Throw-FriendlyError {
    param(
        [string]$Detail,
        [int]$Code,
        [string]$Summary,
        [string]$Hint
    )

    $ex = [System.Exception]::new($Detail)
    $ex.Data["ExitCode"] = $Code
    $ex.Data["Summary"] = $Summary
    $ex.Data["Hint"] = $Hint
    throw $ex
}

function ConvertFrom-JsonCompat {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [string]) {
        $text = [string]$InputObject
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }
        return ($text | ConvertFrom-Json)
    }

    if ($InputObject -is [System.Array]) {
        if ($InputObject.Length -eq 0) {
            return @()
        }

        $first = $InputObject[0]
        if ($first -is [string]) {
            $joined = (($InputObject | ForEach-Object { [string]$_ }) -join "`n")
            if ([string]::IsNullOrWhiteSpace($joined)) {
                return $null
            }
            return ($joined | ConvertFrom-Json)
        }

        return $InputObject
    }

    $asText = [string]$InputObject
    $trimmed = $asText.TrimStart()
    if ($trimmed.StartsWith("{") -or $trimmed.StartsWith("[")) {
        return ($asText | ConvertFrom-Json)
    }

    return $InputObject
}

function ConvertFrom-JsonArrayCompat {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    $parsed = ConvertFrom-JsonCompat -InputObject $InputObject
    $result = @()
    if ($null -eq $parsed) {
        $result = @()
    }
    elseif ($parsed -is [System.Array]) {
        $result = @($parsed)
    }
    else {
        $result = @($parsed)
    }

    return $result
}

function ConvertTo-ObjectArrayCompat {
    param(
        [Parameter(Mandatory = $false)]
        [object]$InputObject
    )

    $result = @()

    if ($null -eq $InputObject) {
        $result = @()
    }
    elseif ($InputObject -is [System.Array]) {
        $result = @($InputObject)
    }
    elseif ($InputObject -is [string] -or $InputObject -is [char]) {
        $result = @([string]$InputObject)
    }
    elseif ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $result = @($InputObject)
    }
    else {
        $result = @($InputObject)
    }

    return $result
}

function Write-TextFileNormalized {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [AllowNull()]
        [string]$Content,
        [ValidateSet("utf8NoBom", "ascii")]
        [string]$Encoding = "utf8NoBom",
        [ValidateSet("lf", "crlf", "preserve")]
        [string]$LineEnding = "preserve",
        [switch]$EnsureTrailingNewline
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Write-TextFileNormalized requires a valid file path."
    }

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if ($null -eq $Content) {
        $Content = ""
    }
    $text = [string]$Content

    switch ($LineEnding) {
        "lf" {
            $text = $text -replace "`r`n", "`n"
            $text = $text -replace "`r", "`n"
        }
        "crlf" {
            $text = $text -replace "`r`n", "`n"
            $text = $text -replace "`r", "`n"
            $text = $text -replace "`n", "`r`n"
        }
    }

    if ($EnsureTrailingNewline) {
        $targetEnding = if ($LineEnding -eq "crlf") { "`r`n" } else { "`n" }
        if (-not $text.EndsWith($targetEnding)) {
            $text += $targetEnding
        }
    }

    $encodingObject = switch ($Encoding) {
        "utf8NoBom" { New-Object System.Text.UTF8Encoding($false) }
        "ascii" { [System.Text.Encoding]::ASCII }
        default { New-Object System.Text.UTF8Encoding($false) }
    }

    [System.IO.File]::WriteAllText($Path, $text, $encodingObject)
}
#endregion
#region Imported:test-config
function Read-DotEnvFile {
    param(
        [string]$Path
    )

    $config = @{}
    if (-not (Test-Path $Path)) {
        Write-Warning ".env file was not found at '$Path'. Built-in defaults will be used."
        return $config
    }

    foreach ($rawLine in Get-Content -Path $Path) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            continue
        }

        $match = [regex]::Match($line, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$')
        if (-not $match.Success) {
            Write-Warning "Skipping invalid .env line: $rawLine"
            continue
        }

        $key = $match.Groups[1].Value
        $value = $match.Groups[2].Value.Trim()
        if (
            ($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))
        ) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        $config[$key] = $value
    }

    return $config
}

function Get-ConfigValue {
    param(
        [hashtable]$Config,
        [string]$Key,
        [string]$DefaultValue
    )

    if ($script:ConfigOverrides -and $script:ConfigOverrides.ContainsKey($Key)) {
        $overrideValue = [string]$script:ConfigOverrides[$Key]
        if (-not [string]::IsNullOrWhiteSpace($overrideValue)) {
            return $overrideValue
        }
    }

    if ($Config -and $Config.ContainsKey($Key)) {
        $configValue = [string]$Config[$Key]
        if (-not [string]::IsNullOrWhiteSpace($configValue)) {
            return $configValue
        }
    }

    return $DefaultValue
}

function Resolve-ServerTemplate {
    param(
        [string]$Value,
        [string]$ServerName
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    return $Value.Replace("{SERVER_NAME}", $ServerName)
}

function Resolve-ConfigPath {
    param(
        [string]$PathValue,
        [string]$RootPath
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $PathValue
    }

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }

    return Join-Path $RootPath $PathValue
}

function Set-DotEnvValue {
    param(
        [string]$Path,
        [string]$Key,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Set-DotEnvValue requires a valid file path."
    }
    if ([string]::IsNullOrWhiteSpace($Key)) {
        throw "Set-DotEnvValue requires a non-empty key."
    }
    if ($null -eq $Value) {
        $Value = ""
    }

    $lines = @()
    if (Test-Path -LiteralPath $Path) {
        $lines = @((Get-Content -Path $Path -ErrorAction Stop))
    }

    $pattern = "^\s*" + [regex]::Escape($Key) + "\s*="
    $updated = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) {
            $lines[$i] = "$Key=$Value"
            $updated = $true
            break
        }
    }

    if (-not $updated) {
        if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines += ""
        }
        $lines += "$Key=$Value"
    }

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Write-TextFileNormalized `
        -Path $Path `
        -Content ($lines -join "`n") `
        -Encoding "utf8NoBom" `
        -LineEnding "crlf" `
        -EnsureTrailingNewline
}
#endregion
#region Imported:test-azure
function Assert-LocationExists {
    param(
        [string]$Location
    )

    $locationExists = az account list-locations --query "[?name=='$Location'].name | [0]" -o tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        Throw-FriendlyError `
            -Detail "az account list-locations failed with exit code $LASTEXITCODE." `
            -Code 22 `
            -Summary "Failed to read the region list." `
            -Hint "Check Azure login status and subscription access."
    }
    if ([string]::IsNullOrWhiteSpace($locationExists)) {
        Throw-FriendlyError `
            -Detail "Region '$Location' was not found." `
            -Code 22 `
            -Summary "Region name is invalid or unavailable." `
            -Hint "Select a valid region with az account list-locations."
    }
}

function Assert-VmImageAvailable {
    param(
        [string]$Location,
        [string]$ImageUrn
    )

    az vm image show -l $Location --urn $ImageUrn -o none --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        Throw-FriendlyError `
            -Detail "az vm image show failed with exit code $LASTEXITCODE." `
            -Code 23 `
            -Summary "The selected image is not available in this region." `
            -Hint "Update vmImage URN to an image available in this region."
    }
}

function Assert-VmSkuAvailableViaRest {
    param(
        [string]$Location,
        [string]$VmSize
    )

    $subscriptionId = az account show --query id -o tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        Throw-FriendlyError `
            -Detail "az account show failed with exit code $LASTEXITCODE." `
            -Code 24 `
            -Summary "Failed to read subscription information." `
            -Hint "Check Azure login status and active subscription selection."
    }
    if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
        Throw-FriendlyError `
            -Detail "Subscription ID could not be read." `
            -Code 24 `
            -Summary "Failed to read subscription information." `
            -Hint "Ensure az account show returns a valid id."
    }

    $sizesUrl = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Compute/locations/$Location/vmSizes"
    $sizeMatch = az rest `
        --method get `
        --url "$sizesUrl" `
        --uri-parameters "api-version=2021-07-01" `
        --query "value[?name=='$VmSize'].name | [0]" `
        -o tsv `
        --only-show-errors

    if ($LASTEXITCODE -ne 0) {
        Throw-FriendlyError `
            -Detail "az rest vmSizes list failed with exit code $LASTEXITCODE." `
            -Code 24 `
            -Summary "SKU availability pre-check could not be completed." `
            -Hint "Check Azure connectivity and az rest permissions."
    }

    if ([string]::IsNullOrWhiteSpace($sizeMatch)) {
        Throw-FriendlyError `
            -Detail "VM size '$VmSize' was not found in region '$Location'." `
            -Code 20 `
            -Summary "The VM size is not available in the selected region." `
            -Hint "Update vmSize or azLocation. The script cannot continue with an unsupported combination."
    }
}

function Assert-VmOsDiskSizeCompatible {
    param(
        [string]$Location,
        [string]$ImageUrn,
        [string]$VmDiskSizeGb
    )

    if (-not ($VmDiskSizeGb -match '^\d+$')) {
        Throw-FriendlyError `
            -Detail "Invalid VM disk size '$VmDiskSizeGb'." `
            -Code 25 `
            -Summary "Configured OS disk size is invalid." `
            -Hint "Set VM_DISK_SIZE_GB to a positive integer."
    }

    $requestedDiskSize = [int]$VmDiskSizeGb
    $imageId = az vm image show -l $Location --urn $ImageUrn --query "id" -o tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($imageId)) {
        Throw-FriendlyError `
            -Detail "Image metadata could not be read for '$ImageUrn' in '$Location'." `
            -Code 25 `
            -Summary "OS disk size compatibility pre-check could not be completed." `
            -Hint "Check image URN/region validity and Azure read permissions."
    }

    $minimumDiskSizeText = az rest `
        --method get `
        --url "https://management.azure.com$($imageId)" `
        --uri-parameters "api-version=2024-03-01" `
        --query "properties.osDiskImage.sizeInGb" `
        -o tsv `
        --only-show-errors

    if ($LASTEXITCODE -ne 0) {
        Throw-FriendlyError `
            -Detail "Image disk-size metadata read failed for '$ImageUrn' in '$Location'." `
            -Code 25 `
            -Summary "OS disk size compatibility pre-check could not be completed." `
            -Hint "Check Azure connectivity and az rest permissions."
    }

    if (-not ($minimumDiskSizeText -match '^\d+$')) {
        return
    }

    $minimumDiskSize = [int]$minimumDiskSizeText
    Write-Host "Image minimum OS disk size: $minimumDiskSize GB. Configured: $requestedDiskSize GB."
    if ($requestedDiskSize -lt $minimumDiskSize) {
        Throw-FriendlyError `
            -Detail "Configured OS disk size '$requestedDiskSize GB' is smaller than image minimum '$minimumDiskSize GB'." `
            -Code 25 `
            -Summary "Configured OS disk size is incompatible with the selected image." `
            -Hint "Set VM_DISK_SIZE_GB to at least $minimumDiskSize for image '$ImageUrn'."
    }
}
#endregion
#region Imported:test-guest
















function Get-CoVmConnectionDisplayModel {
    param(
        [hashtable]$Context,
        [string]$ManagerUser,
        [string]$AssistantUser,
        [string]$SshPort,
        [switch]$IncludeRdp
    )

    $vmConnectionInfo = Get-CoVmVmDetails -Context $Context
    $publicIP = [string]$vmConnectionInfo.PublicIP
    $vmFqdn = [string]$vmConnectionInfo.VmFqdn

    $sshConnections = @(
        [pscustomobject]@{
            User = $ManagerUser
            Command = ("ssh -p {0} {1}@{2}" -f $SshPort, $ManagerUser, $vmFqdn)
        },
        [pscustomobject]@{
            User = $AssistantUser
            Command = ("ssh -p {0} {1}@{2}" -f $SshPort, $AssistantUser, $vmFqdn)
        }
    )

    $model = [ordered]@{
        PublicIP = $publicIP
        VmFqdn = $vmFqdn
        SshConnections = $sshConnections
    }

    if ($IncludeRdp) {
        $rdpConnections = @(
            [pscustomobject]@{
                User = $ManagerUser
                Username = (".\{0}" -f $ManagerUser)
                Command = ("mstsc /v:{0}:3389" -f $vmFqdn)
            },
            [pscustomobject]@{
                User = $AssistantUser
                Username = (".\{0}" -f $AssistantUser)
                Command = ("mstsc /v:{0}:3389" -f $vmFqdn)
            }
        )
        $model["RdpConnections"] = $rdpConnections
    }

    return $model
}


#endregion
#region Imported:test-orchestration
function Invoke-CoVmStep1Common {
    param(
        [hashtable]$ConfigMap,
        [string]$EnvFilePath,
        [switch]$AutoMode,
        [string]$ScriptRoot,
        [string]$ServerNameDefault,
        [string]$VmImageDefault,
        [string]$VmDiskSizeDefault,
        [string]$VmCloudInitConfigKey = "",
        [string]$VmCloudInitDefault = "",
        [string]$VmInitConfigKey = "",
        [string]$VmInitDefault = "",
        [string]$VmUpdateConfigKey,
        [string]$VmUpdateDefault,
        [hashtable]$ConfigOverrides
    )

    if ([string]::IsNullOrWhiteSpace($VmUpdateConfigKey)) {
        throw "VmUpdateConfigKey is required."
    }

    $serverNameDefaultResolved = Get-ConfigValue -Config $ConfigMap -Key "SERVER_NAME" -DefaultValue $ServerNameDefault
    $serverName = $serverNameDefaultResolved
    do {
        if ($AutoMode) {
            $userInput = $serverNameDefaultResolved
        }
        else {
            $userInput = Read-Host "Enter server name (default=$serverNameDefaultResolved)"
        }

        if ([string]::IsNullOrWhiteSpace($userInput)) {
            $userInput = $serverNameDefaultResolved
        }

        if ($userInput -match '^[a-zA-Z][a-zA-Z0-9\-]{2,15}$') {
            $isValid = $true
        }
        else {
            Write-Host "Invalid VM name. Try again." -ForegroundColor Red
            $isValid = $false
        }
    } until ($isValid)

    $serverName = $userInput
    if ($ConfigOverrides) {
        $ConfigOverrides["SERVER_NAME"] = $serverName
    }
    if (-not $AutoMode) {
        Set-DotEnvValue -Path $EnvFilePath -Key "SERVER_NAME" -Value $serverName
    }

    Write-Host "Server name '$serverName' will be used." -ForegroundColor Green

    $resourceGroup = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "RESOURCE_GROUP" -DefaultValue "rg-{SERVER_NAME}") -ServerName $serverName
    $defaultAzLocation = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "AZ_LOCATION" -DefaultValue "austriaeast") -ServerName $serverName
    $VNET = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VNET_NAME" -DefaultValue "vnet-{SERVER_NAME}") -ServerName $serverName
    $SUBNET = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "SUBNET_NAME" -DefaultValue "subnet-{SERVER_NAME}") -ServerName $serverName
    $NSG = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "NSG_NAME" -DefaultValue "nsg-{SERVER_NAME}") -ServerName $serverName
    $nsgRule = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "NSG_RULE_NAME" -DefaultValue "nsg-rule-{SERVER_NAME}") -ServerName $serverName

    $IP = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "PUBLIC_IP_NAME" -DefaultValue "ip-{SERVER_NAME}") -ServerName $serverName
    $NIC = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "NIC_NAME" -DefaultValue "nic-{SERVER_NAME}") -ServerName $serverName
    $vmName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_NAME" -DefaultValue "{SERVER_NAME}") -ServerName $serverName
    $vmImage = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_IMAGE" -DefaultValue $VmImageDefault) -ServerName $serverName
    $vmStorageSku = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_STORAGE_SKU" -DefaultValue "StandardSSD_LRS") -ServerName $serverName
    $defaultVmSize = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_SIZE" -DefaultValue "Standard_B2as_v2") -ServerName $serverName
    $azLocation = $defaultAzLocation
    $vmSize = $defaultVmSize
    if (-not $AutoMode) {
        $priceHours = Get-PriceHoursFromConfig -Config $ConfigMap -DefaultHours 730
        $regionBackToken = Get-CoVmSkuPickerRegionBackToken
        while ($true) {
            $azLocation = Select-AzLocationInteractive -DefaultLocation $azLocation
            $vmSizeSelection = Select-VmSkuInteractive -Location $azLocation -DefaultVmSize $defaultVmSize -PriceHours $priceHours
            if ([string]::Equals([string]$vmSizeSelection, [string]$regionBackToken, [System.StringComparison]::Ordinal)) {
                continue
            }

            $vmSize = [string]$vmSizeSelection
            break
        }
        if ($ConfigOverrides) {
            $ConfigOverrides["AZ_LOCATION"] = $azLocation
            $ConfigOverrides["VM_SIZE"] = $vmSize
        }

        Set-DotEnvValue -Path $EnvFilePath -Key "AZ_LOCATION" -Value $azLocation
        Set-DotEnvValue -Path $EnvFilePath -Key "VM_SIZE" -Value $vmSize
        Write-Host "Interactive selection -> AZ_LOCATION='$azLocation', VM_SIZE='$vmSize'." -ForegroundColor Green
    }

    $vmDiskName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_DISK_NAME" -DefaultValue "disk-{SERVER_NAME}") -ServerName $serverName
    $vmDiskSize = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_DISK_SIZE_GB" -DefaultValue $VmDiskSizeDefault) -ServerName $serverName
    $vmUser = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_USER" -DefaultValue "manager") -ServerName $serverName
    $vmPass = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_PASS" -DefaultValue "<runtime-secret>") -ServerName $serverName
    $vmAssistantUser = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_ASSISTANT_USER" -DefaultValue "assistant") -ServerName $serverName
    $vmAssistantPass = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_ASSISTANT_PASS" -DefaultValue "<runtime-secret>") -ServerName $serverName
    $sshPort = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "SSH_PORT" -DefaultValue "444") -ServerName $serverName

    $vmCloudInitScriptFile = $null
    if (-not [string]::IsNullOrWhiteSpace($VmCloudInitConfigKey)) {
        $vmCloudInitScriptName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key $VmCloudInitConfigKey -DefaultValue $VmCloudInitDefault) -ServerName $serverName
        $vmCloudInitScriptFile = Resolve-ConfigPath -PathValue $vmCloudInitScriptName -RootPath $ScriptRoot
    }

    $vmInitScriptFile = $null
    if (-not [string]::IsNullOrWhiteSpace($VmInitConfigKey)) {
        $vmInitScriptName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key $VmInitConfigKey -DefaultValue $VmInitDefault) -ServerName $serverName
        $vmInitScriptFile = Resolve-ConfigPath -PathValue $vmInitScriptName -RootPath $ScriptRoot
    }

    $vmUpdateScriptName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key $VmUpdateConfigKey -DefaultValue $VmUpdateDefault) -ServerName $serverName
    $vmUpdateScriptFile = Resolve-ConfigPath -PathValue $vmUpdateScriptName -RootPath $ScriptRoot

    $defaultPortsCsv = "80,443,444,8444,3389,389,5173,3000,3001,8080,5432,3306,6837,4000,4001,5000,5001,6000,6001,6060,7000,7001,7070,8000,8001,9000,9001,9090,2222,3333,4444,5555,6666,7777,8888,9999,11434"
    $tcpPortsCsv = Get-ConfigValue -Config $ConfigMap -Key "TCP_PORTS" -DefaultValue $defaultPortsCsv
    $tcpPorts = @($tcpPortsCsv -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })

    if (-not ($sshPort -match '^\d+$')) {
        throw "Invalid SSH port '$sshPort'."
    }
    if ($tcpPorts -notcontains $sshPort) {
        $tcpPorts += $sshPort
    }
    if (-not $tcpPorts -or $tcpPorts.Count -eq 0) {
        throw "No valid TCP ports were found in TCP_PORTS."
    }

    return [ordered]@{
        ServerName = $serverName
        ResourceGroup = $resourceGroup
        AzLocation = $azLocation
        DefaultAzLocation = $defaultAzLocation
        VNET = $VNET
        SUBNET = $SUBNET
        NSG = $NSG
        NsgRule = $nsgRule
        IP = $IP
        NIC = $NIC
        VmName = $vmName
        VmImage = $vmImage
        VmStorageSku = $vmStorageSku
        VmSize = $vmSize
        DefaultVmSize = $defaultVmSize
        VmDiskName = $vmDiskName
        VmDiskSize = $vmDiskSize
        VmUser = $vmUser
        VmPass = $vmPass
        VmAssistantUser = $vmAssistantUser
        VmAssistantPass = $vmAssistantPass
        SshPort = $sshPort
        TcpPorts = @($tcpPorts)
        VmCloudInitScriptFile = $vmCloudInitScriptFile
        VmInitScriptFile = $vmInitScriptFile
        VmUpdateScriptFile = $vmUpdateScriptFile
    }
}

function Invoke-CoVmPrecheckStep {
    param(
        [hashtable]$Context
    )

    Show-CoVmStepFirstUseValues `
        -StepLabel "Step 2/9 - resource availability precheck" `
        -Context $Context `
        -Keys @("AzLocation", "VmImage", "VmSize", "VmDiskSize")

    Assert-LocationExists -Location $Context.AzLocation
    Assert-VmImageAvailable -Location $Context.AzLocation -ImageUrn $Context.VmImage
    Assert-VmSkuAvailableViaRest -Location $Context.AzLocation -VmSize $Context.VmSize
    Assert-VmOsDiskSizeCompatible -Location $Context.AzLocation -ImageUrn $Context.VmImage -VmDiskSizeGb $Context.VmDiskSize
}

function Invoke-CoVmResourceGroupStep {
    param(
        [hashtable]$Context,
        [switch]$AutoMode,
        [switch]$UpdateMode,
        [ValidateSet("legacy","default","update","destructive rebuild")]
        [string]$ExecutionMode = "legacy"
    )

    $resourceGroup = [string]$Context.ResourceGroup
    $effectiveMode = if ([string]::IsNullOrWhiteSpace([string]$ExecutionMode)) { "legacy" } else { [string]$ExecutionMode.Trim().ToLowerInvariant() }
    Show-CoVmStepFirstUseValues `
        -StepLabel "Step 3/9 - resource group check" `
        -Context $Context `
        -Keys @("ResourceGroup") `
        -ExtraValues @{
            ResourceExecutionMode = $effectiveMode
        }
    Write-Host "'$resourceGroup'"
    $resourceExists = az group exists -n $resourceGroup
    Assert-LastExitCode "az group exists"
    $resourceExistsBool = [string]::Equals([string]$resourceExists, "true", [System.StringComparison]::OrdinalIgnoreCase)
    $shouldCreateResourceGroup = $true

    switch ($effectiveMode) {
        "default" {
            if ($resourceExistsBool) {
                Write-Host "Default mode: existing resource group '$resourceGroup' will be kept; create step is skipped." -ForegroundColor Yellow
                $shouldCreateResourceGroup = $false
            }
        }
        "update" {
            if ($resourceExistsBool) {
                Write-Host "Update mode: existing resource group '$resourceGroup' will be kept; create-or-update command will run." -ForegroundColor Yellow
            }
        }
        "destructive rebuild" {
            if ($resourceExistsBool) {
                Write-Host "destructive rebuild mode: resource group '$resourceGroup' exists and can be deleted before recreate."
                $shouldDelete = $true
                if ($AutoMode) {
                    Write-Host "Auto mode: deletion was confirmed automatically."
                }
                else {
                    $shouldDelete = Confirm-YesNo -PromptText "Are you sure you want to delete resource group '$resourceGroup'?" -DefaultYes $false
                }

                if ($shouldDelete) {
                    Invoke-TrackedAction -Label "az group delete -n $resourceGroup --yes --no-wait" -Action {
                        az group delete -n $resourceGroup --yes --no-wait
                        Assert-LastExitCode "az group delete"
                    } | Out-Null
                    Invoke-TrackedAction -Label "az group wait -n $resourceGroup --deleted" -Action {
                        az group wait -n $resourceGroup --deleted
                        Assert-LastExitCode "az group wait deleted"
                    } | Out-Null
                    Write-Host "Resource group '$resourceGroup' was deleted."
                }
                else {
                    Write-Host "Resource group '$resourceGroup' was not deleted by user choice; continuing with recreate command." -ForegroundColor Yellow
                }
            }
        }
        default {
            if ($resourceExistsBool) {
                if ($UpdateMode) {
                    Write-Host "Update mode: existing resource group '$resourceGroup' will be kept." -ForegroundColor Yellow
                }
                else {
                    Write-Host "Resource group '$resourceGroup' will be deleted."
                    $shouldDelete = $true
                    if ($AutoMode) {
                        Write-Host "Auto mode: deletion was confirmed automatically."
                    }
                    else {
                        $shouldDelete = Confirm-YesNo -PromptText "Are you sure you want to delete resource group '$resourceGroup'?" -DefaultYes $false
                    }

                    if ($shouldDelete) {
                        Invoke-TrackedAction -Label "az group delete -n $resourceGroup --yes --no-wait" -Action {
                            az group delete -n $resourceGroup --yes --no-wait
                            Assert-LastExitCode "az group delete"
                        } | Out-Null
                        Invoke-TrackedAction -Label "az group wait -n $resourceGroup --deleted" -Action {
                            az group wait -n $resourceGroup --deleted
                            Assert-LastExitCode "az group wait deleted"
                        } | Out-Null
                        Write-Host "Resource group '$resourceGroup' was deleted."
                    }
                    else {
                        Write-Host "Resource group '$resourceGroup' was not deleted by user choice; continuing with existing resource group." -ForegroundColor Yellow
                    }
                }
            }
        }
    }

    if (-not $shouldCreateResourceGroup) {
        return
    }

    Write-Host "Creating resource group '$resourceGroup'..."
    $groupCreateSucceeded = $false
    $groupCreateAttempts = 12
    $groupCreateDelaySeconds = 10
    for ($groupCreateAttempt = 1; $groupCreateAttempt -le $groupCreateAttempts; $groupCreateAttempt++) {
        $attemptLabel = "az group create -n $resourceGroup -l $($Context.AzLocation)"
        if ($groupCreateAttempts -gt 1) {
            $attemptLabel = "$attemptLabel (attempt $groupCreateAttempt/$groupCreateAttempts)"
        }

        $groupCreateOutput = Invoke-TrackedAction -Label $attemptLabel -Action {
            az group create -n $resourceGroup -l $Context.AzLocation -o json 2>&1
        }
        $groupCreateExitCode = [int]$LASTEXITCODE
        if ($groupCreateExitCode -eq 0) {
            $groupCreateSucceeded = $true
            break
        }

        $groupCreateText = (@($groupCreateOutput) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        $isGroupBeingDeleted = ($groupCreateText -match '(?i)(ResourceGroupBeingDeleted|deprovisioning state)')
        if ($isGroupBeingDeleted -and $groupCreateAttempt -lt $groupCreateAttempts) {
            Write-Host ("Resource group '{0}' is still deprovisioning. Retrying in {1}s..." -f $resourceGroup, $groupCreateDelaySeconds) -ForegroundColor Yellow
            Start-Sleep -Seconds $groupCreateDelaySeconds
            continue
        }

        throw "az group create failed with exit code $groupCreateExitCode."
    }

    if (-not $groupCreateSucceeded) {
        throw "az group create failed because resource group '$resourceGroup' did not become ready in time."
    }
}

function Test-CoVmAzResourceExists {
    param(
        [string[]]$AzArgs
    )

    $null = az @AzArgs --only-show-errors -o none 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-CoVmNetworkStep {
    param(
        [hashtable]$Context,
        [ValidateSet("legacy","default","update","destructive rebuild")]
        [string]$ExecutionMode = "legacy"
    )

    $effectiveMode = if ([string]::IsNullOrWhiteSpace([string]$ExecutionMode)) { "legacy" } else { [string]$ExecutionMode.Trim().ToLowerInvariant() }
    $alwaysCreate = ($effectiveMode -in @("legacy","update","destructive rebuild"))
    Show-CoVmStepFirstUseValues `
        -StepLabel "Step 4/9 - network provisioning" `
        -Context $Context `
        -Keys @("ResourceGroup", "VNET", "SUBNET", "NSG", "NsgRule", "IP", "NIC", "TcpPorts") `
        -ExtraValues @{
            NetworkExecutionMode = $effectiveMode
        }

    $createVnet = $alwaysCreate
    if (-not $alwaysCreate) {
        $createVnet = -not (Test-CoVmAzResourceExists -AzArgs @("network", "vnet", "show", "-g", [string]$Context.ResourceGroup, "-n", [string]$Context.VNET))
        if (-not $createVnet) {
            Write-Host ("Default mode: VNet '{0}' exists; create command is skipped." -f [string]$Context.VNET) -ForegroundColor Yellow
        }
    }
    if ($createVnet) {
        Invoke-TrackedAction -Label "az network vnet create -g $($Context.ResourceGroup) -n $($Context.VNET)" -Action {
            az network vnet create -g $Context.ResourceGroup -n $Context.VNET --address-prefix 10.20.0.0/16 `
                --subnet-name $Context.SUBNET --subnet-prefix 10.20.0.0/24 -o table
            Assert-LastExitCode "az network vnet create"
        } | Out-Null
    }

    $createNsg = $alwaysCreate
    if (-not $alwaysCreate) {
        $createNsg = -not (Test-CoVmAzResourceExists -AzArgs @("network", "nsg", "show", "-g", [string]$Context.ResourceGroup, "-n", [string]$Context.NSG))
        if (-not $createNsg) {
            Write-Host ("Default mode: NSG '{0}' exists; create command is skipped." -f [string]$Context.NSG) -ForegroundColor Yellow
        }
    }
    if ($createNsg) {
        Invoke-TrackedAction -Label "az network nsg create -g $($Context.ResourceGroup) -n $($Context.NSG)" -Action {
            az network nsg create -g $Context.ResourceGroup -n $Context.NSG -o table
            Assert-LastExitCode "az network nsg create"
        } | Out-Null
    }

    $priority = 101
    $ports = @($Context.TcpPorts)
    $createNsgRule = $alwaysCreate
    if (-not $alwaysCreate) {
        $createNsgRule = -not (Test-CoVmAzResourceExists -AzArgs @("network", "nsg", "rule", "show", "-g", [string]$Context.ResourceGroup, "--nsg-name", [string]$Context.NSG, "--name", [string]$Context.NsgRule))
        if (-not $createNsgRule) {
            Write-Host ("Default mode: NSG rule '{0}' exists; create command is skipped." -f [string]$Context.NsgRule) -ForegroundColor Yellow
        }
    }
    if ($createNsgRule) {
        Invoke-TrackedAction -Label "az network nsg rule create -g $($Context.ResourceGroup) --nsg-name $($Context.NSG) --name $($Context.NsgRule)" -Action {
            $ruleArgs = @(
                "network", "nsg", "rule", "create",
                "-g", [string]$Context.ResourceGroup,
                "--nsg-name", [string]$Context.NSG,
                "--name", [string]$Context.NsgRule,
                "--priority", [string]$priority,
                "--direction", "Inbound",
                "--protocol", "Tcp",
                "--access", "Allow",
                "--destination-port-ranges"
            )
            $ruleArgs += @($ports | ForEach-Object { [string]$_ })
            $ruleArgs += @(
                "--source-address-prefixes", "*",
                "--source-port-ranges", "*",
                "-o", "table"
            )
            az @ruleArgs
            Assert-LastExitCode "az network nsg rule create"
        } | Out-Null
    }

    $createPublicIp = $alwaysCreate
    if (-not $alwaysCreate) {
        $createPublicIp = -not (Test-CoVmAzResourceExists -AzArgs @("network", "public-ip", "show", "-g", [string]$Context.ResourceGroup, "-n", [string]$Context.IP))
        if (-not $createPublicIp) {
            Write-Host ("Default mode: public IP '{0}' exists; create command is skipped." -f [string]$Context.IP) -ForegroundColor Yellow
        }
    }
    if ($createPublicIp) {
        Write-Host "Creating public IP '$($Context.IP)'..."
        Invoke-TrackedAction -Label "az network public-ip create -g $($Context.ResourceGroup) -n $($Context.IP)" -Action {
            az network public-ip create -g $Context.ResourceGroup -n $Context.IP --allocation-method Static --sku Standard --dns-name $Context.VmName -o table
            Assert-LastExitCode "az network public-ip create"
        } | Out-Null
    }

    $createNic = $alwaysCreate
    if (-not $alwaysCreate) {
        $createNic = -not (Test-CoVmAzResourceExists -AzArgs @("network", "nic", "show", "-g", [string]$Context.ResourceGroup, "-n", [string]$Context.NIC))
        if (-not $createNic) {
            Write-Host ("Default mode: NIC '{0}' exists; create command is skipped." -f [string]$Context.NIC) -ForegroundColor Yellow
        }
    }
    if ($createNic) {
        Write-Host "Creating network NIC '$($Context.NIC)'..."
        Invoke-TrackedAction -Label "az network nic create -g $($Context.ResourceGroup) -n $($Context.NIC)" -Action {
            az network nic create -g $Context.ResourceGroup -n $Context.NIC --vnet-name $Context.VNET --subnet $Context.SUBNET `
                --network-security-group $Context.NSG `
                --public-ip-address $Context.IP `
                -o table
            Assert-LastExitCode "az network nic create"
        } | Out-Null
    }
}

function Invoke-CoVmVmCreateStep {
    param(
        [hashtable]$Context,
        [switch]$AutoMode,
        [switch]$UpdateMode,
        [ValidateSet("legacy","default","update","destructive rebuild")]
        [string]$ExecutionMode = "legacy",
        [scriptblock]$CreateVmAction
    )

    if (-not $CreateVmAction) {
        throw "CreateVmAction is required."
    }

    $resourceGroup = [string]$Context.ResourceGroup
    $effectiveMode = if ([string]::IsNullOrWhiteSpace([string]$ExecutionMode)) { "legacy" } else { [string]$ExecutionMode.Trim().ToLowerInvariant() }
    $vmName = [string]$Context.VmName
    Show-CoVmStepFirstUseValues `
        -StepLabel "Step 7/9 - VM create" `
        -Context $Context `
        -Keys @("ResourceGroup", "VmName", "VmImage", "VmSize", "VmStorageSku", "VmDiskName", "VmDiskSize", "VmUser", "VmPass", "VmAssistantUser", "VmAssistantPass", "NIC") `
        -ExtraValues @{
            VmExecutionMode = $effectiveMode
        }

    $existingVM = az vm list `
        --resource-group $resourceGroup `
        --query "[?name=='$vmName'].name | [0]" `
        -o tsv
    Assert-LastExitCode "az vm list"

    $hasExistingVm = -not [string]::IsNullOrWhiteSpace([string]$existingVM)
    $shouldDeleteVm = $false
    $shouldCreateVm = $true
    $vmDeletedInThisRun = $false
    if ($hasExistingVm) {
        Write-Host "VM '$vmName' exists in resource group '$resourceGroup'."

        switch ($effectiveMode) {
            "default" {
                $shouldCreateVm = $false
                Write-Host "Default mode: existing VM '$vmName' will be kept; create step is skipped." -ForegroundColor Yellow
            }
            "update" {
                Write-Host "Update mode: existing VM will be kept; az vm create will run in create-or-update mode." -ForegroundColor Yellow
            }
            "destructive rebuild" {
                if ($AutoMode) {
                    $shouldDeleteVm = $true
                    Write-Host "Auto mode: VM deletion was confirmed automatically."
                }
                else {
                    $shouldDeleteVm = Confirm-YesNo -PromptText "Are you sure you want to delete VM '$vmName'?" -DefaultYes $false
                }
            }
            default {
                if ($UpdateMode) {
                    $shouldDeleteVm = $false
                    Write-Host "Update mode: existing VM will be kept; az vm create will run in create-or-update mode." -ForegroundColor Yellow
                }
                elseif ($AutoMode) {
                    $shouldDeleteVm = $true
                    Write-Host "Auto mode: VM deletion was confirmed automatically."
                }
                else {
                    $shouldDeleteVm = Confirm-YesNo -PromptText "Are you sure you want to delete VM '$vmName'?" -DefaultYes $false
                }
            }
        }

        if ($shouldDeleteVm) {
            Write-Host "VM '$vmName' will be deleted..."
            Invoke-TrackedAction -Label "az vm delete --name $vmName --resource-group $resourceGroup --yes" -Action {
                az vm delete --name $vmName --resource-group $resourceGroup --yes -o table
                Assert-LastExitCode "az vm delete"
            } | Out-Null
            Write-Host "VM '$vmName' was deleted from resource group '$resourceGroup'."
            $vmDeletedInThisRun = $true
        }
        elseif ($effectiveMode -eq "destructive rebuild") {
            Write-Host "destructive rebuild mode: VM '$vmName' was not deleted by user choice; az vm create will run on existing VM." -ForegroundColor Yellow
        }
        elseif ($effectiveMode -ne "default") {
            Write-Host "VM '$vmName' was not deleted by user choice; continuing with az vm create on existing VM." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "VM '$vmName' is not present in resource group '$resourceGroup'. Creating..."
    }

    if (-not $shouldCreateVm) {
        return [pscustomobject]@{
            VmExistsBefore = [bool]$hasExistingVm
            VmDeleted = [bool]$vmDeletedInThisRun
            VmCreateInvoked = $false
            VmCreatedThisRun = $false
            VmId = ""
        }
    }

    $vmCreatedThisRun = (-not $hasExistingVm) -or $vmDeletedInThisRun
    $vmCreateJson = Invoke-TrackedAction -Label "az vm create --resource-group $resourceGroup --name $vmName" -Action {
        $result = & $CreateVmAction
        if ($LASTEXITCODE -ne 0) {
            $createExitCode = [int]$LASTEXITCODE
            Write-Warning "az vm create returned a non-zero code; checking VM existence."

            $vmExistsAfterCreate = ""
            $shouldUseLongPresenceProbe = (($effectiveMode -in @("update","destructive rebuild")) -and $hasExistingVm) -or (($effectiveMode -eq "legacy") -and $UpdateMode -and $hasExistingVm)
            $presenceProbeAttempts = if ($shouldUseLongPresenceProbe) { 12 } else { 3 }
            for ($presenceAttempt = 1; $presenceAttempt -le $presenceProbeAttempts; $presenceAttempt++) {
                $vmExistsAfterCreate = az vm show -g $resourceGroup -n $vmName --query "id" -o tsv 2>$null
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$vmExistsAfterCreate)) {
                    break
                }

                if ($presenceAttempt -lt $presenceProbeAttempts) {
                    Write-Host ("VM existence probe attempt {0}/{1} did not resolve yet. Retrying in 10s..." -f $presenceAttempt, $presenceProbeAttempts) -ForegroundColor Yellow
                    Start-Sleep -Seconds 10
                }
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$vmExistsAfterCreate)) {
                Write-Host "VM exists; details will be retrieved via az vm show -d."
                $result = az vm show -g $resourceGroup -n $vmName -d -o json
                Assert-LastExitCode "az vm show -d after vm create non-zero"
            }
            else {
                throw "az vm create failed with exit code $createExitCode."
            }
        }

        $result
    }

    $vmCreateObj = ConvertFrom-JsonCompat -InputObject $vmCreateJson
    if (-not $vmCreateObj.id) {
        throw "az vm create completed but VM id was not returned."
    }

    Write-Host "Printing az vm create output..."
    Write-Host $vmCreateJson

    return [pscustomobject]@{
        VmExistsBefore = [bool]$hasExistingVm
        VmDeleted = [bool]$vmDeletedInThisRun
        VmCreateInvoked = $true
        VmCreatedThisRun = [bool]$vmCreatedThisRun
        VmId = [string]$vmCreateObj.id
    }
}

function Get-CoVmVmDetails {
    param(
        [hashtable]$Context
    )

    Show-CoVmStepFirstUseValues `
        -StepLabel "Step 9/9 - VM details" `
        -Context $Context `
        -Keys @("ResourceGroup", "VmName", "AzLocation", "SshPort")

    $vmDetailsJson = Invoke-TrackedAction -Label "az vm show -g $($Context.ResourceGroup) -n $($Context.VmName) -d" -Action {
        $result = az vm show -g $Context.ResourceGroup -n $Context.VmName -d -o json
        Assert-LastExitCode "az vm show -d"
        $result
    }

    $vmDetails = ConvertFrom-JsonCompat -InputObject $vmDetailsJson
    if (-not $vmDetails) {
        throw "VM detail output could not be parsed."
    }

    $publicIP = $vmDetails.publicIps
    $vmFqdn = $vmDetails.fqdns
    if ([string]::IsNullOrWhiteSpace($vmFqdn)) {
        $vmFqdn = "$($Context.VmName).$($Context.AzLocation).cloudapp.azure.com"
    }

    return [ordered]@{
        VmDetails = $vmDetails
        PublicIP = $publicIP
        VmFqdn = $vmFqdn
    }
}

function Resolve-CoVmFriendlyError {
    param(
        [object]$ErrorRecord,
        [string]$DefaultErrorSummary,
        [string]$DefaultErrorHint
    )

    $errorMessage = [string]$ErrorRecord.Exception.Message
    $summary = $DefaultErrorSummary
    $hint = $DefaultErrorHint
    $code = 99

    if ($ErrorRecord.Exception.Data -and $ErrorRecord.Exception.Data.Contains("ExitCode")) {
        $code = [int]$ErrorRecord.Exception.Data["ExitCode"]
        if ($ErrorRecord.Exception.Data.Contains("Summary")) {
            $summary = [string]$ErrorRecord.Exception.Data["Summary"]
        }
        if ($ErrorRecord.Exception.Data.Contains("Hint")) {
            $hint = [string]$ErrorRecord.Exception.Data["Hint"]
        }
    }
    elseif ($errorMessage -match "^VM size '(.+)' is available in region '(.+)' but not available for this subscription\.$") {
        $summary = "VM size exists in region but is not available for this subscription."
        $hint = "Choose another size in the same region or fix subscription quota/permissions."
        $code = 21
    }
    elseif ($errorMessage -match "^az group create failed with exit code") {
        $summary = "Resource group creation step failed."
        $hint = "Check region, policy, and subscription permissions."
        $code = 30
    }
    elseif ($errorMessage -match "^az vm create failed with exit code") {
        $summary = "VM creation step failed."
        $hint = "Check Step-2 precheck results, vmSize/image compatibility, and quota status."
        $code = 40
    }
    elseif ($errorMessage -match "^az vm run-command invoke") {
        $summary = "Configuration command inside VM failed."
        $hint = "Check VM running state and RunCommand availability."
        $code = 50
    }
    elseif ($errorMessage -match "^VM task '(.+)' failed:") {
        $summary = "A VM task failed."
        $hint = "Review the task name in the error detail and fix the related command."
        $code = 51
    }
    elseif ($errorMessage -match "^VM task batch execution failed") {
        $summary = "One or more tasks failed in auto mode."
        $hint = "Review the related task in the log file and fix the command."
        $code = 52
    }

    return [ordered]@{
        ErrorMessage = $errorMessage
        Summary = $summary
        Hint = $hint
        Code = $code
    }
}

function ConvertTo-CoVmDisplayValue {
    param(
        [object]$Value
    )

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [string]) {
        return [string]$Value
    }

    if ($Value -is [System.Array]) {
        return ((@($Value) | ForEach-Object { [string]$_ }) -join ", ")
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $pairs = @()
        foreach ($key in @($Value.Keys | Sort-Object)) {
            $pairs += ("{0}={1}" -f [string]$key, (ConvertTo-CoVmDisplayValue -Value $Value[$key]))
        }
        return ($pairs -join "; ")
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        return ((@($Value) | ForEach-Object { [string]$_ }) -join ", ")
    }

    return [string]$Value
}

function Get-CoVmFirstUseTracker {
    if (-not $script:CoVmFirstUseTracker) {
        $script:CoVmFirstUseTracker = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    }

    # Return as a single object even when empty; otherwise PowerShell may enumerate
    # an empty HashSet into $null and break method calls like .Contains().
    return (, $script:CoVmFirstUseTracker)
}

function Get-CoVmValueStateTracker {
    if (-not $script:CoVmValueStateTracker) {
        $script:CoVmValueStateTracker = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    }

    return (, $script:CoVmValueStateTracker)
}

function Register-CoVmValueObservation {
    param(
        [string]$Key,
        [object]$Value
    )

    $normalizedKey = [string]$Key
    if ([string]::IsNullOrWhiteSpace($normalizedKey)) {
        return [pscustomobject]@{
            Key = ""
            DisplayValue = ""
            ShouldPrint = $false
            IsFirst = $false
        }
    }

    $displayValue = ConvertTo-CoVmDisplayValue -Value $Value
    $valueState = Get-CoVmValueStateTracker
    $firstUseTracker = Get-CoVmFirstUseTracker

    $hasPrevious = $valueState.ContainsKey($normalizedKey)
    $previousValue = ""
    if ($hasPrevious) {
        $previousValue = [string]$valueState[$normalizedKey]
    }

    $shouldPrint = (-not $hasPrevious) -or (-not [string]::Equals($previousValue, [string]$displayValue, [System.StringComparison]::Ordinal))
    if ($shouldPrint) {
        $valueState[$normalizedKey] = [string]$displayValue
    }

    [void]$firstUseTracker.Add($normalizedKey)

    return [pscustomobject]@{
        Key = $normalizedKey
        DisplayValue = [string]$displayValue
        ShouldPrint = [bool]$shouldPrint
        IsFirst = [bool](-not $hasPrevious)
    }
}

function Show-CoVmStepFirstUseValues {
    param(
        [string]$StepLabel,
        [hashtable]$Context,
        [string[]]$Keys,
        [hashtable]$ExtraValues
    )

    $rows = @()
    $processed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($key in @($Keys)) {
        if ([string]::IsNullOrWhiteSpace([string]$key)) {
            continue
        }

        $normalizedKey = [string]$key
        if (-not $processed.Add($normalizedKey)) {
            continue
        }

        $value = $null
        $hasValue = $false
        if ($Context -and $Context.ContainsKey($normalizedKey)) {
            $value = $Context[$normalizedKey]
            $hasValue = $true
        }
        elseif ($ExtraValues -and $ExtraValues.ContainsKey($normalizedKey)) {
            $value = $ExtraValues[$normalizedKey]
            $hasValue = $true
        }

        if (-not $hasValue) {
            continue
        }

        $observed = Register-CoVmValueObservation -Key $normalizedKey -Value $value
        if ($observed.ShouldPrint) {
            $rows += [pscustomobject]@{
                Key = $observed.Key
                Value = $observed.DisplayValue
                IsFirst = $observed.IsFirst
            }
        }
    }

    if ($ExtraValues) {
        foreach ($extraKey in @($ExtraValues.Keys | Sort-Object)) {
            $normalizedKey = [string]$extraKey
            if ([string]::IsNullOrWhiteSpace($normalizedKey)) {
                continue
            }
            if (-not $processed.Add($normalizedKey)) {
                continue
            }

            $observed = Register-CoVmValueObservation -Key $normalizedKey -Value $ExtraValues[$extraKey]
            if ($observed.ShouldPrint) {
                $rows += [pscustomobject]@{
                    Key = $observed.Key
                    Value = $observed.DisplayValue
                    IsFirst = $observed.IsFirst
                }
            }
        }
    }

    if ($rows.Count -eq 0) {
        return
    }

    Write-Host ""
    if ([string]::IsNullOrWhiteSpace($StepLabel)) {
        Write-Host "Step value usage (new/updated values):" -ForegroundColor DarkCyan
    }
    else {
        Write-Host ("Step value usage ({0}) - new/updated values:" -f $StepLabel) -ForegroundColor DarkCyan
    }
    foreach ($row in @($rows)) {
        $statusTag = if ($row.IsFirst) { "new" } else { "updated" }
        Write-Host ("- {0} = {1} [{2}]" -f [string]$row.Key, [string]$row.Value, $statusTag)
    }
}

function Get-CoVmAzAccountSnapshot {
    $snapshot = [ordered]@{
        SubscriptionName = ""
        SubscriptionId = ""
        TenantName = ""
        TenantId = ""
        UserName = ""
    }

    $accountResult = Invoke-CoVmAzCommandWithTimeout `
        -AzArgs @("account", "show", "-o", "json", "--only-show-errors") `
        -TimeoutSeconds 15
    if ($accountResult.TimedOut -or $accountResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$accountResult.Output)) {
        return $snapshot
    }

    $accountObj = ConvertFrom-JsonCompat -InputObject $accountResult.Output
    if (-not $accountObj) {
        return $snapshot
    }

    $snapshot.SubscriptionName = [string]$accountObj.name
    $snapshot.SubscriptionId = [string]$accountObj.id
    $snapshot.TenantId = [string]$accountObj.tenantId
    $snapshot.UserName = [string]$accountObj.user.name

    $tenantName = ""
    if (-not [string]::IsNullOrWhiteSpace($snapshot.TenantId)) {
        $tenantResult = Invoke-CoVmAzCommandWithTimeout `
            -AzArgs @("account", "tenant", "list", "-o", "json", "--only-show-errors") `
            -TimeoutSeconds 20
        if (-not $tenantResult.TimedOut -and $tenantResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$tenantResult.Output)) {
            $tenantList = ConvertFrom-JsonArrayCompat -InputObject $tenantResult.Output
            foreach ($tenant in @($tenantList)) {
                if ([string]$tenant.tenantId -ne $snapshot.TenantId) {
                    continue
                }

                $tenantName = [string]$tenant.displayName
                if ([string]::IsNullOrWhiteSpace($tenantName)) {
                    $tenantName = [string]$tenant.defaultDomain
                }
                if ([string]::IsNullOrWhiteSpace($tenantName)) {
                    $tenantName = [string]$tenant.tenantId
                }
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($tenantName)) {
        $tenantName = [string]$snapshot.TenantId
    }
    $snapshot.TenantName = $tenantName
    return $snapshot
}

function Invoke-CoVmAzCommandWithTimeout {
    param(
        [string[]]$AzArgs,
        [int]$TimeoutSeconds = 15
    )

    if (-not $AzArgs -or $AzArgs.Count -eq 0) {
        throw "AzArgs is required."
    }

    if ($TimeoutSeconds -lt 1) {
        $TimeoutSeconds = 1
    }

    $job = Start-Job -ScriptBlock {
        param(
            [string[]]$InnerArgs
        )

        $outputLines = & az @InnerArgs 2>$null
        $outputText = ""
        if ($null -ne $outputLines) {
            $outputText = (@($outputLines) -join [Environment]::NewLine)
        }

        [pscustomobject]@{
            ExitCode = [int]$LASTEXITCODE
            Output = [string]$outputText
        }
    } -ArgumentList (,$AzArgs)

    try {
        $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if (-not $completed) {
            Stop-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
            return [pscustomobject]@{
                ExitCode = 124
                Output = ""
                TimedOut = $true
            }
        }

        $jobResult = Receive-Job -Job $job -ErrorAction SilentlyContinue
        if ($null -eq $jobResult) {
            return [pscustomobject]@{
                ExitCode = 1
                Output = ""
                TimedOut = $false
            }
        }

        return [pscustomobject]@{
            ExitCode = [int]$jobResult.ExitCode
            Output = [string]$jobResult.Output
            TimedOut = $false
        }
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

function Show-CoVmRuntimeConfigurationSnapshot {
    param(
        [string]$Platform,
        [string]$ScriptName,
        [string]$ScriptRoot,
        [switch]$AutoMode,
        [switch]$UpdateMode,
        [switch]$RenewMode,
        [hashtable]$ConfigMap,
        [hashtable]$ConfigOverrides,
        [hashtable]$Context
    )

    Write-Host ""
    Write-Host "Configuration Snapshot ($ScriptName / platform=$Platform):" -ForegroundColor DarkCyan

    $azAccount = Get-CoVmAzAccountSnapshot
    $accountRows = @()
    $accountFields = [ordered]@{
        SubscriptionName = "Subscription Name"
        SubscriptionId = "Subscription ID"
        TenantName = "Tenant Name"
        TenantId = "Tenant ID"
        UserName = "Account User"
    }
    foreach ($fieldKey in @($accountFields.Keys)) {
        $observed = Register-CoVmValueObservation -Key ([string]$fieldKey) -Value $azAccount[$fieldKey]
        if ($observed.ShouldPrint) {
            $accountRows += [pscustomobject]@{
                Label = [string]$accountFields[$fieldKey]
                Value = [string]$observed.DisplayValue
                IsFirst = [bool]$observed.IsFirst
            }
        }
    }
    if ($accountRows.Count -gt 0) {
        Write-Host "Azure account:"
        foreach ($row in @($accountRows)) {
            $statusTag = if ($row.IsFirst) { "new" } else { "updated" }
            Write-Host ("- {0}: {1} [{2}]" -f [string]$row.Label, [string]$row.Value, $statusTag)
        }
    }

    if ($Context) {
        $selectedRows = @()
        $selectedFields = [ordered]@{
            ResourceGroup = "Azure Resource Group"
            AzLocation = "Azure Region"
            VmSize = "Azure VM SKU"
            VmDiskSize = "VM Disk Size GB"
            VmImage = "VM OS Image"
        }
        foreach ($fieldKey in @($selectedFields.Keys)) {
            $observed = Register-CoVmValueObservation -Key ([string]$fieldKey) -Value $Context[$fieldKey]
            if ($observed.ShouldPrint) {
                $selectedRows += [pscustomobject]@{
                    Label = [string]$selectedFields[$fieldKey]
                    Value = [string]$observed.DisplayValue
                    IsFirst = [bool]$observed.IsFirst
                }
            }
        }
        if ($selectedRows.Count -gt 0) {
            Write-Host "Selected deployment values:"
            foreach ($row in @($selectedRows)) {
                $statusTag = if ($row.IsFirst) { "new" } else { "updated" }
                Write-Host ("- {0}: {1} [{2}]" -f [string]$row.Label, [string]$row.Value, $statusTag)
            }
        }
    }

    $runtimeRows = @()
    $runtimeFields = [ordered]@{
        AutoMode = [bool]$AutoMode
        UpdateMode = [bool]$UpdateMode
        RenewMode = [bool]$RenewMode
        ScriptRoot = [string]$ScriptRoot
        ScriptName = [string]$ScriptName
    }
    $runtimeLabels = @{
        AutoMode = "Auto mode"
        UpdateMode = "Update mode"
        RenewMode = "destructive rebuild mode"
        ScriptRoot = "Script root"
        ScriptName = "Script name"
    }
    foreach ($fieldKey in @($runtimeFields.Keys)) {
        $observed = Register-CoVmValueObservation -Key ([string]$fieldKey) -Value $runtimeFields[$fieldKey]
        if ($observed.ShouldPrint) {
            $runtimeRows += [pscustomobject]@{
                Label = [string]$runtimeLabels[$fieldKey]
                Value = [string]$observed.DisplayValue
                IsFirst = [bool]$observed.IsFirst
            }
        }
    }
    if ($runtimeRows.Count -gt 0) {
        Write-Host "Runtime flags and app parameters:"
        foreach ($row in @($runtimeRows)) {
            $statusTag = if ($row.IsFirst) { "new" } else { "updated" }
            Write-Host ("- {0}: {1} [{2}]" -f [string]$row.Label, [string]$row.Value, $statusTag)
        }
    }

    $envRows = @()
    if ($ConfigMap -and $ConfigMap.Count -gt 0) {
        foreach ($key in @($ConfigMap.Keys | Sort-Object)) {
            $obsKey = "ENV::{0}" -f [string]$key
            $observed = Register-CoVmValueObservation -Key $obsKey -Value $ConfigMap[$key]
            if ($observed.ShouldPrint) {
                $envRows += [pscustomobject]@{
                    Label = [string]$key
                    Value = [string]$observed.DisplayValue
                    IsFirst = [bool]$observed.IsFirst
                }
            }
        }
    }
    if ($envRows.Count -gt 0) {
        Write-Host ".env loaded values:"
        foreach ($row in @($envRows)) {
            $statusTag = if ($row.IsFirst) { "new" } else { "updated" }
            Write-Host ("- {0} = {1} [{2}]" -f [string]$row.Label, [string]$row.Value, $statusTag)
        }
    }

    $overrideRows = @()
    if ($ConfigOverrides -and $ConfigOverrides.Count -gt 0) {
        foreach ($key in @($ConfigOverrides.Keys | Sort-Object)) {
            $obsKey = "OVERRIDE::{0}" -f [string]$key
            $observed = Register-CoVmValueObservation -Key $obsKey -Value $ConfigOverrides[$key]
            if ($observed.ShouldPrint) {
                $overrideRows += [pscustomobject]@{
                    Label = [string]$key
                    Value = [string]$observed.DisplayValue
                    IsFirst = [bool]$observed.IsFirst
                }
            }
        }
    }
    if ($overrideRows.Count -gt 0) {
        Write-Host "Runtime overrides:"
        foreach ($row in @($overrideRows)) {
            $statusTag = if ($row.IsFirst) { "new" } else { "updated" }
            Write-Host ("- {0} = {1} [{2}]" -f [string]$row.Label, [string]$row.Value, $statusTag)
        }
    }

    if ($Context) {
        $effectiveRows = @()
        foreach ($key in @($Context.Keys | Sort-Object)) {
            $observed = Register-CoVmValueObservation -Key ([string]$key -replace '^\s+|\s+$', '') -Value $Context[$key]
            if ($observed.ShouldPrint) {
                $effectiveRows += [pscustomobject]@{
                    Label = [string]$key
                    Value = [string]$observed.DisplayValue
                    IsFirst = [bool]$observed.IsFirst
                }
            }
        }
        if ($effectiveRows.Count -gt 0) {
            Write-Host "Resolved effective values:"
            foreach ($row in @($effectiveRows)) {
                $statusTag = if ($row.IsFirst) { "new" } else { "updated" }
                Write-Host ("- {0} = {1} [{2}]" -f [string]$row.Label, [string]$row.Value, $statusTag)
            }
        }
    }
}
#endregion
#region Imported:test-runcommand
function Resolve-CoRunCommandScriptText {
    param(
        [string]$ScriptText
    )

    if ([string]::IsNullOrWhiteSpace($ScriptText)) {
        throw "VM run-command task script content is empty."
    }

    if ($ScriptText.StartsWith("@")) {
        $scriptPath = $ScriptText.Substring(1)
        if (-not (Test-Path -LiteralPath $scriptPath)) {
            throw "VM run-command task script file was not found: $scriptPath"
        }
        return (Get-Content -Path $scriptPath -Raw)
    }

    return $ScriptText
}

function Get-CoRunCommandScriptArgs {
    param(
        [string]$ScriptText,
        [string]$CommandId
    )

    if ([string]::IsNullOrWhiteSpace($ScriptText)) {
        throw "VM run-command task script content is empty."
    }

    if ($ScriptText.StartsWith("@")) {
        return @($ScriptText)
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'az-vm-run-command'
    if (-not (Test-Path -LiteralPath $tempRoot)) {
        [void](New-Item -ItemType Directory -Path $tempRoot -Force)
    }

    $extension = if ($CommandId -eq "RunPowerShellScript") { ".ps1" } else { ".sh" }
    $fileName = "task-{0}{1}" -f ([System.Guid]::NewGuid().ToString("N")), $extension
    $tempPath = Join-Path $tempRoot $fileName

    Write-TextFileNormalized -Path $tempPath -Content $ScriptText -Encoding "utf8NoBom" -EnsureTrailingNewline:$true
    return @("@$tempPath")
}

function Test-CoVmBenignRunCommandStdErr {
    param(
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace([string]$Message)) {
        return $false
    }

    $normalized = [string]$Message
    $normalized = $normalized -replace "`r", " "
    $normalized = $normalized -replace "`n", " "

    $benignPatterns = @(
        "(?i)'wmic'\s+is\s+not\s+recognized\s+as\s+an\s+internal\s+or\s+external\s+command"
    )

    foreach ($pattern in $benignPatterns) {
        if ($normalized -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-CoRunCommandResultMessage {
    param(
        [string]$TaskName,
        [object]$RawJson,
        [string]$ModeLabel
    )

    if ($null -eq $RawJson -or [string]::IsNullOrWhiteSpace([string]$RawJson)) {
        throw "VM $ModeLabel task '$TaskName' run-command output is empty."
    }

    try {
        $result = ConvertFrom-JsonCompat -InputObject $RawJson
    }
    catch {
        throw "VM $ModeLabel task '$TaskName' run-command output could not be parsed as JSON."
    }

    $resultEntries = ConvertTo-ObjectArrayCompat -InputObject $result.value
    if (-not $resultEntries -or $resultEntries.Count -eq 0) {
        throw "VM $ModeLabel task '$TaskName' run-command output is empty."
    }

    $messages = @()
    $hasError = $false
    foreach ($entry in $resultEntries) {
        $code = [string]$entry.code
        $message = [string]$entry.message
        $isFailedCode = ($code -match '(?i)/failed$')
        $isStdErrCode = ($code -match '(?i)StdErr')
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            $messages += $message.Trim()
        }

        if ($isStdErrCode -and -not [string]::IsNullOrWhiteSpace($message)) {
            if (Test-CoVmBenignRunCommandStdErr -Message $message) {
                Write-Warning ("Ignoring benign run-command stderr line for task '{0}': {1}" -f $TaskName, $message.Trim())
            }
            elseif ($message -match '(?i)(terminatingerror|exception|failed|not recognized|cannot find|categoryinfo)') {
                $hasError = $true
            }
            elseif ($isFailedCode) {
                $hasError = $true
            }
        }
        elseif ($isFailedCode) {
            $hasError = $true
        }
    }

    if ($hasError) {
        $joinedMessages = ($messages -join " | ")
        throw "VM $ModeLabel task '$TaskName' reported error: $joinedMessages"
    }

    return ($messages -join "`n")
}

function Parse-CoVmStep8Markers {
    param(
        [string]$MessageText
    )

    $result = [ordered]@{
        SuccessCount = 0
        WarningCount = 0
        ErrorCount = 0
        RebootCount = 0
        RebootRequired = $false
        HasSummaryLine = $false
        SummaryLine = ""
    }

    if ([string]::IsNullOrWhiteSpace($MessageText)) {
        return [pscustomobject]$result
    }

    $lines = @($MessageText -split "`r?`n")
    foreach ($line in $lines) {
        $trimmed = [string]$line
        if ($trimmed -match '^TASK_STATUS:(.+?):(success|warning|error)$') {
            $status = [string]$Matches[2]
            switch ($status) {
                "success" { $result.SuccessCount++ }
                "warning" { $result.WarningCount++ }
                "error" { $result.ErrorCount++ }
            }
            continue
        }

        if ($trimmed -match '^STEP8_SUMMARY:success=(\d+);warning=(\d+);error=(\d+);reboot=(\d+)$') {
            $result.SuccessCount = [int]$Matches[1]
            $result.WarningCount = [int]$Matches[2]
            $result.ErrorCount = [int]$Matches[3]
            $result.RebootCount = [int]$Matches[4]
            $result.HasSummaryLine = $true
            $result.SummaryLine = $trimmed
            continue
        }

        if ($trimmed -match '^CO_VM_REBOOT_REQUIRED:') {
            $result.RebootRequired = $true
            continue
        }
    }

    return [pscustomobject]$result
}

function Test-CoVmOutputIndicatesRebootRequired {
    param(
        [string]$MessageText
    )

    if ([string]::IsNullOrWhiteSpace($MessageText)) {
        return $false
    }

    if ($MessageText -match '^CO_VM_REBOOT_REQUIRED:' -or $MessageText -match '(?im)^TASK_REBOOT_REQUIRED:') {
        return $true
    }

    return ($MessageText -match '(?i)(reboot required|restart required|pending reboot|press any key to install windows subsystem for linux)')
}

function Invoke-VmRunCommandBlocks {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$CommandId,
        [object[]]$TaskBlocks,
        [ValidateSet("bash","powershell")]
        [string]$CombinedShell = "powershell"
    )

    if (-not $TaskBlocks -or $TaskBlocks.Count -eq 0) {
        throw "VM run-command task list is empty."
    }
    Write-Host "Task-batch mode is enabled: init tasks will run in a single run-command call."

    $combinedBuilder = New-Object System.Text.StringBuilder
    if ($CombinedShell -eq "bash") {
        [void]$combinedBuilder.AppendLine('set -euo pipefail')
        [void]$combinedBuilder.AppendLine('invoke_combined_task() {')
        [void]$combinedBuilder.AppendLine('  local task_name_base64="$1"')
        [void]$combinedBuilder.AppendLine('  local script_base64="$2"')
        [void]$combinedBuilder.AppendLine('  local task_name')
        [void]$combinedBuilder.AppendLine('  task_name=$(printf ''%s'' "$task_name_base64" | base64 -d)')
        [void]$combinedBuilder.AppendLine('  echo "TASK started: ${task_name}"')
        [void]$combinedBuilder.AppendLine('  local start_ts')
        [void]$combinedBuilder.AppendLine('  start_ts=$(date +%s)')
        [void]$combinedBuilder.AppendLine('  local task_script')
        [void]$combinedBuilder.AppendLine('  task_script=$(printf ''%s'' "$script_base64" | base64 -d)')
        [void]$combinedBuilder.AppendLine('  if bash -lc "$task_script"; then')
        [void]$combinedBuilder.AppendLine('    local end_ts')
        [void]$combinedBuilder.AppendLine('    end_ts=$(date +%s)')
        [void]$combinedBuilder.AppendLine('    local elapsed=$(( end_ts - start_ts ))')
        [void]$combinedBuilder.AppendLine('    echo "TASK completed: ${task_name} (${elapsed}s)"')
        [void]$combinedBuilder.AppendLine('    echo "TASK result: success"')
        [void]$combinedBuilder.AppendLine('  else')
        [void]$combinedBuilder.AppendLine('    echo "TASK result: failure (${task_name})"')
        [void]$combinedBuilder.AppendLine('    return 1')
        [void]$combinedBuilder.AppendLine('  fi')
        [void]$combinedBuilder.AppendLine('}')
    }
    else {
        [void]$combinedBuilder.AppendLine('$ErrorActionPreference = "Stop"')
        [void]$combinedBuilder.AppendLine('$ProgressPreference = "SilentlyContinue"')
        [void]$combinedBuilder.AppendLine('function Invoke-CombinedTaskBlock {')
        [void]$combinedBuilder.AppendLine('    param([string]$TaskName,[string]$ScriptBase64)')
        [void]$combinedBuilder.AppendLine('    Write-Host "TASK started: $TaskName"')
        [void]$combinedBuilder.AppendLine('    $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()')
        [void]$combinedBuilder.AppendLine('    try {')
        [void]$combinedBuilder.AppendLine('        $decodedScript = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($ScriptBase64))')
        [void]$combinedBuilder.AppendLine('        Invoke-Expression $decodedScript')
        [void]$combinedBuilder.AppendLine('        $taskWatch.Stop()')
        [void]$combinedBuilder.AppendLine('        Write-Host ("TASK completed: {0} ({1:N1}s)" -f $TaskName, $taskWatch.Elapsed.TotalSeconds)')
        [void]$combinedBuilder.AppendLine('        Write-Host "TASK result: success"')
        [void]$combinedBuilder.AppendLine('    }')
        [void]$combinedBuilder.AppendLine('    catch {')
        [void]$combinedBuilder.AppendLine('        if ($taskWatch.IsRunning) { $taskWatch.Stop() }')
        [void]$combinedBuilder.AppendLine('        Write-Host "TASK result: failure ($TaskName)"')
        [void]$combinedBuilder.AppendLine('        throw')
        [void]$combinedBuilder.AppendLine('    }')
        [void]$combinedBuilder.AppendLine('}')
    }

    foreach ($taskBlock in $TaskBlocks) {
        $taskName = [string]$taskBlock.Name
        $taskScript = Resolve-CoRunCommandScriptText -ScriptText ([string]$taskBlock.Script)
        if ($CombinedShell -eq "bash") {
            $taskNameBytes = [System.Text.Encoding]::UTF8.GetBytes($taskName)
            $taskNameBase64 = [System.Convert]::ToBase64String($taskNameBytes)
            $taskBytes = [System.Text.Encoding]::UTF8.GetBytes($taskScript)
            $taskBase64 = [System.Convert]::ToBase64String($taskBytes)
            [void]$combinedBuilder.AppendLine(("invoke_combined_task '{0}' '{1}'" -f $taskNameBase64, $taskBase64))
        }
        else {
            $taskNameSafe = $taskName.Replace("'", "''")
            $taskBytes = [System.Text.Encoding]::UTF8.GetBytes($taskScript)
            $taskBase64 = [System.Convert]::ToBase64String($taskBytes)
            [void]$combinedBuilder.AppendLine(("Invoke-CombinedTaskBlock -TaskName '{0}' -ScriptBase64 '{1}'" -f $taskNameSafe, $taskBase64))
        }
    }

    $combinedScript = $combinedBuilder.ToString()
    try {
        $combinedArgs = Get-CoRunCommandScriptArgs -ScriptText $combinedScript -CommandId $CommandId
        $combinedAzArgs = @(
            "vm", "run-command", "invoke",
            "--resource-group", $ResourceGroup,
            "--name", $VmName,
            "--command-id", $CommandId,
            "--scripts"
        )
        $combinedAzArgs += $combinedArgs
        $combinedAzArgs += @("-o", "json")
        $combinedInvokeLabel = "az vm run-command invoke (task-batch-combined)"
        $combinedJson = Invoke-TrackedAction -Label $combinedInvokeLabel -Action {
            $invokeResult = az @combinedAzArgs
            Assert-LastExitCode "az vm run-command invoke (task-batch-combined)"
            $invokeResult
        }
        $combinedMessage = Get-CoRunCommandResultMessage -TaskName "combined-task-batch" -RawJson $combinedJson -ModeLabel "auto-mode"
        Write-Host "TASK batch run-command completed."
        if (-not [string]::IsNullOrWhiteSpace($combinedMessage)) {
            Write-Host $combinedMessage
        }

        $marker = Parse-CoVmStep8Markers -MessageText $combinedMessage
        return [pscustomobject]@{
            SuccessCount = [int]$marker.SuccessCount
            WarningCount = [int]$marker.WarningCount
            ErrorCount = [int]$marker.ErrorCount
            RebootRequired = ([bool]$marker.RebootRequired -or (Test-CoVmOutputIndicatesRebootRequired -MessageText $combinedMessage))
            NextTaskIndex = [int]$TaskBlocks.Count
        }
    }
    catch {
        throw "VM task batch execution failed in combined flow: $($_.Exception.Message)"
    }
}

function Apply-CoVmTaskBlockReplacements {
    param(
        [object[]]$TaskBlocks,
        [hashtable]$Replacements
    )

    if (-not $TaskBlocks) {
        return @()
    }

    $resolvedBlocks = @()
    foreach ($taskBlock in $TaskBlocks) {
        $taskName = [string]$taskBlock.Name
        $taskScript = [string]$taskBlock.Script

        if ($Replacements) {
            foreach ($key in $Replacements.Keys) {
                $token = "__{0}__" -f [string]$key
                $value = [string]$Replacements[$key]
                $taskScript = $taskScript.Replace($token, $value)
            }
        }

        $resolvedBlocks += [pscustomobject]@{
            Name = $taskName
            Script = $taskScript
        }
    }

    return $resolvedBlocks
}

function Wait-CoVmVmRunningState {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [int]$MaxAttempts = 60,
        [int]$DelaySeconds = 10
    )

    if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
    if ($DelaySeconds -lt 1) { $DelaySeconds = 1 }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $powerState = az vm get-instance-view `
            --resource-group $ResourceGroup `
            --name $VmName `
            --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" `
            -o tsv
        Assert-LastExitCode "az vm get-instance-view (power state)"

        if ([string]::IsNullOrWhiteSpace([string]$powerState)) {
            Write-Host ("VM power state is empty (attempt {0}/{1})." -f $attempt, $MaxAttempts) -ForegroundColor Yellow
        }
        else {
            Write-Host ("VM power state: {0} (attempt {1}/{2})" -f [string]$powerState, $attempt, $MaxAttempts)
            if ([string]$powerState -eq "VM running") {
                return $true
            }
        }

        Start-Sleep -Seconds $DelaySeconds
    }

    return $false
}



#endregion
#region Imported:test-ssh
function Resolve-CoVmSshRetryCount {
    param(
        [string]$RetryText,
        [int]$DefaultValue = 3
    )

    $value = $DefaultValue
    if ($RetryText -match '^\d+$') {
        $value = [int]$RetryText
    }

    if ($value -lt 1) {
        $value = 1
    }
    if ($value -gt 3) {
        $value = 3
    }

    return $value
}

function Resolve-CoVmPySshToolPath {
    param(
        [string]$ConfiguredPath,
        [string]$RepoRoot,
        [string]$ToolName
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        $candidate = [string]$ConfiguredPath
        if (-not [System.IO.Path]::IsPathRooted($candidate)) {
            $candidate = Join-Path $RepoRoot $candidate
        }
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $defaultPath = Join-Path (Join-Path $RepoRoot "tools\\pyssh") $ToolName
    if (Test-Path -LiteralPath $defaultPath) {
        return (Resolve-Path -LiteralPath $defaultPath).Path
    }

    return $defaultPath
}

function Ensure-CoVmPySshTools {
    param(
        [string]$RepoRoot,
        [string]$ConfiguredPySshClientPath = ""
    )

    $configuredClientPath = [string]$ConfiguredPySshClientPath
    $pySshClientPath = Resolve-CoVmPySshToolPath -ConfiguredPath $configuredClientPath -RepoRoot $RepoRoot -ToolName "ssh_client.py"
    if (Test-Path -LiteralPath $pySshClientPath) {
        return [ordered]@{
            ClientPath = $pySshClientPath
        }
    }

    $installerPath = Join-Path $RepoRoot "tools\\install-pyssh-tools.ps1"
    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw "Python SSH tool installer script was not found: $installerPath"
    }

    Invoke-TrackedAction -Label ("powershell -File {0}" -f $installerPath) -Action {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installerPath
        Assert-LastExitCode "install-pyssh-tools.ps1"
    } | Out-Null

    if (-not (Test-Path -LiteralPath $pySshClientPath)) {
        throw "Python SSH tools could not be initialized. Missing ssh_client.py."
    }

    return [ordered]@{
        ClientPath = $pySshClientPath
    }
}

function Invoke-CoVmProcessWithRetry {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$Label,
        [int]$MaxAttempts = 3,
        [switch]$AllowFailure
    )

    if ($MaxAttempts -lt 1) {
        $MaxAttempts = 1
    }
    if ($MaxAttempts -gt 3) {
        $MaxAttempts = 3
    }

    $lastOutput = ""
    $lastExit = 0
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $attemptLabel = if ($MaxAttempts -gt 1) { ("{0} (attempt {1}/{2})" -f $Label, $attempt, $MaxAttempts) } else { $Label }
        $output = Invoke-TrackedAction -Label $attemptLabel -Action {
            & $FilePath @Arguments 2>&1
        }
        $lastExit = [int]$LASTEXITCODE
        $lastOutput = ((@($output) | ForEach-Object { [string]$_ }) -join "`n")

        if ($lastExit -eq 0 -or $AllowFailure) {
            return [pscustomobject]@{
                ExitCode = $lastExit
                Output = $lastOutput
            }
        }

        if ($attempt -lt $MaxAttempts) {
            Write-Host ("Retrying after failure (exit {0}): {1}" -f $lastExit, $Label) -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        }
    }

    throw ("{0} failed after {1} attempt(s). Exit={2}. Output={3}" -f $Label, $MaxAttempts, $lastExit, $lastOutput)
}

function Initialize-CoVmSshHostKey {
    param(
        [string]$PySshClientPath,
        [string]$HostName,
        [string]$UserName,
        [string]$Password,
        [string]$Port,
        [int]$ConnectTimeoutSeconds = 30
    )

    if ($ConnectTimeoutSeconds -lt 5) { $ConnectTimeoutSeconds = 5 }
    if ($ConnectTimeoutSeconds -gt 300) { $ConnectTimeoutSeconds = 300 }

    $result = Invoke-CoVmProcessWithRetry `
        -FilePath "python" `
        -Arguments @(
            $PySshClientPath,
            "exec",
            "--host", [string]$HostName,
            "--port", [string]$Port,
            "--user", [string]$UserName,
            "--password", [string]$Password,
            "--timeout", [string]$ConnectTimeoutSeconds,
            "--command", "whoami"
        ) `
        -Label "pyssh connection bootstrap" `
        -MaxAttempts 1 `
        -AllowFailure

    if ($result.ExitCode -ne 0) {
        Write-Warning "Python SSH bootstrap returned non-zero exit code. Continuing and allowing retry flow."
    }

    return [pscustomobject]@{
        ExitCode = [int]$result.ExitCode
        Output = [string]$result.Output
        HostKey = "auto-add"
    }
}







function Convert-CoVmProcessArgument {
    param(
        [string]$Value
    )

    if ($null -eq $Value) {
        return '""'
    }

    $escaped = [string]$Value
    $escaped = $escaped -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return ('"{0}"' -f $escaped)
}

function Start-CoVmPersistentSshSession {
    param(
        [string]$PySshClientPath,
        [string]$HostName,
        [string]$UserName,
        [string]$Password,
        [string]$Port,
        [ValidateSet("powershell", "bash")]
        [string]$Shell = "powershell",
        [int]$ConnectTimeoutSeconds = 30,
        [int]$DefaultTaskTimeoutSeconds = 1800
    )

    if ([string]::IsNullOrWhiteSpace($PySshClientPath) -or -not (Test-Path -LiteralPath $PySshClientPath)) {
        throw "Persistent SSH session could not start because pyssh client path is invalid."
    }
    if ($ConnectTimeoutSeconds -lt 5) { $ConnectTimeoutSeconds = 5 }
    if ($DefaultTaskTimeoutSeconds -lt 5) { $DefaultTaskTimeoutSeconds = 5 }

    $argList = @(
        [string]$PySshClientPath,
        "session",
        "--host", [string]$HostName,
        "--port", [string]$Port,
        "--user", [string]$UserName,
        "--password", [string]$Password,
        "--timeout", [string]$ConnectTimeoutSeconds,
        "--task-timeout", [string]$DefaultTaskTimeoutSeconds,
        "--shell", [string]$Shell
    )
    $argText = ($argList | ForEach-Object { Convert-CoVmProcessArgument -Value ([string]$_) }) -join ' '

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "python"
    $psi.Arguments = $argText
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psiType = $psi.GetType()
    if ($psiType.GetProperty("StandardInputEncoding")) {
        try { $psi.StandardInputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    }
    if ($psiType.GetProperty("StandardOutputEncoding")) {
        try { $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    }
    if ($psiType.GetProperty("StandardErrorEncoding")) {
        try { $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8 } catch { }
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    if (-not $proc.Start()) {
        throw "Persistent SSH python process could not be started."
    }

    return [pscustomobject]@{
        Process = $proc
        StdoutReader = $proc.StandardOutput
        StderrReader = $proc.StandardError
        PendingStdoutTask = $null
        PendingStderrTask = $null
        HostName = [string]$HostName
        UserName = [string]$UserName
        Port = [string]$Port
        Shell = [string]$Shell
        DefaultTaskTimeoutSeconds = [int]$DefaultTaskTimeoutSeconds
    }
}

function Write-CoVmPersistentSshProtocolLine {
    param(
        [psobject]$Session,
        [string]$Line
    )

    if ($null -eq $Session -or $null -eq $Session.Process) {
        throw "Persistent SSH session is not initialized."
    }
    if ($Session.Process.HasExited) {
        throw ("Persistent SSH session process has already exited (code={0})." -f $Session.Process.ExitCode)
    }

    $text = [string]$Line
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text + "`n")
    $stream = $Session.Process.StandardInput.BaseStream
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Normalize-CoVmProtocolLine {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        return $null
    }

    $value = [string]$Text
    $value = $value.Replace("`0", "")
    $value = $value.TrimStart([char]0xFEFF)
    $value = $value.TrimEnd("`r", "`n")
    return $value
}

function Invoke-CoVmPersistentSshTask {
    param(
        [psobject]$Session,
        [string]$TaskName,
        [string]$TaskScript,
        [int]$TimeoutSeconds = 1800
    )

    if ($null -eq $Session -or $null -eq $Session.Process) {
        throw "Persistent SSH session is not initialized."
    }
    if ($Session.Process.HasExited) {
        $stdoutTail = ""
        $stderrTail = ""
        try { $stdoutTail = [string]$Session.Process.StandardOutput.ReadToEnd() } catch { }
        try { $stderrTail = [string]$Session.Process.StandardError.ReadToEnd() } catch { }
        $detail = ""
        if (-not [string]::IsNullOrWhiteSpace($stdoutTail)) { $detail += (" stdout={0}" -f $stdoutTail.Trim()) }
        if (-not [string]::IsNullOrWhiteSpace($stderrTail)) { $detail += (" stderr={0}" -f $stderrTail.Trim()) }
        throw ("Persistent SSH session process has already exited (code={0}).{1}" -f $Session.Process.ExitCode, $detail)
    }
    if ($TimeoutSeconds -lt 5) { $TimeoutSeconds = 5 }

    $payload = [ordered]@{
        action = "run"
        task = [string]$TaskName
        timeout = [int]$TimeoutSeconds
        script = [string]$TaskScript
    } | ConvertTo-Json -Compress -Depth 20

    Write-CoVmPersistentSshProtocolLine -Session $Session -Line ([string]$payload)

    $proc = $Session.Process
    $stdoutReader = $Session.StdoutReader
    if ($null -eq $stdoutReader) {
        $stdoutReader = $proc.StandardOutput
        $Session.StdoutReader = $stdoutReader
    }
    $stderrReader = $Session.StderrReader
    if ($null -eq $stderrReader) {
        $stderrReader = $proc.StandardError
        $Session.StderrReader = $stderrReader
    }

    if ($null -eq $Session.PendingStdoutTask) {
        $Session.PendingStdoutTask = $stdoutReader.ReadLineAsync()
    }
    if ($null -eq $Session.PendingStderrTask) {
        $Session.PendingStderrTask = $stderrReader.ReadLineAsync()
    }
    $outputLines = New-Object 'System.Collections.Generic.List[string]'
    $endMarkerRegex = '^CO_VM_TASK_END:(?<task>.+?):(?<code>-?\d+)$'
    $beginMarkerRegex = '^CO_VM_TASK_BEGIN:(?<task>.+)$'
    $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $exitCode = $null

    while ($null -eq $exitCode) {
        $stdoutTask = $Session.PendingStdoutTask
        $stderrTask = $Session.PendingStderrTask
        $completedIndex = [System.Threading.Tasks.Task]::WaitAny(@($stdoutTask, $stderrTask), 250)

        if ($completedIndex -eq 0) {
            $line = $stdoutTask.Result
            $Session.PendingStdoutTask = $stdoutReader.ReadLineAsync()
            if ($null -ne $line) {
                $lineText = [string]$line
                $normalizedLine = Normalize-CoVmProtocolLine -Text $lineText
                if ($null -eq $normalizedLine) { $normalizedLine = "" }
                [void]$outputLines.Add([string]$normalizedLine)
                Write-Host ([string]$normalizedLine)
                if (($normalizedLine -as [string]) -like "CO_VM_SESSION_ERROR:*") {
                    throw ("Persistent SSH session reported protocol error for task '{0}': {1}" -f $TaskName, [string]$normalizedLine)
                }
                if ($normalizedLine -match $beginMarkerRegex) {
                    continue
                }
                if ($normalizedLine -match $endMarkerRegex) {
                    $markerTask = [string]$Matches.task
                    if ([string]::Equals($markerTask, [string]$TaskName, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $exitCode = [int]$Matches.code
                        break
                    }
                }
            }
        }
        elseif ($completedIndex -eq 1) {
            $line = $stderrTask.Result
            $Session.PendingStderrTask = $stderrReader.ReadLineAsync()
            if ($null -ne $line) {
                $lineText = [string]$line
                $normalizedLine = Normalize-CoVmProtocolLine -Text $lineText
                if ($null -eq $normalizedLine) { $normalizedLine = "" }
                [void]$outputLines.Add([string]$normalizedLine)
                Write-Warning ([string]$normalizedLine)
            }
        }

        if ($proc.HasExited -and $null -eq $exitCode) {
            $stdoutTail = ""
            $stderrTail = ""
            try { $stdoutTail = [string]$stdoutReader.ReadToEnd() } catch { }
            try { $stderrTail = [string]$stderrReader.ReadToEnd() } catch { }
            if (-not [string]::IsNullOrWhiteSpace($stdoutTail)) {
                foreach ($line in ($stdoutTail -split "`r?`n")) {
                    $normalizedTailLine = Normalize-CoVmProtocolLine -Text ([string]$line)
                    if ([string]::IsNullOrWhiteSpace($normalizedTailLine)) { continue }
                    [void]$outputLines.Add([string]$normalizedTailLine)
                    Write-Host ([string]$normalizedTailLine)
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($stderrTail)) {
                foreach ($line in ($stderrTail -split "`r?`n")) {
                    $normalizedTailLine = Normalize-CoVmProtocolLine -Text ([string]$line)
                    if ([string]::IsNullOrWhiteSpace($normalizedTailLine)) { continue }
                    [void]$outputLines.Add([string]$normalizedTailLine)
                    Write-Warning ([string]$normalizedTailLine)
                }
            }
            throw ("Persistent SSH session process exited before task completion (code={0})." -f $proc.ExitCode)
        }
        if ($taskWatch.Elapsed.TotalSeconds -gt ($TimeoutSeconds + 60)) {
            throw ("Persistent SSH task timeout guard reached for '{0}'." -f $TaskName)
        }
    }

    if ($taskWatch.IsRunning) { $taskWatch.Stop() }
    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Output = ($outputLines -join "`n")
    }
}

function Stop-CoVmPersistentSshSession {
    param(
        [psobject]$Session
    )

    if ($null -eq $Session) {
        return
    }

    $proc = $Session.Process
    if ($null -ne $proc) {
        try {
            if (-not $proc.HasExited) {
                try {
                    $closePayload = @{ action = "close" } | ConvertTo-Json -Compress
                    Write-CoVmPersistentSshProtocolLine -Session $Session -Line ([string]$closePayload)
                    $proc.StandardInput.Close()
                }
                catch { }

                if (-not $proc.WaitForExit(5000)) {
                    try { $proc.Kill() } catch { }
                    [void]$proc.WaitForExit(2000)
                }
            }
        }
        finally {
            try { $proc.Dispose() } catch { }
        }
    }
}

#endregion
#region Imported:test-sku
function Get-PriceHoursFromConfig {
    param(
        [hashtable]$Config,
        [int]$DefaultHours = 730
    )

    $hoursText = Get-ConfigValue -Config $Config -Key "PRICE_HOURS" -DefaultValue "$DefaultHours"
    if ($hoursText -match '^\d+$') {
        $hours = [int]$hoursText
        if ($hours -gt 0) {
            return $hours
        }
    }

    return $DefaultHours
}

function Get-AzLocationCatalog {
    $locationsJson = az account list-locations `
        --only-show-errors `
        --query "[?metadata.regionType=='Physical'].{Name:name,DisplayName:displayName,RegionType:metadata.regionType}" `
        -o json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($locationsJson)) {
        Throw-FriendlyError `
            -Detail "az account list-locations failed with exit code $LASTEXITCODE." `
            -Code 26 `
            -Summary "Azure region list could not be loaded." `
            -Hint "Run az login and verify subscription access."
    }

    $locations = ConvertFrom-JsonArrayCompat -InputObject $locationsJson
    if (-not $locations -or $locations.Count -eq 0) {
        $fallbackJson = az account list-locations `
            --only-show-errors `
            --query "[].{Name:name,DisplayName:displayName,RegionType:metadata.regionType}" `
            -o json
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($fallbackJson)) {
            $fallbackLocations = ConvertFrom-JsonArrayCompat -InputObject $fallbackJson
            $locations = @($fallbackLocations | Where-Object { $_.RegionType -eq "Physical" })
        }
    }
    if (-not $locations -or $locations.Count -eq 0) {
        Throw-FriendlyError `
            -Detail "Azure returned an empty physical deployment region list." `
            -Code 26 `
            -Summary "Azure region list could not be loaded." `
            -Hint "Check Azure account/subscription context and location metadata availability."
    }

    return (ConvertTo-ObjectArrayCompat -InputObject @($locations | Sort-Object DisplayName, Name))
    return
}

function Write-RegionSelectionGrid {
    param(
        [object[]]$Locations,
        [int]$DefaultIndex,
        [int]$Columns = 10
    )

    if (-not $Locations -or $Locations.Count -eq 0) {
        return
    }

    if ($Columns -lt 1) {
        $Columns = 1
    }

    $labels = @()
    for ($i = 0; $i -lt $Locations.Count; $i++) {
        $regionName = [string]$Locations[$i].Name
        $isDefault = (($i + 1) -eq $DefaultIndex)
        if ($isDefault) {
            $labels += ("*{0}-{1}." -f ($i + 1), $regionName)
        }
        else {
            $labels += ("{0}-{1}." -f ($i + 1), $regionName)
        }
    }

    $maxLength = ($labels | Measure-Object -Property Length -Maximum).Maximum
    $cellWidth = [int]$maxLength + 3

    for ($start = 0; $start -lt $labels.Count; $start += $Columns) {
        $end = [math]::Min($start + $Columns - 1, $labels.Count - 1)
        $lineBuilder = New-Object System.Text.StringBuilder
        for ($idx = $start; $idx -le $end; $idx++) {
            [void]$lineBuilder.Append(($labels[$idx]).PadRight($cellWidth))
        }
        Write-Host $lineBuilder.ToString().TrimEnd()
    }

}

function Select-AzLocationInteractive {
    param(
        [string]$DefaultLocation
    )

    $locations = Get-AzLocationCatalog
    $defaultIndex = 1
    for ($i = 0; $i -lt $locations.Count; $i++) {
        if ([string]::Equals($locations[$i].Name, $DefaultLocation, [System.StringComparison]::OrdinalIgnoreCase)) {
            $defaultIndex = $i + 1
            break
        }
    }

    Write-Host ""
    Write-Host "Available Azure regions (select by number):" -ForegroundColor Cyan
    Write-RegionSelectionGrid -Locations $locations -DefaultIndex $defaultIndex -Columns 10

    while ($true) {
        $inputValue = Read-Host "Enter region number (default=$defaultIndex)"
        if ([string]::IsNullOrWhiteSpace($inputValue)) {
            return $locations[$defaultIndex - 1].Name
        }

        if ($inputValue -match '^\d+$') {
            $selectedNo = [int]$inputValue
            if ($selectedNo -ge 1 -and $selectedNo -le $locations.Count) {
                return $locations[$selectedNo - 1].Name
            }
        }

        Write-Host "Invalid region selection. Please enter a valid number." -ForegroundColor Yellow
    }
}

function Convert-ToSkuSearchPattern {
    param(
        [string]$FilterText
    )

    if ([string]::IsNullOrWhiteSpace($FilterText)) {
        return ""
    }

    $trimmed = $FilterText.Trim()
    return "*" + $trimmed + "*"
}

function Test-SkuWildcardMatchOrdinalIgnoreCase {
    param(
        [string]$Text,
        [string]$Pattern
    )

    if ($null -eq $Text) {
        $Text = ""
    }
    if ($null -eq $Pattern) {
        $Pattern = ""
    }

    $textIndex = 0
    $patternIndex = 0
    $lastStarIndex = -1
    $starMatchTextIndex = 0

    while ($textIndex -lt $Text.Length) {
        if ($patternIndex -lt $Pattern.Length) {
            $patternChar = $Pattern[$patternIndex]
            $textChar = $Text[$textIndex]

            if ($patternChar -eq '?') {
                $textIndex++
                $patternIndex++
                continue
            }

            if ([string]::Equals([string]$textChar, [string]$patternChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                $textIndex++
                $patternIndex++
                continue
            }

            if ($patternChar -eq '*') {
                $lastStarIndex = $patternIndex
                $starMatchTextIndex = $textIndex
                $patternIndex++
                continue
            }
        }

        if ($lastStarIndex -ne -1) {
            $patternIndex = $lastStarIndex + 1
            $starMatchTextIndex++
            $textIndex = $starMatchTextIndex
            continue
        }

        return $false
    }

    while ($patternIndex -lt $Pattern.Length -and $Pattern[$patternIndex] -eq '*') {
        $patternIndex++
    }

    return ($patternIndex -eq $Pattern.Length)
}

function Get-LocationSkusForSelection {
    param(
        [string]$Location,
        [string]$SkuLike
    )

    $filterText = ""
    if (-not [string]::IsNullOrWhiteSpace($SkuLike)) {
        $filterText = $SkuLike.Trim()
    }

    $raw = az vm list-sizes -l $Location --only-show-errors -o json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        Throw-FriendlyError `
            -Detail "az vm list-sizes failed for location '$Location' with exit code $LASTEXITCODE." `
            -Code 27 `
            -Summary "VM size list could not be loaded for the selected region." `
            -Hint "Verify the selected region and Azure subscription permissions."
    }

    $allSkus = ConvertFrom-JsonArrayCompat -InputObject $raw
    $namedSkus = @(
        $allSkus | Where-Object {
            $_.name
        }
    )

    if ($filterText -eq "") {
        return (ConvertTo-ObjectArrayCompat -InputObject @($namedSkus | Sort-Object name -Unique))
        return
    }

    $effectivePattern = Convert-ToSkuSearchPattern -FilterText $filterText
    $filtered = foreach ($sku in $namedSkus) {
        $name = [string]$sku.name
        if (Test-SkuWildcardMatchOrdinalIgnoreCase -Text $name -Pattern $effectivePattern) {
            $sku
        }
    }

    return (ConvertTo-ObjectArrayCompat -InputObject @($filtered | Sort-Object name -Unique))
    return
}

function Get-SkuAvailabilityMap {
    param(
        [string]$Location,
        [string[]]$SkuNames
    )

    $result = @{}
    if (-not $SkuNames -or $SkuNames.Count -eq 0) {
        return $result
    }

    $targetSkuSet = @{}
    foreach ($skuName in $SkuNames) {
        if (-not [string]::IsNullOrWhiteSpace($skuName)) {
            $targetSkuSet[$skuName.ToLowerInvariant()] = $true
        }
    }

    $subscriptionId = az account show --only-show-errors --query id -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($subscriptionId)) {
        Throw-FriendlyError `
            -Detail "az account show failed while resolving subscription for SKU availability." `
            -Code 24 `
            -Summary "SKU availability pre-check could not be completed." `
            -Hint "Run az login and verify active subscription."
    }

    $tokenJson = az account get-access-token --only-show-errors --resource https://management.azure.com/ -o json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tokenJson)) {
        Throw-FriendlyError `
            -Detail "az account get-access-token failed while resolving SKU availability." `
            -Code 24 `
            -Summary "SKU availability pre-check could not be completed." `
            -Hint "Verify Azure CLI authentication and token permissions."
    }

    $accessToken = (ConvertFrom-JsonCompat -InputObject $tokenJson).accessToken
    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        Throw-FriendlyError `
            -Detail "Azure access token is empty for SKU availability request." `
            -Code 24 `
            -Summary "SKU availability pre-check could not be completed." `
            -Hint "Refresh Azure login session and retry."
    }

    $filter = [uri]::EscapeDataString("location eq '$Location'")
    $url = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Compute/skus?api-version=2023-07-01&`$filter=$filter"

    try {
        $response = Invoke-RestMethod -Method Get -Uri $url -Headers @{ Authorization = "Bearer $accessToken" } -ErrorAction Stop
    }
    catch {
        Throw-FriendlyError `
            -Detail "Resource SKU API call failed for availability check in '$Location'." `
            -Code 24 `
            -Summary "SKU availability pre-check could not be completed." `
            -Hint "Check Azure REST access and subscription permissions."
    }

    $items = @(
        (ConvertTo-ObjectArrayCompat -InputObject $response.value) |
            Where-Object { $_.resourceType -eq "virtualMachines" }
    )
    foreach ($item in $items) {
        if (-not $item.name) { continue }
        $itemName = [string]$item.name
        $skuKey = $itemName.ToLowerInvariant()
        if (-not $targetSkuSet.ContainsKey($skuKey)) { continue }

        $isUnavailable = $false
        foreach ($restriction in (ConvertTo-ObjectArrayCompat -InputObject $item.restrictions)) {
            if ($restriction.reasonCode -eq "NotAvailableForSubscription") {
                $isUnavailable = $true
                break
            }
            if ($restriction.type -eq "Location" -and (($restriction.values -and ($restriction.values -contains $Location)) -or -not $restriction.values)) {
                $isUnavailable = $true
                break
            }
        }

        $locationInfo = @(
            (ConvertTo-ObjectArrayCompat -InputObject $item.locationInfo) |
                Where-Object { $_.location -ieq $Location }
        )
        if ($isUnavailable -or -not $locationInfo) {
            $result[$itemName] = "no"
        }
        else {
            $result[$itemName] = "yes"
        }
    }

    return $result
}

function Get-SkuPriceMap {
    param(
        [string]$Location,
        [string[]]$SkuNames
    )

    $result = @{}
    if (-not $SkuNames -or $SkuNames.Count -eq 0) {
        return $result
    }

    $targetSkuSet = @{}
    foreach ($skuName in $SkuNames) {
        if (-not [string]::IsNullOrWhiteSpace($skuName)) {
            $targetSkuSet[$skuName.ToLowerInvariant()] = $true
        }
    }

    $baseFilter = "serviceName eq 'Virtual Machines' and armRegionName eq '$Location' and type eq 'Consumption' and unitOfMeasure eq '1 Hour'"
    $chunkSize = 15
    for ($i = 0; $i -lt $SkuNames.Count; $i += $chunkSize) {
        $end = [math]::Min($i + $chunkSize - 1, $SkuNames.Count - 1)
        $chunk = @($SkuNames[$i..$end])
        if (-not $chunk -or $chunk.Count -eq 0) { continue }

        $skuOrExpr = ($chunk | ForEach-Object { "armSkuName eq '$($_)'" }) -join " or "
        $filter = "$baseFilter and ($skuOrExpr)"
        $nextUri = "https://prices.azure.com/api/retail/prices?`$filter=" + [uri]::EscapeDataString($filter)

        while ($nextUri) {
            $response = Invoke-RestMethod -Uri $nextUri -Method Get -ErrorAction Stop
            foreach ($item in (ConvertTo-ObjectArrayCompat -InputObject $response.Items)) {
                if (-not $item.armSkuName -or $item.unitPrice -eq $null) { continue }
                $itemSkuName = [string]$item.armSkuName
                $itemKey = $itemSkuName.ToLowerInvariant()
                if (-not $targetSkuSet.ContainsKey($itemKey)) { continue }

                if ($item.productName -like "*Cloud Services*") { continue }
                $priceText = "$($item.productName) $($item.skuName) $($item.meterName) $($item.meterSubCategory)"
                if ($priceText -match '(?i)\bspot\b' -or $priceText -match '(?i)\blow\s+priority\b') { continue }

                if (-not $result.ContainsKey($itemSkuName)) {
                    $result[$itemSkuName] = [ordered]@{
                        LinuxPerHour   = $null
                        WindowsPerHour = $null
                        Currency       = $item.currencyCode
                    }
                }

                $entry = $result[$itemSkuName]
                $unitPrice = [double]$item.unitPrice
                if ($item.productName -like "*Windows*") {
                    if ($null -eq $entry.WindowsPerHour -or $unitPrice -lt $entry.WindowsPerHour) {
                        $entry.WindowsPerHour = $unitPrice
                    }
                }
                else {
                    if ($null -eq $entry.LinuxPerHour -or $unitPrice -lt $entry.LinuxPerHour) {
                        $entry.LinuxPerHour = $unitPrice
                    }
                }
            }

            $nextUri = $response.NextPageLink
        }
    }

    return $result
}

function Convert-HourlyPriceToMonthlyText {
    param(
        [double]$PricePerHour,
        [int]$Hours
    )

    if ($PricePerHour -le 0) {
        return "N/A"
    }

    return [math]::Round(($PricePerHour * $Hours), 2)
}

function Build-VmSkuSelectionRows {
    param(
        [object[]]$Skus,
        [hashtable]$AvailabilityMap,
        [hashtable]$PriceMap,
        [int]$PriceHours
    )

    $linuxPriceColumn = "Linux_{0}h" -f $PriceHours
    $windowsPriceColumn = "Windows_{0}h" -f $PriceHours

    $rows = @()
    for ($i = 0; $i -lt $Skus.Count; $i++) {
        $sku = $Skus[$i]
        $skuName = [string]$sku.name
        $price = $null
        if ($PriceMap.ContainsKey($skuName)) {
            $price = $PriceMap[$skuName]
        }

        $availability = "unknown"
        if ($AvailabilityMap.ContainsKey($skuName)) {
            $availability = [string]$AvailabilityMap[$skuName]
        }

        $row = [ordered]@{
            No          = $i + 1
            Sku         = $skuName
            vCPU        = [int]$sku.numberOfCores
            RAM_GB      = [math]::Round(([double]$sku.memoryInMB / 1024), 2)
        }

        $linuxPrice = if ($price -and $price.LinuxPerHour -ne $null) { Convert-HourlyPriceToMonthlyText -PricePerHour $price.LinuxPerHour -Hours $PriceHours } else { "N/A" }
        $windowsPrice = if ($price -and $price.WindowsPerHour -ne $null) { Convert-HourlyPriceToMonthlyText -PricePerHour $price.WindowsPerHour -Hours $PriceHours } else { "N/A" }
        $row[$linuxPriceColumn] = $linuxPrice
        $row[$windowsPriceColumn] = $windowsPrice
        $row["CreateReady"] = $availability

        $rows += [PSCustomObject]$row
    }

    return (ConvertTo-ObjectArrayCompat -InputObject $rows)
    return
}

function Read-StrictYesNo {
    param(
        [string]$PromptText
    )

    while ($true) {
        $raw = Read-Host ("{0} (y/n)" -f $PromptText)
        if ($null -eq $raw) {
            $raw = ""
        }

        $value = $raw.Trim().ToLowerInvariant()
        if ($value -eq "y") {
            return $true
        }
        if ($value -eq "n") {
            return $false
        }

        Write-Host "Invalid choice. Please enter 'y' or 'n'." -ForegroundColor Yellow
    }
}

function Get-CoVmSkuPickerRegionBackToken {
    return "__CO_VM_PICK_REGION_AGAIN__"
}

function Select-VmSkuInteractive {
    param(
        [string]$Location,
        [string]$DefaultVmSize,
        [int]$PriceHours
    )

    $currentVmSku = ""
    if (-not [string]::IsNullOrWhiteSpace($DefaultVmSize)) {
        $currentVmSku = $DefaultVmSize.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($currentVmSku)) {
        Write-Host ""
        Write-Host ("Current VM SKU for region '{0}': {1}" -f $Location, $currentVmSku) -ForegroundColor Cyan
        $useCurrentSku = Read-StrictYesNo -PromptText ("Continue with VM SKU '{0}'?" -f $currentVmSku)
        if ($useCurrentSku) {
            return $currentVmSku
        }
    }

    while ($true) {
        $skuLikeRaw = Read-Host "Enter partial VM type (supports * and ?, examples: b2a, standard_a*, standard_b?a*v2). Leave empty to list all"
        if ($null -eq $skuLikeRaw) {
            $skuLikeRaw = ""
        }
        $skuLike = $skuLikeRaw.Trim()

        $skus = Get-LocationSkusForSelection -Location $Location -SkuLike $skuLike
        $effectiveFilter = if ([string]::IsNullOrWhiteSpace($skuLike)) { "<all>" } else { $skuLike }
        Write-Host ("Partial VM type filter received: {0}" -f $effectiveFilter) -ForegroundColor DarkGray
        Write-Host ("Matching SKU count: {0}" -f @($skus).Count) -ForegroundColor DarkGray
        if (-not $skus -or $skus.Count -eq 0) {
            Write-Host "No matching VM SKU found for '$skuLike' in '$Location'. Try another filter." -ForegroundColor Yellow
            continue
        }

        $skuNames = @($skus | ForEach-Object { [string]$_.name })
        $availabilityMap = Get-SkuAvailabilityMap -Location $Location -SkuNames $skuNames
        $priceMap = @{}
        try {
            $priceMap = Get-SkuPriceMap -Location $Location -SkuNames $skuNames
        }
        catch {
            Write-Warning "Price API lookup failed. Pricing columns will be shown as N/A. Detail: $($_.Exception.Message)"
        }

        Write-Host ""
        Write-Host ("Available VM SKUs in region '{0}' (prices use {1} hours/month):" -f $Location, $PriceHours) -ForegroundColor Cyan
        $rows = Build-VmSkuSelectionRows -Skus $skus -AvailabilityMap $availabilityMap -PriceMap $priceMap -PriceHours $PriceHours
        $rows | Format-Table -AutoSize | Out-Host

        $defaultIndex = 1
        for ($i = 0; $i -lt $rows.Count; $i++) {
            if ([string]::Equals($rows[$i].Sku, $DefaultVmSize, [System.StringComparison]::OrdinalIgnoreCase)) {
                $defaultIndex = $i + 1
                break
            }
        }

        while ($true) {
            $selection = Read-Host "Enter VM SKU number (default=$defaultIndex, f=change filter, r=change region)"
            if ([string]::IsNullOrWhiteSpace($selection)) {
                $selectedSku = [string]$rows[$defaultIndex - 1].Sku
                $confirmSelected = Read-StrictYesNo -PromptText ("Selected VM SKU: '{0}'. Continue?" -f $selectedSku)
                if ($confirmSelected) {
                    return $selectedSku
                }

                Write-Host "Returning to VM SKU filter search..." -ForegroundColor DarkGray
                break
            }
            if ($selection -match '^[fF]$') {
                break
            }
            if ($selection -match '^[rR]$') {
                Write-Host "Returning to region selection..." -ForegroundColor DarkGray
                return (Get-CoVmSkuPickerRegionBackToken)
            }

            if ($selection -match '^\d+$') {
                $selectedNo = [int]$selection
                if ($selectedNo -ge 1 -and $selectedNo -le $rows.Count) {
                    $selectedSku = [string]$rows[$selectedNo - 1].Sku
                    $confirmSelected = Read-StrictYesNo -PromptText ("Selected VM SKU: '{0}'. Continue?" -f $selectedSku)
                    if ($confirmSelected) {
                        return $selectedSku
                    }

                    Write-Host "Returning to VM SKU filter search..." -ForegroundColor DarkGray
                    break
                }
            }

            Write-Host "Invalid VM SKU selection. Please enter a valid number, or use 'f'/'r'." -ForegroundColor Yellow
        }
    }
}
#endregion

if ($MyInvocation.InvocationName -eq '.') {
    return
}

Invoke-AzVmMain -WindowsFlag:$Windows -LinuxFlag:$Linux


