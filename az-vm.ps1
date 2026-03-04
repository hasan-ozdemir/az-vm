<#
Script Filename: az-vm.ps1
Script Description:
- Unified Azure VM provisioning flow for Windows and Linux.
- OS selection: --windows or --linux (or VM_OS_TYPE from .env).
- Init tasks run via az vm run-command task-by-task.
- Update tasks run via persistent pyssh task-by-task.
#>

param(
    [Alias('a','NonInteractive')]
    [switch]$Auto,
    [Alias('u')]
    [switch]$Update,
    [Alias('r')]
    [switch]$destructive rebuild,
    [switch]$Windows,
    [switch]$Linux
)

$script:AutoMode = [bool]$Auto
$script:UpdateMode = [bool]$Update
$script:RenewMode = [bool]$destructive rebuild
$script:TranscriptStarted = $false
$script:HadError = $false
$script:ExitCode = 0
$script:ConfigOverrides = @{}
$script:ExecutionMode = if ($script:RenewMode) { 'destructive rebuild' } elseif ($script:UpdateMode) { 'update' } else { 'default' }

$script:DefaultErrorSummary = 'An unexpected error occurred.'
$script:DefaultErrorHint = 'Review the error line and check script parameters and Azure connectivity.'

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

    $files = @(Get-ChildItem -LiteralPath $DirectoryPath -File | Sort-Object Name)
    if ($files.Count -eq 0) {
        throw ("No task files were found in {0}." -f $DirectoryPath)
    }

    $rows = @()
    foreach ($file in $files) {
        $name = [string]$file.Name
        if (-not ($name -match $namePattern)) {
            throw ("Invalid task filename '{0}'. Expected NN-verb-topic format with 2-5 words." -f $name)
        }

        $ext = [string]$Matches.ext
        if (-not [string]::Equals($ext, $expectedExt, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ("Task file '{0}' has invalid extension for platform '{1}'. Expected '{2}'." -f $name, $Platform, $expectedExt)
        }

        $rows += [pscustomobject]@{
            Order = [int]$Matches.n
            Name = [System.IO.Path]::GetFileNameWithoutExtension($name)
            Path = [string]$file.FullName
        }
    }

    $taskBlocks = @()
    foreach ($row in @($rows | Sort-Object Order, Name)) {
        $content = Get-Content -Path $row.Path -Raw
        $taskBlocks += [pscustomobject]@{
            Name = [string]$row.Name
            Script = [string]$content
        }
    }

    return $taskBlocks
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

function Invoke-CoVmRunCommandTaskBlocks {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$CommandId,
        [object[]]$TaskBlocks,
        [ValidateSet('continue','strict')]
        [string]$TaskOutcomeMode = 'strict'
    )

    if (-not $TaskBlocks -or @($TaskBlocks).Count -eq 0) {
        throw 'Run-command task list is empty.'
    }

    $totalSuccess = 0
    $totalWarnings = 0
    $totalErrors = 0

    foreach ($task in @($TaskBlocks)) {
        $taskName = [string]$task.Name
        $taskScript = Resolve-CoRunCommandScriptText -ScriptText ([string]$task.Script)
        $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            Write-Host ("TASK started: {0}" -f $taskName)
            $taskArgs = Get-CoRunCommandScriptArgs -ScriptText $taskScript -CommandId $CommandId
            $azArgs = @(
                'vm', 'run-command', 'invoke',
                '--resource-group', $ResourceGroup,
                '--name', $VmName,
                '--command-id', $CommandId,
                '--scripts'
            )
            $azArgs += $taskArgs
            $azArgs += @('-o', 'json')

            $json = Invoke-TrackedAction -Label ("az vm run-command invoke (task: {0})" -f $taskName) -Action {
                $res = az @azArgs
                Assert-LastExitCode ("az vm run-command invoke ({0})" -f $taskName)
                $res
            }

            $message = Get-CoRunCommandResultMessage -TaskName $taskName -RawJson $json -ModeLabel 'task-by-task'
            if ($taskWatch.IsRunning) { $taskWatch.Stop() }
            Write-Host ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
            Write-Host 'TASK result: success'
            Write-Host ("TASK_STATUS:{0}:success" -f $taskName)
            if (-not [string]::IsNullOrWhiteSpace([string]$message)) {
                Write-Host ([string]$message)
            }
            $totalSuccess++
        }
        catch {
            if ($taskWatch.IsRunning) { $taskWatch.Stop() }
            $detail = $_.Exception.Message
            if ($TaskOutcomeMode -eq 'continue') {
                $totalWarnings++
                Write-Warning ("TASK warning: {0} => {1}" -f $taskName, $detail)
                Write-Host ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
                Write-Host 'TASK result: warning'
                Write-Host ("TASK_STATUS:{0}:warning" -f $taskName)
                continue
            }

            $totalErrors++
            Write-Host ("TASK result: failure ({0})" -f $taskName) -ForegroundColor Red
            Write-Host ("TASK_STATUS:{0}:error" -f $taskName)
            throw
        }
    }

    Write-Host ("TASK_SUMMARY:success={0};warning={1};error={2}" -f $totalSuccess, $totalWarnings, $totalErrors)
    if ($TaskOutcomeMode -eq 'strict' -and ($totalWarnings -gt 0 -or $totalErrors -gt 0)) {
        throw ("Task outcome mode strict blocked continuation: warning={0}, error={1}" -f $totalWarnings, $totalErrors)
    }

    return [pscustomobject]@{
        SuccessCount = $totalSuccess
        WarningCount = $totalWarnings
        ErrorCount = $totalErrors
    }
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
        [object[]]$TaskBlocks,
        [ValidateSet('continue','strict')]
        [string]$TaskOutcomeMode = 'continue',
        [int]$SshMaxRetries = 3,
        [string]$ConfiguredPlinkPath = '',
        [string]$ConfiguredPscpPath = ''
    )

    if (-not $TaskBlocks -or @($TaskBlocks).Count -eq 0) {
        throw 'SSH task block list is empty.'
    }

    $SshMaxRetries = Resolve-CoVmSshRetryCount -RetryText ([string]$SshMaxRetries) -DefaultValue 3
    $putty = Ensure-CoVmPuttyTools -RepoRoot $RepoRoot -ConfiguredPlinkPath $ConfiguredPlinkPath -ConfiguredPscpPath $ConfiguredPscpPath

    $bootstrap = Initialize-CoVmSshHostKey -PlinkPath ([string]$putty.PlinkPath) -HostName $SshHost -UserName $SshUser -Password $SshPassword -Port $SshPort
    if (-not [string]::IsNullOrWhiteSpace([string]$bootstrap.Output)) {
        Write-Host ([string]$bootstrap.Output)
    }
    Write-Host ("Resolved SSH host key for batch transport: {0}" -f [string]$bootstrap.HostKey)

    $shell = if ($Platform -eq 'windows') { 'powershell' } else { 'bash' }
    $session = $null
    $totalSuccess = 0
    $totalWarnings = 0
    $totalErrors = 0

    try {
        Write-Host 'Task-by-task mode is enabled: Step 8 tasks are executed one-by-one over SSH.'
        Write-Host 'Persistent SSH task session is enabled: one SSH connection will be reused for Step 8 tasks.' -ForegroundColor DarkCyan
        Write-Host ("Task outcome mode: {0}" -f $TaskOutcomeMode)

        $session = Start-CoVmPersistentSshSession -PySshClientPath ([string]$putty.PlinkPath) -HostName $SshHost -UserName $SshUser -Password $SshPassword -Port $SshPort -Shell $shell -ConnectTimeoutSeconds 30 -DefaultTaskTimeoutSeconds 1800

        foreach ($task in @($TaskBlocks)) {
            $taskName = [string]$task.Name
            $taskScript = [string]$task.Script
            $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $taskResult = $null
            $taskInvocationError = $null

            Write-Host ("TASK started: {0}" -f $taskName)

            for ($attempt = 1; $attempt -le $SshMaxRetries; $attempt++) {
                $taskInvocationError = $null
                try {
                    $taskResult = Invoke-CoVmPersistentSshTask -Session $session -TaskName $taskName -TaskScript $taskScript -TimeoutSeconds 1800
                    break
                }
                catch {
                    $taskInvocationError = $_
                    if ($attempt -lt $SshMaxRetries) {
                        Write-Warning ("Persistent SSH task execution failed for '{0}' (attempt {1}/{2}): {3}" -f $taskName, $attempt, $SshMaxRetries, $_.Exception.Message)
                        Stop-CoVmPersistentSshSession -Session $session
                        $session = Start-CoVmPersistentSshSession -PySshClientPath ([string]$putty.PlinkPath) -HostName $SshHost -UserName $SshUser -Password $SshPassword -Port $SshPort -Shell $shell -ConnectTimeoutSeconds 30 -DefaultTaskTimeoutSeconds 1800
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
        }

        Write-Host ("STEP8_SUMMARY:success={0};warning={1};error={2};reboot=0" -f $totalSuccess, $totalWarnings, $totalErrors)
        if ($TaskOutcomeMode -eq 'strict' -and ($totalWarnings -gt 0 -or $totalErrors -gt 0)) {
            throw ("Step 8 strict task outcome mode blocked continuation: warning={0}, error={1}" -f $totalWarnings, $totalErrors)
        }

        return [pscustomobject]@{ SuccessCount = $totalSuccess; WarningCount = $totalWarnings; ErrorCount = $totalErrors; RebootCount = 0 }
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
- Init tasks run via az vm run-command task-by-task.
- Update tasks run via persistent pyssh task-by-task.
- SSH (default 444) and RDP (Windows) access are prepared.
- Run mode: interactive (default), auto (--auto / -a).
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
            $sshMaxRetries = Resolve-CoVmSshRetryCount -RetryText $sshMaxRetriesText -DefaultValue 3
            $configuredPlinkPath = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'PUTTY_PLINK_PATH' -DefaultValue '')
            $configuredPscpPath = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'PUTTY_PSCP_PATH' -DefaultValue '')

            if ($script:AutoMode) {
                Show-CoVmRuntimeConfigurationSnapshot -Platform $platform -ScriptName 'az-vm.ps1' -ScriptRoot $PSScriptRoot -AutoMode:$script:AutoMode -UpdateMode:$script:UpdateMode -RenewMode:$script:RenewMode -IncludeStep8LegacyFlags $false -ConfigMap $effectiveConfigMap -ConfigOverrides $script:ConfigOverrides -Context $step1Context
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
            $initTaskTemplates = @(Get-CoVmTaskBlocksFromDirectory -DirectoryPath $vmInitTaskDir -Platform $platform -Stage 'init')
            $initTaskBlocks = @(Resolve-CoVmRuntimeTaskBlocks -TemplateTaskBlocks $initTaskTemplates -Context $step1Context)
            Show-CoVmStepFirstUseValues -StepLabel 'Step 5/9 - init task catalog' -Context $step1Context -ExtraValues @{ InitTaskCount = @($initTaskBlocks).Count }
        }

        Invoke-Step 'Step 6/9 - VM update task files will be prepared...' {
            Show-CoVmStepFirstUseValues -StepLabel 'Step 6/9 - update task catalog' -Context $step1Context -ExtraValues @{ Platform = $platform; VmUpdateTaskDir = $vmUpdateTaskDir }
            $updateTaskTemplates = @(Get-CoVmTaskBlocksFromDirectory -DirectoryPath $vmUpdateTaskDir -Platform $platform -Stage 'update')
            $updateTaskBlocks = @(Resolve-CoVmRuntimeTaskBlocks -TemplateTaskBlocks $updateTaskTemplates -Context $step1Context)
            Show-CoVmStepFirstUseValues -StepLabel 'Step 6/9 - update task catalog' -Context $step1Context -ExtraValues @{ UpdateTaskCount = @($updateTaskBlocks).Count; TaskOutcomeMode = $taskOutcomeMode }
        }

        Invoke-Step 'Step 7/9 - virtual machine will be created...' {
            if ($platform -eq 'windows') {
                Invoke-CoVmVmCreateStep -Context $step1Context -AutoMode:$script:AutoMode -UpdateMode:$script:UpdateMode -ExecutionMode $script:ExecutionMode -CreateVmAction {
                    az vm create --resource-group $resourceGroup --name $vmName --image $vmImage --size $vmSize --storage-sku $vmStorageSku --os-disk-name $vmDiskName --os-disk-size-gb $vmDiskSize --admin-username $vmUser --admin-password $vmPass --authentication-type password --nics $NIC -o json
                }
            }
            else {
                Invoke-CoVmVmCreateStep -Context $step1Context -AutoMode:$script:AutoMode -UpdateMode:$script:UpdateMode -ExecutionMode $script:ExecutionMode -CreateVmAction {
                    az vm create --resource-group $resourceGroup --name $vmName --image $vmImage --size $vmSize --storage-sku $vmStorageSku --os-disk-name $vmDiskName --os-disk-size-gb $vmDiskSize --admin-username $vmUser --admin-password $vmPass --authentication-type password --nics $NIC -o json
                }
            }
        }

        Invoke-Step 'Step 8/9 - VM init and update tasks will be executed...' {
            Show-CoVmStepFirstUseValues -StepLabel 'Step 8/9 - guest execution' -Context $step1Context -ExtraValues @{
                Platform = $platform
                InitExecutor = 'az-vm-run-command'
                UpdateExecutor = 'pyssh-persistent'
                RunCommandId = [string]$platformDefaults.RunCommandId
                InitTaskCount = @($initTaskBlocks).Count
                UpdateTaskCount = @($updateTaskBlocks).Count
                TaskOutcomeMode = $taskOutcomeMode
                SshMaxRetries = $sshMaxRetries
                PuttyPlinkPath = $configuredPlinkPath
                PuttyPscpPath = $configuredPscpPath
            }

            Invoke-VmRunCommandBlocks -ResourceGroup $resourceGroup -VmName $vmName -CommandId ([string]$platformDefaults.RunCommandId) -TaskBlocks $initTaskBlocks -CombinedShell 'powershell' | Out-Null

            Write-Host 'Waiting 20 seconds for SSH service to settle after init...'
            Start-Sleep -Seconds 20

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

            Invoke-CoVmSshTaskBlocks -Platform $platform -RepoRoot $PSScriptRoot -SshHost $sshHost -SshUser $step8SshUser -SshPassword $step8SshPassword -SshPort $sshPort -TaskBlocks $updateTaskBlocks -TaskOutcomeMode $taskOutcomeMode -SshMaxRetries $sshMaxRetries -ConfiguredPlinkPath $configuredPlinkPath -ConfiguredPscpPath $configuredPscpPath | Out-Null
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
        . $Action
        $after = @(Get-Variable)
        Publish-NewStepVariables -BeforeVariables $before -AfterVariables $after
        return
    }
    do {
        $response = Read-Host "$prompt (mode: interactive) (yes/no)?"
    } until ($response -match '^[yYnN]$')
    if ($response -match '^[yY]$') {
        . $Action
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
function Get-CoVmLinuxCloudInitContent {
    param(
        [string]$VmUser,
        [string]$VmPass
    )

    $template = @'
#cloud-config
package_update: true
package_upgrade: false
timezone: UTC
users:
  - default
  - name: __VM_USER__
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
chpasswd:
  expire: false
  users:
    - name: __VM_USER__
      password: __VM_PASS__
ssh_pwauth: true
'@

    return $template.Replace("__VM_USER__", $VmUser).Replace("__VM_PASS__", $VmPass)
}

function Get-CoVmWindowsInitScriptContent {
    param(
        [string]$VmUser,
        [string]$VmPass,
        [string]$AssistantUser,
        [string]$AssistantPass,
        [string]$SshPort,
        [string[]]$TcpPorts
    )

    if ([string]::IsNullOrWhiteSpace($VmUser)) { throw "VmUser is required for Windows init script." }
    if ([string]::IsNullOrWhiteSpace($VmPass)) { throw "VmPass is required for Windows init script." }
    if ([string]::IsNullOrWhiteSpace($AssistantUser)) { throw "AssistantUser is required for Windows init script." }
    if ([string]::IsNullOrWhiteSpace($AssistantPass)) { throw "AssistantPass is required for Windows init script." }
    if (-not ($SshPort -match '^\d+$')) { throw "SshPort is invalid for Windows init script." }

    $validPorts = @(@($TcpPorts) | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^\d+$' } | Select-Object -Unique)
    if ($validPorts -notcontains [string]$SshPort) {
        $validPorts += [string]$SshPort
    }
    if ($validPorts -notcontains "3389") {
        $validPorts += "3389"
    }
    $portsCsv = ($validPorts -join ",")

    $template = @'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "Init phase started."
Set-TimeZone -Id "UTC" -ErrorAction SilentlyContinue

$vmUser = "__VM_USER__"
$vmPass = "__VM_PASS__"
$assistantUser = "__ASSISTANT_USER__"
$assistantPass = "__ASSISTANT_PASS__"

function Ensure-GroupMembership {
    param(
        [string]$GroupName,
        [string]$MemberName
    )

    function Normalize-Identity {
        param(
            [string]$Value
        )

        if ([string]::IsNullOrWhiteSpace($Value)) {
            return ""
        }

        return $Value.Trim().ToLowerInvariant()
    }

    $shortMember = [string]$MemberName
    if ($MemberName -match '^[^\\]+\\(.+)$') {
        $shortMember = [string]$Matches[1]
    }

    $memberAliases = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @(
        $MemberName,
        $shortMember,
        "$env:COMPUTERNAME\$shortMember",
        ".\$shortMember"
    )) {
        $normalizedCandidate = Normalize-Identity -Value ([string]$candidate)
        if (-not [string]::IsNullOrWhiteSpace($normalizedCandidate)) {
            [void]$memberAliases.Add($normalizedCandidate)
        }
    }

    $alreadyMember = $false
    try {
        $members = Get-LocalGroupMember -Group $GroupName -ErrorAction Stop
        foreach ($member in $members) {
            $existingMember = Normalize-Identity -Value ([string]$member.Name)
            if ($memberAliases.Contains($existingMember)) {
                $alreadyMember = $true
                break
            }
        }
    }
    catch {
        $groupOutput = net localgroup "$GroupName" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $groupOutputText = (@($groupOutput) | ForEach-Object { [string]$_ }) -join "`n"
            $escapedShortMember = [regex]::Escape($shortMember)
            $escapedFullMember = [regex]::Escape($MemberName)
            if (
                $groupOutputText -match ("(?im)^\s*(?:.+\\)?{0}\s*$" -f $escapedShortMember) -or
                $groupOutputText -match ("(?im)^\s*{0}\s*$" -f $escapedFullMember)
            ) {
                $alreadyMember = $true
            }
        }
    }

    if ($alreadyMember) {
        Write-Host "User '$MemberName' is already in local group '$GroupName'."
        return
    }

    $lastAddExitCode = 1
    $addCandidates = @(
        $MemberName,
        $shortMember,
        ".\$shortMember"
    )
    $addTried = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($addCandidate in @($addCandidates)) {
        if ([string]::IsNullOrWhiteSpace([string]$addCandidate)) {
            continue
        }

        if (-not $addTried.Add([string]$addCandidate)) {
            continue
        }

        net localgroup "$GroupName" $addCandidate /add | Out-Null
        $lastAddExitCode = $LASTEXITCODE

        if ($lastAddExitCode -eq 0) {
            Write-Host "User '$addCandidate' was added to local group '$GroupName'."
            return
        }

        if ($lastAddExitCode -eq 1378) {
            Write-Host "User '$addCandidate' is already in local group '$GroupName' (system error 1378)."
            return
        }
    }

    if ($lastAddExitCode -ne 0) {
        throw "Adding '$MemberName' to '$GroupName' failed with exit code $lastAddExitCode."
    }
}

function Ensure-LocalPowerAdmin {
    param(
        [string]$UserName,
        [string]$Password
    )

    if (-not (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
        $securePass = ConvertTo-SecureString $Password -AsPlainText -Force
        New-LocalUser -Name $UserName -Password $securePass -PasswordNeverExpires -AccountNeverExpires -FullName $UserName -Description "Azure VM Power Admin user" | Out-Null
    }
    else {
        net user $UserName $Password | Out-Null
    }
    Ensure-GroupMembership -GroupName "Administrators" -MemberName $UserName
    Ensure-GroupMembership -GroupName "Remote Desktop Users" -MemberName $UserName
}

Ensure-LocalPowerAdmin -UserName $vmUser -Password $vmPass
Ensure-LocalPowerAdmin -UserName $assistantUser -Password $assistantPass
Write-Host "local-admin-users-ready"

if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (-not (Test-Path $chocoExe)) {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString("https://community.chocolatey.org/install.ps1"))
    }
    $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (-not (Test-Path $chocoExe)) { throw "choco was not found." }
    & $chocoExe upgrade openssh -y --no-progress | Out-Null
    $openSshExit = $LASTEXITCODE
    if ($openSshExit -ne 0 -and $openSshExit -ne 2) { throw "choco upgrade openssh failed with exit code $openSshExit." }

    if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
        foreach ($installScript in @(
            "C:\Program Files\OpenSSH-Win64\install-sshd.ps1",
            "C:\ProgramData\chocolatey\lib\openssh\tools\install-sshd.ps1"
        )) {
            if (Test-Path $installScript) {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript | Out-Null
                break
            }
        }
    }
}
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) { throw "OpenSSH setup completed but sshd service was not found." }
Set-Service -Name sshd -StartupType Automatic
if (Get-Service ssh-agent -ErrorAction SilentlyContinue) { Set-Service -Name ssh-agent -StartupType Automatic }
Write-Host "openssh-ready"

$sshdConfig = "C:\ProgramData\ssh\sshd_config"
if (-not (Test-Path $sshdConfig)) { New-Item -Path $sshdConfig -ItemType File -Force | Out-Null }
$content = @(Get-Content -Path $sshdConfig -ErrorAction SilentlyContinue)
if ($content.Count -eq 0) {
    $content = @(
        "# Generated baseline sshd_config",
        "Port 22",
        "PasswordAuthentication no",
        "PubkeyAuthentication yes",
        "PermitEmptyPasswords no",
        "AllowTcpForwarding yes",
        "GatewayPorts no",
        "Subsystem sftp sftp-server.exe"
    )
}
function Set-OrAdd([string]$Key,[string]$Value) {
    $regex = "^\s*#?\s*" + [regex]::Escape($Key) + "\s+.*$"
    $replacement = "$Key $Value"
    $updated = $false
    for ($i = 0; $i -lt $content.Count; $i++) {
        if ($content[$i] -match $regex) {
            $content[$i] = $replacement
            $updated = $true
        }
    }
    if (-not $updated) { $content += $replacement }
}
Set-OrAdd -Key "Port" -Value "__SSH_PORT__"
Set-OrAdd -Key "PasswordAuthentication" -Value "yes"
Set-OrAdd -Key "PubkeyAuthentication" -Value "no"
Set-OrAdd -Key "PermitEmptyPasswords" -Value "no"
Set-OrAdd -Key "AllowTcpForwarding" -Value "yes"
Set-OrAdd -Key "GatewayPorts" -Value "yes"
Set-OrAdd -Key "Subsystem sftp" -Value "sftp-server.exe"
Set-Content -Path $sshdConfig -Value $content -Encoding ascii
New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name "DefaultShell" -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
Restart-Service -Name sshd -Force
if (-not (Get-NetFirewallRule -DisplayName "Allow-SSH-__SSH_PORT__" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow-SSH-__SSH_PORT__" -Direction Inbound -Action Allow -Protocol TCP -LocalPort __SSH_PORT__ -RemoteAddress Any -Profile Any | Out-Null
}
Write-Host "sshd-config-ready"

Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 0
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "SecurityLayer" -Value 1
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "MinEncryptionLevel" -Value 2
if (-not (Get-NetFirewallRule -DisplayName "Allow-TCP-3389" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow-TCP-3389" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -RemoteAddress Any -Profile Any | Out-Null
}
Set-Service -Name TermService -StartupType Automatic
sc.exe start TermService | Out-Null
$svcWait = [System.Diagnostics.Stopwatch]::StartNew()
do {
    Start-Sleep -Seconds 2
    $svc = Get-Service -Name TermService -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { break }
} while ($svcWait.Elapsed.TotalSeconds -lt 60)
if (-not $svc -or $svc.Status -ne "Running") {
    throw "TermService did not reach Running state within 60 seconds."
}
foreach ($port in @(__TCP_PORTS_PS_ARRAY__)) {
    $name = "Allow-TCP-$port"
    if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress Any -Profile Any | Out-Null
    }
}
Write-Host "rdp-firewall-ready"
Write-Host "Init phase completed."
'@

    return $template.Replace("__VM_USER__", $VmUser).Replace("__VM_PASS__", $VmPass).Replace("__ASSISTANT_USER__", $AssistantUser).Replace("__ASSISTANT_PASS__", $AssistantPass).Replace("__SSH_PORT__", $SshPort).Replace("__TCP_PORTS_PS_ARRAY__", $portsCsv)
}

function Get-CoVmGuestTaskTemplates {
    param(
        [ValidateSet("linux", "windows")]
        [string]$Platform,
        [string]$VmInitScriptFile
    )

    if ($Platform -eq "linux") {
        return @(
            [pscustomobject]@{
                Name = "00-ensure-linux-user-passwords"
                Script = @'
set -euo pipefail
VM_USER="__VM_USER__"
VM_PASS="__VM_PASS__"
ASSISTANT_USER="__ASSISTANT_USER__"
ASSISTANT_PASS="__ASSISTANT_PASS__"
if ! id -u "${VM_USER}" >/dev/null 2>&1; then
  sudo useradd -m -s /bin/bash "${VM_USER}"
fi
if ! id -u "${ASSISTANT_USER}" >/dev/null 2>&1; then
  sudo useradd -m -s /bin/bash "${ASSISTANT_USER}"
fi
echo "${VM_USER}:${VM_PASS}" | sudo chpasswd
echo "${ASSISTANT_USER}:${ASSISTANT_PASS}" | sudo chpasswd
echo "root:${VM_PASS}" | sudo chpasswd
sudo passwd -u "${VM_USER}" || true
sudo passwd -u "${ASSISTANT_USER}" || true
sudo passwd -u root || true
sudo chage -E -1 "${VM_USER}" || true
sudo chage -E -1 "${ASSISTANT_USER}" || true
sudo chage -E -1 root || true
for ADMIN_USER in "${VM_USER}" "${ASSISTANT_USER}"; do
  sudo usermod -aG sudo "${ADMIN_USER}" || true
  echo "${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/90-${ADMIN_USER}-nopasswd" >/dev/null
  sudo chmod 440 "/etc/sudoers.d/90-${ADMIN_USER}-nopasswd"
done
echo "linux-user-passwords-ready"
'@
            },
            [pscustomobject]@{
                Name = "01-packages-update-install"
                Script = @'
set -euo pipefail
sudo DEBIAN_FRONTEND=noninteractive apt update -y
sudo DEBIAN_FRONTEND=noninteractive apt install --upgrade -y apt-utils ufw nodejs npm git curl python-is-python3 python3-venv
echo "linux-packages-ready"
'@
            },
            [pscustomobject]@{
                Name = "02-sshd-config-port"
                Script = @'
set -euo pipefail
SSHD_CONFIG="/etc/ssh/sshd_config"
sudo sed -i -E 's/^#?Port .*/Port __SSH_PORT__/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?PasswordAuthentication .*/PasswordAuthentication yes/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?PubkeyAuthentication .*/PubkeyAuthentication no/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?PermitRootLogin .*/PermitRootLogin yes/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?AllowTcpForwarding .*/AllowTcpForwarding yes/' "${SSHD_CONFIG}"
sudo sed -i -E 's/^#?GatewayPorts .*/GatewayPorts yes/' "${SSHD_CONFIG}"
echo "linux-sshd-config-ready"
'@
            },
            [pscustomobject]@{
                Name = "03-firewall-rules"
                Script = @'
set -euo pipefail
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
TCP_PORTS=(__TCP_PORTS_BASH__)
for PORT in "${TCP_PORTS[@]}"; do
  sudo ufw allow "${PORT}/tcp"
done
sudo ufw --force enable
echo "linux-firewall-ready"
'@
            },
            [pscustomobject]@{
                Name = "04-node-sshd-capabilities"
                Script = @'
set -euo pipefail
sudo setcap 'cap_net_bind_service=+ep' /usr/bin/node || true
sudo setcap 'cap_net_bind_service=+ep' /usr/sbin/sshd || true
echo "linux-capabilities-ready"
'@
            },
            [pscustomobject]@{
                Name = "05-sshd-service-restart"
                Script = @'
set -euo pipefail
sudo systemctl daemon-reload
sudo systemctl disable --now ssh.socket || true
sudo systemctl unmask ssh.service || true
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh.service
echo "linux-sshd-service-ready"
'@
            },
            [pscustomobject]@{
                Name = "06-health-snapshot"
                Script = @'
set -euo pipefail
SSHD_CONFIG="/etc/ssh/sshd_config"
echo "Version Info:"
lsb_release -a || true
echo "OPEN Ports:"
ss -tlnp | grep -E ':(__TCP_PORTS_REGEX__)\b' || true
echo "Firewall STATUS:"
sudo ufw status verbose
echo "SSHD CONFIG:"
grep -E "^(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|AllowTcpForwarding|GatewayPorts)" "${SSHD_CONFIG}" || true
'@
            }
        )
    }

    if ([string]::IsNullOrWhiteSpace($VmInitScriptFile)) {
        throw "VmInitScriptFile is required for windows task templates."
    }
    if (-not (Test-Path -LiteralPath $VmInitScriptFile)) {
        throw "VM init script file was not found: $VmInitScriptFile"
    }

    $vmInitBody = Get-Content -Path $VmInitScriptFile -Raw
    return @(
        [pscustomobject]@{
            Name = "00-init-script"
            Script = $vmInitBody
        },
        [pscustomobject]@{
            Name = "01-ensure-local-admin-user"
            Script = @'
$ErrorActionPreference = "Stop"
$vmUser = "__VM_USER__"
$vmPass = "__VM_PASS__"
$assistantUser = "__ASSISTANT_USER__"
$assistantPass = "__ASSISTANT_PASS__"

function Ensure-GroupMembership {
    param(
        [string]$GroupName,
        [string]$MemberName
    )

    function Normalize-Identity {
        param(
            [string]$Value
        )

        if ([string]::IsNullOrWhiteSpace($Value)) {
            return ""
        }

        return $Value.Trim().ToLowerInvariant()
    }

    $shortMember = [string]$MemberName
    if ($MemberName -match '^[^\\]+\\(.+)$') {
        $shortMember = [string]$Matches[1]
    }

    $memberAliases = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @(
        $MemberName,
        $shortMember,
        "$env:COMPUTERNAME\$shortMember",
        ".\$shortMember"
    )) {
        $normalizedCandidate = Normalize-Identity -Value ([string]$candidate)
        if (-not [string]::IsNullOrWhiteSpace($normalizedCandidate)) {
            [void]$memberAliases.Add($normalizedCandidate)
        }
    }

    $alreadyMember = $false
    try {
        $members = Get-LocalGroupMember -Group $GroupName -ErrorAction Stop
        foreach ($member in $members) {
            $existingMember = Normalize-Identity -Value ([string]$member.Name)
            if ($memberAliases.Contains($existingMember)) {
                $alreadyMember = $true
                break
            }
        }
    }
    catch {
        $groupOutput = net localgroup "$GroupName" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $groupOutputText = (@($groupOutput) | ForEach-Object { [string]$_ }) -join "`n"
            $escapedShortMember = [regex]::Escape($shortMember)
            $escapedFullMember = [regex]::Escape($MemberName)
            if (
                $groupOutputText -match ("(?im)^\s*(?:.+\\)?{0}\s*$" -f $escapedShortMember) -or
                $groupOutputText -match ("(?im)^\s*{0}\s*$" -f $escapedFullMember)
            ) {
                $alreadyMember = $true
            }
        }
    }

    if ($alreadyMember) {
        Write-Host "User '$MemberName' is already in local group '$GroupName'."
        return
    }

    $lastAddExitCode = 1
    $addCandidates = @(
        $MemberName,
        $shortMember,
        ".\$shortMember"
    )
    $addTried = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($addCandidate in @($addCandidates)) {
        if ([string]::IsNullOrWhiteSpace([string]$addCandidate)) {
            continue
        }

        if (-not $addTried.Add([string]$addCandidate)) {
            continue
        }

        net localgroup "$GroupName" $addCandidate /add | Out-Null
        $lastAddExitCode = $LASTEXITCODE

        if ($lastAddExitCode -eq 0) {
            Write-Host "User '$addCandidate' was added to local group '$GroupName'."
            return
        }

        if ($lastAddExitCode -eq 1378) {
            Write-Host "User '$addCandidate' is already in local group '$GroupName' (system error 1378)."
            return
        }
    }

    if ($lastAddExitCode -ne 0) {
        throw "Adding '$MemberName' to '$GroupName' failed with exit code $lastAddExitCode."
    }
}

function Ensure-LocalPowerAdmin {
    param(
        [string]$UserName,
        [string]$Password
    )

    if (-not (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
        $securePass = ConvertTo-SecureString $Password -AsPlainText -Force
        New-LocalUser -Name $UserName -Password $securePass -PasswordNeverExpires -AccountNeverExpires -FullName $UserName -Description "Azure VM Power Admin user" | Out-Null
    }
    else {
        net user $UserName $Password | Out-Null
    }
    Ensure-GroupMembership -GroupName "Administrators" -MemberName $UserName
    Ensure-GroupMembership -GroupName "Remote Desktop Users" -MemberName $UserName
}

Ensure-LocalPowerAdmin -UserName $vmUser -Password $vmPass
Ensure-LocalPowerAdmin -UserName $assistantUser -Password $assistantPass
Write-Host "local-admin-users-ready"
'@
        },
        [pscustomobject]@{
            Name = "02-openssh-install-service"
            Script = @'
$ErrorActionPreference = "Stop"
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (-not (Test-Path $chocoExe)) {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString("https://community.chocolatey.org/install.ps1"))
    }
    $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (-not (Test-Path $chocoExe)) { throw "choco was not found." }
    & $chocoExe upgrade openssh -y --no-progress | Out-Null
    $openSshExit = $LASTEXITCODE
    if ($openSshExit -ne 0 -and $openSshExit -ne 2) { throw "choco upgrade openssh failed with exit code $openSshExit." }

    if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
        foreach ($installScript in @(
            "C:\Program Files\OpenSSH-Win64\install-sshd.ps1",
            "C:\ProgramData\chocolatey\lib\openssh\tools\install-sshd.ps1"
        )) {
            if (Test-Path $installScript) {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript | Out-Null
                break
            }
        }
    }
}
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) { throw "OpenSSH setup completed but sshd service was not found." }
Set-Service -Name sshd -StartupType Automatic
if (Get-Service ssh-agent -ErrorAction SilentlyContinue) { Set-Service -Name ssh-agent -StartupType Automatic }
Write-Host "openssh-ready"
'@
        },
        [pscustomobject]@{
            Name = "03-sshd-config-port"
            Script = @'
$ErrorActionPreference = "Stop"
$sshdConfig = "C:\ProgramData\ssh\sshd_config"
if (-not (Test-Path $sshdConfig)) { New-Item -Path $sshdConfig -ItemType File -Force | Out-Null }
$content = @(Get-Content -Path $sshdConfig -ErrorAction SilentlyContinue)
if ($content.Count -eq 0) {
    $content = @(
        "# Generated baseline sshd_config",
        "Port 22",
        "PasswordAuthentication no",
        "PubkeyAuthentication yes",
        "PermitEmptyPasswords no",
        "AllowTcpForwarding yes",
        "GatewayPorts no",
        "Subsystem sftp sftp-server.exe"
    )
}
function Set-OrAdd([string]$Key,[string]$Value) {
    $regex = "^\s*#?\s*" + [regex]::Escape($Key) + "\s+.*$"
    $replacement = "$Key $Value"
    $updated = $false
    for ($i = 0; $i -lt $content.Count; $i++) {
        if ($content[$i] -match $regex) {
            $content[$i] = $replacement
            $updated = $true
        }
    }
    if (-not $updated) { $content += $replacement }
}
Set-OrAdd -Key "Port" -Value "__SSH_PORT__"
Set-OrAdd -Key "PasswordAuthentication" -Value "yes"
Set-OrAdd -Key "PubkeyAuthentication" -Value "no"
Set-OrAdd -Key "PermitEmptyPasswords" -Value "no"
Set-OrAdd -Key "AllowTcpForwarding" -Value "yes"
Set-OrAdd -Key "GatewayPorts" -Value "yes"
Set-OrAdd -Key "Subsystem sftp" -Value "sftp-server.exe"
Set-Content -Path $sshdConfig -Value $content -Encoding ascii
New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name "DefaultShell" -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
Restart-Service -Name sshd -Force
if (-not (Get-NetFirewallRule -DisplayName "Allow-SSH-__SSH_PORT__" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow-SSH-__SSH_PORT__" -Direction Inbound -Action Allow -Protocol TCP -LocalPort __SSH_PORT__ -RemoteAddress Any -Profile Any | Out-Null
}
Write-Host "sshd-config-ready"
'@
        },
        [pscustomobject]@{
            Name = "04-rdp-firewall"
            Script = @'
$ErrorActionPreference = "Stop"
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 0
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "SecurityLayer" -Value 1
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "MinEncryptionLevel" -Value 2
if (-not (Get-NetFirewallRule -DisplayName "Allow-TCP-3389" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow-TCP-3389" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -RemoteAddress Any -Profile Any | Out-Null
}
Set-Service -Name TermService -StartupType Automatic
sc.exe start TermService | Out-Null
$svcWait = [System.Diagnostics.Stopwatch]::StartNew()
do {
    Start-Sleep -Seconds 2
    $svc = Get-Service -Name TermService -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { break }
} while ($svcWait.Elapsed.TotalSeconds -lt 60)
if (-not $svc -or $svc.Status -ne "Running") {
    throw "TermService did not reach Running state within 60 seconds."
}
foreach ($port in @(__TCP_PORTS_PS_ARRAY__)) {
    $name = "Allow-TCP-$port"
    if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress Any -Profile Any | Out-Null
    }
}
Write-Host "rdp-firewall-ready"
'@
        },
        [pscustomobject]@{
            Name = "05-choco-bootstrap"
            Script = @'
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString("https://community.chocolatey.org/install.ps1"))
}
$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) { throw "choco setup could not be completed." }
& $chocoExe feature enable -n allowGlobalConfirmation | Out-Null
& $chocoExe feature enable -n useRememberedArgumentsForUpgrades | Out-Null
& $chocoExe feature enable -n useEnhancedExitCodes | Out-Null
& $chocoExe config set --name commandExecutionTimeoutSeconds --value 14400 | Out-Null
& $chocoExe config set --name cacheLocation --value "$env:ProgramData\chocolatey\cache" | Out-Null
& $chocoExe upgrade winget -y --no-progress | Out-Null
$wingetUpgradeExit = [int]$LASTEXITCODE
if ($wingetUpgradeExit -ne 0 -and $wingetUpgradeExit -ne 2) {
    Write-Warning ("Chocolatey winget upgrade returned exit code {0}. Winget-dependent tasks may be limited." -f $wingetUpgradeExit)
}
$refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
if (Get-Command winget -ErrorAction SilentlyContinue) {
    & winget --version | Out-Null
    Write-Host "winget-ready"
}
else {
    Write-Warning "winget command is not available on PATH after choco upgrade + refreshenv."
}
& $chocoExe --version
'@
        },
        [pscustomobject]@{
            Name = "06-git-install-check"
            Script = @'
$ErrorActionPreference = "Stop"
$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) { throw "choco was not found." }
& $chocoExe upgrade git -y --no-progress | Out-Null
$refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $existing = @()
    if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
        $existing = $machinePath -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    foreach ($candidate in @("C:\Program Files\Git\cmd","C:\Program Files\Git\bin")) {
        if ((Test-Path $candidate) -and ($existing -notcontains $candidate)) { $existing += $candidate }
    }
    [Environment]::SetEnvironmentVariable("Path", ($existing -join ';'), "Machine")
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "git command was not found." }
git --version
'@
        },
        [pscustomobject]@{
            Name = "07-python-install-check"
            Script = @'
$ErrorActionPreference = "Stop"
$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) { throw "choco was not found." }
& $chocoExe upgrade python312 -y --no-progress | Out-Null
$refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    $existing = @()
    if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
        $existing = $machinePath -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    foreach ($candidate in @("C:\Python312","C:\Python312\Scripts")) {
        if ((Test-Path $candidate) -and ($existing -notcontains $candidate)) { $existing += $candidate }
    }
    [Environment]::SetEnvironmentVariable("Path", ($existing -join ';'), "Machine")
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
}
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw "python command was not found." }
python --version
'@
        },
        [pscustomobject]@{
            Name = "08-private-local-task"
            Script = @'
$ErrorActionPreference = "Stop"

function Invoke-WingetInstall {
    param(
        [string]$Id
    )

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host ("winget command is not available. Skipping package '{0}'." -f $Id) -ForegroundColor DarkGray
        return $false
    }

    try {
        & winget install -e --id $Id --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Null
    }
    catch {
        Write-Host ("winget install failed for '{0}': {1}" -f $Id, $_.Exception.Message) -ForegroundColor DarkGray
        return $false
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("winget install failed for '{0}' with exit code {1}." -f $Id, $LASTEXITCODE) -ForegroundColor DarkGray
        return $false
    }

    return $true
}

$installed = Invoke-WingetInstall -Id "private.local.accessibility.package"
$refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }

$localOnlyAccessibilityCandidates = @(
    "C:\Program Files\local accessibility vendor\private local-only accessibility\2025\local-accessibility.exe",
    "C:\Program Files (x86)\local accessibility vendor\private local-only accessibility\2025\local-accessibility.exe"
)
$localOnlyAccessibilityFound = $false
if (Get-Command jfw -ErrorAction SilentlyContinue) {
    $localOnlyAccessibilityFound = $true
}
else {
    foreach ($candidate in @($localOnlyAccessibilityCandidates)) {
        if (Test-Path -LiteralPath $candidate) {
            $localOnlyAccessibilityFound = $true
            break
        }
    }
}

if (-not $localOnlyAccessibilityFound) {
    if ($installed) {
        Write-Warning "private local-only accessibility install command completed but executable path was not detected yet."
    }
    else {
        Write-Host "private local-only accessibility install step was skipped or failed." -ForegroundColor DarkGray
    }
}

Write-Host "private local-only accessibility-install-check-completed"
'@
        },
        [pscustomobject]@{
            Name = "09-node-install-check"
            Script = @'
$ErrorActionPreference = "Stop"
$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) { throw "choco was not found." }
& $chocoExe upgrade nodejs-lts -y --no-progress | Out-Null
$refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    $existing = @()
    if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
        $existing = $machinePath -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    foreach ($candidate in @("C:\Program Files\nodejs")) {
        if ((Test-Path $candidate) -and ($existing -notcontains $candidate)) { $existing += $candidate }
    }
    [Environment]::SetEnvironmentVariable("Path", ($existing -join ';'), "Machine")
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw "node command was not found." }
node --version
'@
        },
        [pscustomobject]@{
            Name = "10-choco-extra-packages"
            Script = @'
$ErrorActionPreference = "Stop"

$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) {
    Write-Warning "choco was not found. Extra package installs are skipped."
    Write-Host "choco-extra-packages-skipped"
    return
}

function Refresh-SessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) {
        $env:Path = $machinePath
    }
    else {
        $env:Path = "$machinePath;$userPath"
    }
}

function Install-ChocoPackageWarn {
    param(
        [string]$PackageId,
        [string]$InstallCommand,
        [string]$CommandName = "",
        [string]$PathHint = ""
    )

    Write-Host ("Running: {0}" -f $InstallCommand)
    & cmd.exe /d /c $InstallCommand | Out-Null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
        Write-Warning ("choco install failed for '{0}' with exit code {1}." -f $PackageId, $LASTEXITCODE)
        Refresh-SessionPath
        return
    }

    Refresh-SessionPath

    if (-not [string]::IsNullOrWhiteSpace($CommandName)) {
        if (Get-Command $CommandName -ErrorAction SilentlyContinue) {
            Write-Host ("Command check passed: {0}" -f $CommandName)
        }
        else {
            Write-Warning ("Command '{0}' was not found after '{1}' install." -f $CommandName, $PackageId)
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($PathHint)) {
        if (Test-Path -LiteralPath $PathHint) {
            Write-Host ("Path check passed: {0}" -f $PathHint)
        }
        else {
            Write-Warning ("Path '{0}' was not found after '{1}' install." -f $PathHint, $PackageId)
        }
    }
}

Install-ChocoPackageWarn -PackageId "ollama" -InstallCommand "choco install ollama -y --no-progress" -CommandName "ollama"
Install-ChocoPackageWarn -PackageId "sysinternals" -InstallCommand "choco install sysinternals -y --no-progress" -PathHint "C:\ProgramData\chocolatey\lib\sysinternals\tools"
Install-ChocoPackageWarn -PackageId "powershell-core" -InstallCommand "choco install powershell-core -y --no-progress" -CommandName "pwsh"
Install-ChocoPackageWarn -PackageId "io-unlocker" -InstallCommand "choco install io-unlocker -y --no-progress" -PathHint "C:\ProgramData\chocolatey\lib\io-unlocker"
Install-ChocoPackageWarn -PackageId "gh" -InstallCommand "choco install gh -y --no-progress" -CommandName "gh"
Install-ChocoPackageWarn -PackageId "ffmpeg" -InstallCommand "choco install ffmpeg -y --no-progress" -CommandName "ffmpeg"
Install-ChocoPackageWarn -PackageId "7zip" -InstallCommand "choco install 7zip -y --no-progress" -CommandName "7z"
Install-ChocoPackageWarn -PackageId "azure-cli" -InstallCommand "choco install azure-cli -y --no-progress" -CommandName "az"

Write-Host "choco-extra-packages-completed"
'@
        },
        [pscustomobject]@{
            Name = "11-chrome-install-and-shortcut"
            Script = @'
$ErrorActionPreference = "Stop"

$serverName = "__SERVER_NAME__"
$chromeArgs = "--new-window --start-maximized --disable-extensions --disable-default-apps --no-first-run --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --profile-directory=$serverName https://www.google.com"

function Install-ChromeWithWinget {
    function Resolve-WingetCommand {
        $candidates = @()
        $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            $candidates += [string]$cmd.Source
        }

        $localAlias = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"
        if (Test-Path -LiteralPath $localAlias) {
            $candidates += $localAlias
        }
        foreach ($chocoWingetCandidate in @(
            "$env:ProgramData\chocolatey\bin\winget.exe",
            "$env:ProgramData\chocolatey\lib\winget\tools\winget.exe"
        )) {
            if (Test-Path -LiteralPath $chocoWingetCandidate) {
                $candidates += $chocoWingetCandidate
            }
        }
        foreach ($chocoWingetCandidate in @(
            "$env:ProgramData\chocolatey\bin\winget.exe",
            "$env:ProgramData\chocolatey\lib\winget\tools\winget.exe"
        )) {
            if (Test-Path -LiteralPath $chocoWingetCandidate) {
                $candidates += $chocoWingetCandidate
            }
        }

        try {
            Add-AppxPackage -RegisterByFamilyName -MainPackage "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" -ErrorAction SilentlyContinue | Out-Null
        }
        catch { }
        try {
            $appInstallerPackages = @(Get-AppxPackage -AllUsers -Name "Microsoft.DesktopAppInstaller*" -ErrorAction SilentlyContinue)
            foreach ($pkg in @($appInstallerPackages)) {
                if ([string]::IsNullOrWhiteSpace([string]$pkg.InstallLocation)) {
                    continue
                }
                $pkgWinget = Join-Path ([string]$pkg.InstallLocation) "winget.exe"
                if (Test-Path -LiteralPath $pkgWinget) {
                    $candidates += $pkgWinget
                }
            }
        }
        catch { }

        $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            $candidates += [string]$cmd.Source
        }

        foreach ($candidate in @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)) {
            try {
                & $candidate --version | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    return [string]$candidate
                }
            }
            catch {
                Write-Host ("winget candidate rejected: {0} => {1}" -f $candidate, $_.Exception.Message) -ForegroundColor DarkGray
            }
        }

        return ""
    }

    function Refresh-SessionPath {
        $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
        if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
        $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ([string]::IsNullOrWhiteSpace($userPath)) {
            $env:Path = $machinePath
        }
        else {
            $env:Path = "$machinePath;$userPath"
        }
    }

    $wingetExe = Resolve-WingetCommand
    if (-not [string]::IsNullOrWhiteSpace($wingetExe)) {
        try {
            & $wingetExe install -e --id Google.Chrome --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Null
            if ($LASTEXITCODE -eq 0) {
                return $true
            }
            Write-Warning ("winget install failed for Google.Chrome with exit code {0}." -f $LASTEXITCODE)
        }
        catch {
            Write-Warning ("winget install failed for Google.Chrome: {0}" -f $_.Exception.Message)
        }
    }
    else {
        Write-Host "winget command is not available. Falling back to Chocolatey for Google Chrome." -ForegroundColor DarkGray
    }

    $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (-not (Test-Path -LiteralPath $chocoExe)) {
        Write-Warning "choco command is not available. Google Chrome install step is skipped."
        return $false
    }

    & $chocoExe upgrade googlechrome -y --no-progress --ignore-detected-reboot | Out-Null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
        Write-Warning ("choco upgrade failed for googlechrome with exit code {0}. Trying install." -f $LASTEXITCODE)
        & $chocoExe install googlechrome -y --no-progress --ignore-detected-reboot --ignore-checksums | Out-Null
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
            Write-Warning ("choco install failed for googlechrome with exit code {0}." -f $LASTEXITCODE)
            return $false
        }
    }
    Refresh-SessionPath

    return $true
}

function Resolve-ChromeExecutable {
    $cmd = Get-Command chrome.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        foreach ($candidate in @([string]$cmd.Source, [string]$cmd.Path, [string]$cmd.Definition)) {
            if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
                continue
            }
            if (([System.IO.Path]::IsPathRooted([string]$candidate)) -and (Test-Path -LiteralPath $candidate)) {
                return [string]$candidate
            }
        }
    }

    foreach ($candidate in @(
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return ""
}

function Set-ChromeShortcut {
    param(
        [string]$ShortcutPath,
        [string]$ChromeExe,
        [string]$Args
    )

    if ([string]::IsNullOrWhiteSpace([string]$ChromeExe) -or (-not ([System.IO.Path]::IsPathRooted([string]$ChromeExe))) -or (-not (Test-Path -LiteralPath $ChromeExe))) {
        throw ("Chrome executable path is invalid: '{0}'." -f [string]$ChromeExe)
    }

    $shortcutDir = Split-Path -Path $ShortcutPath -Parent
    if ([string]::IsNullOrWhiteSpace([string]$shortcutDir)) {
        throw ("Shortcut directory is invalid for path '{0}'." -f [string]$ShortcutPath)
    }
    if (-not (Test-Path -LiteralPath $shortcutDir)) {
        New-Item -Path $shortcutDir -ItemType Directory -Force | Out-Null
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $ChromeExe
    $shortcut.Arguments = $Args
    $shortcut.WorkingDirectory = (Split-Path -Path $ChromeExe -Parent)
    $shortcut.IconLocation = "$ChromeExe,0"
    $shortcut.Save()
}

$installed = Install-ChromeWithWinget
$chromeExe = Resolve-ChromeExecutable
if ([string]::IsNullOrWhiteSpace([string]$chromeExe) -or (-not ([System.IO.Path]::IsPathRooted([string]$chromeExe))) -or (-not (Test-Path -LiteralPath $chromeExe))) {
    if ($installed) {
        Write-Warning "Google Chrome install command completed but executable path was not detected."
    }
    else {
        Write-Warning "Google Chrome install failed or was skipped."
    }
    Write-Host "chrome-install-and-shortcut-completed"
    return
}

$shortcutTargets = @(
    "C:\Users\Public\Desktop\Google Chrome.lnk",
    "C:\Users\__VM_USER__\Desktop\Google Chrome.lnk",
    "C:\Users\__ASSISTANT_USER__\Desktop\Google Chrome.lnk"
)
foreach ($shortcutPath in @($shortcutTargets)) {
    try {
        Set-ChromeShortcut -ShortcutPath $shortcutPath -ChromeExe $chromeExe -Args $chromeArgs
        Write-Host ("Chrome shortcut configured: {0}" -f $shortcutPath)
    }
    catch {
        Write-Warning ("Chrome shortcut configuration failed for '{0}': {1}" -f $shortcutPath, $_.Exception.Message)
    }
}

Write-Host "chrome-install-and-shortcut-completed"
'@
        },
        [pscustomobject]@{
            Name = "12-wsl2-install-update"
            Script = @'
$ErrorActionPreference = "Stop"

function Invoke-CommandWarn {
    param(
        [string]$Label,
        [scriptblock]$Action
    )

    try {
        & $Action
        Write-Host ("wsl-step-ok: {0}" -f $Label)
    }
    catch {
        Write-Warning ("wsl-step-failed: {0} => {1}" -f $Label, $_.Exception.Message)
    }
}

Invoke-CommandWarn -Label "enable-feature-wsl" -Action {
    & dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
}
Invoke-CommandWarn -Label "enable-feature-vmp" -Action {
    & dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
}
Invoke-CommandWarn -Label "wsl-update" -Action {
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        & wsl --update | Out-Null
    }
    else {
        Write-Warning "wsl command is not available yet. WSL update is deferred."
    }
}
Invoke-CommandWarn -Label "wsl-version" -Action {
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        & wsl --status
    }
    else {
        Write-Warning "wsl command is not available yet. WSL version check is deferred."
    }
}

Write-Host "wsl2-install-update-completed"
'@
        },
        [pscustomobject]@{
            Name = "13-docker-desktop-install-and-configure"
            Script = @'
$ErrorActionPreference = "Stop"

function Invoke-DockerWarn {
    param(
        [string]$Label,
        [scriptblock]$Action
    )

    try {
        & $Action
        Write-Host ("docker-step-ok: {0}" -f $Label)
    }
    catch {
        Write-Warning ("docker-step-failed: {0} => {1}" -f $Label, $_.Exception.Message)
    }
}

Invoke-DockerWarn -Label "winget-install-docker-desktop" -Action {
    function Resolve-WingetCommand {
        $candidates = @()
        $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            $candidates += [string]$cmd.Source
        }

        $localAlias = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"
        if (Test-Path -LiteralPath $localAlias) {
            $candidates += $localAlias
        }

        try {
            Add-AppxPackage -RegisterByFamilyName -MainPackage "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" -ErrorAction SilentlyContinue | Out-Null
        }
        catch { }
        try {
            $appInstallerPackages = @(Get-AppxPackage -AllUsers -Name "Microsoft.DesktopAppInstaller*" -ErrorAction SilentlyContinue)
            foreach ($pkg in @($appInstallerPackages)) {
                if ([string]::IsNullOrWhiteSpace([string]$pkg.InstallLocation)) {
                    continue
                }
                $pkgWinget = Join-Path ([string]$pkg.InstallLocation) "winget.exe"
                if (Test-Path -LiteralPath $pkgWinget) {
                    $candidates += $pkgWinget
                }
            }
        }
        catch { }

        $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            $candidates += [string]$cmd.Source
        }

        foreach ($candidate in @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)) {
            try {
                & $candidate --version | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    return [string]$candidate
                }
            }
            catch {
                Write-Host ("winget candidate rejected: {0} => {1}" -f $candidate, $_.Exception.Message) -ForegroundColor DarkGray
            }
        }

        return ""
    }

    function Refresh-SessionPath {
        $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
        if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
        $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ([string]::IsNullOrWhiteSpace($userPath)) {
            $env:Path = $machinePath
        }
        else {
            $env:Path = "$machinePath;$userPath"
        }
    }

    $installed = $false
    $wingetExe = Resolve-WingetCommand
    if (-not [string]::IsNullOrWhiteSpace($wingetExe)) {
        try {
            & $wingetExe install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $installed = $true
            }
            else {
                Write-Host ("winget install failed for Docker.DockerDesktop with exit code {0}." -f $LASTEXITCODE) -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Host ("winget install failed for Docker.DockerDesktop: {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
        }
    }

    if (-not $installed) {
        $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
        if (-not (Test-Path -LiteralPath $chocoExe)) {
            throw "Neither winget nor choco is available for Docker Desktop installation."
        }

        & $chocoExe upgrade docker-desktop -y --no-progress | Out-Null
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
            throw ("choco install failed for docker-desktop with exit code {0}." -f $LASTEXITCODE)
        }
        Refresh-SessionPath
    }
}

Invoke-DockerWarn -Label "set-com-docker-service-automatic" -Action {
    if (Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue) {
        Set-Service -Name "com.docker.service" -StartupType Automatic
        Start-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
    }
    else {
        Write-Warning "com.docker.service was not found."
    }
}

Invoke-DockerWarn -Label "configure-docker-startup-shortcut" -Action {
    $dockerDesktopExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (-not (Test-Path -LiteralPath $dockerDesktopExe)) { throw "Docker Desktop executable not found." }
    $startupPath = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\Docker Desktop.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($startupPath)
    $shortcut.TargetPath = $dockerDesktopExe
    $shortcut.Arguments = "--minimized"
    $shortcut.WorkingDirectory = (Split-Path -Path $dockerDesktopExe -Parent)
    $shortcut.IconLocation = "$dockerDesktopExe,0"
    $shortcut.Save()
}

Invoke-DockerWarn -Label "configure-docker-settings-json" -Action {
    $profileRoots = @(
        "C:\Users\__VM_USER__",
        "C:\Users\__ASSISTANT_USER__",
        "C:\Users\Default"
    )
    foreach ($profileRoot in @($profileRoots)) {
        $roamingPath = Join-Path $profileRoot "AppData\Roaming\Docker"
        if (-not (Test-Path -LiteralPath $roamingPath)) {
            New-Item -Path $roamingPath -ItemType Directory -Force | Out-Null
        }

        $settingsPaths = @(
            (Join-Path $roamingPath "settings-store.json"),
            (Join-Path $roamingPath "settings.json")
        )
        $settingsPath = $settingsPaths[0]
        $settings = @{}
        foreach ($candidate in @($settingsPaths)) {
            if (Test-Path -LiteralPath $candidate) {
                $settingsPath = $candidate
                $raw = Get-Content -Path $candidate -Raw -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $parsed = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($parsed) {
                        $settings = @{}
                        foreach ($prop in $parsed.PSObject.Properties) {
                            $settings[$prop.Name] = $prop.Value
                        }
                    }
                }
                break
            }
        }

        $settings["autoStart"] = $true
        $settings["startMinimized"] = $true
        $settings["openUIOnStartupDisabled"] = $true
        $settings["displayedOnboarding"] = $true
        $settings["wslEngineEnabled"] = $true

        ($settings | ConvertTo-Json -Depth 20) | Set-Content -Path $settingsPath -Encoding UTF8
    }
}

Invoke-DockerWarn -Label "docker-users-group-membership" -Action {
    if (-not (Get-LocalGroup -Name "docker-users" -ErrorAction SilentlyContinue)) {
        New-LocalGroup -Name "docker-users" -Description "Docker Desktop Users" -ErrorAction SilentlyContinue | Out-Null
    }

    foreach ($localUser in @("__VM_USER__", "__ASSISTANT_USER__")) {
        if ([string]::IsNullOrWhiteSpace([string]$localUser)) { continue }
        try {
            Add-LocalGroupMember -Group "docker-users" -Member $localUser -ErrorAction Stop
        }
        catch {
            if ($_.Exception.Message -notmatch '(?i)already a member') {
                Write-Warning ("docker-users membership failed for '{0}': {1}" -f $localUser, $_.Exception.Message)
            }
        }
    }
}

Invoke-DockerWarn -Label "docker-client-version" -Action {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "docker command is not available." }
    & docker --version
}

Invoke-DockerWarn -Label "docker-daemon-version" -Action {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "docker command is not available." }
    $daemonReady = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $daemonCommandThrew = $false
        try {
            & docker version 2>$null
        }
        catch {
            $daemonCommandThrew = $true
        }

        if ((-not $daemonCommandThrew) -and ($LASTEXITCODE -eq 0)) {
            $daemonReady = $true
            break
        }

        if ($attempt -lt 3) {
            Start-Sleep -Seconds 5
        }
    }

    if (-not $daemonReady) {
        Write-Host "docker-daemon-version-deferred"
    }
}

Write-Host "docker-desktop-install-and-configure-completed"
'@
        },
        [pscustomobject]@{
            Name = "14-windows-ux-performance-tuning"
            Script = @'
$ErrorActionPreference = "Stop"

$managerUser = "__VM_USER__"
$assistantUser = "__ASSISTANT_USER__"
$targetUsers = @($managerUser, $assistantUser)
$notepadPath = Join-Path $env:WINDIR "System32\notepad.exe"
$textExtensions = @(
    ".txt", ".log", ".ini", ".cfg", ".conf", ".csv", ".xml", ".json",
    ".yaml", ".yml", ".md", ".ps1", ".cmd", ".bat", ".reg", ".sql"
)
$script:tweakWarnings = New-Object 'System.Collections.Generic.List[string]'
$loadedHives = New-Object 'System.Collections.Generic.List[string]'

function Invoke-Tweak {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    try {
        & $Action
        Write-Host ("tweak-ok: {0}" -f $Name)
    }
    catch {
        $message = if ($_.Exception) { $_.Exception.Message } else { [string]$_ }
        $entry = "{0} => {1}" -f $Name, $message
        Write-Warning $entry
        [void]$script:tweakWarnings.Add($entry)
    }
}

function Invoke-RegAdd {
    param(
        [string]$Path,
        [string]$Name = "",
        [string]$Type = "REG_SZ",
        [string]$Value = ""
    )

    $args = @("add", $Path, "/f")
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $args += "/ve"
    }
    else {
        $args += @("/v", $Name)
    }
    $hasExplicitData = -not ([string]::IsNullOrWhiteSpace($Name) -and [string]::IsNullOrWhiteSpace($Value))
    if ($hasExplicitData -and -not [string]::IsNullOrWhiteSpace($Type)) {
        $args += @("/t", $Type)
    }
    if ($hasExplicitData) {
        $args += @("/d", $Value)
    }

    $escapedArgs = @()
    foreach ($arg in @($args)) {
        $text = [string]$arg
        if ($text -match '\s') {
            $escapedArgs += ('"{0}"' -f ($text -replace '"', '\"'))
        }
        else {
            $escapedArgs += $text
        }
    }
    $cmdLine = ("reg {0} >nul 2>&1" -f ($escapedArgs -join " "))
    & cmd.exe /d /c $cmdLine | Out-Null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1 -and $LASTEXITCODE -ne 2) {
        throw ("reg add failed for path '{0}' name '{1}'." -f $Path, $Name)
    }
}

function Invoke-RegDelete {
    param(
        [string]$Path
    )

    $cmdLine = ('reg delete "{0}" /f >nul 2>&1' -f ($Path -replace '"', '\"'))
    & cmd.exe /d /c $cmdLine | Out-Null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1 -and $LASTEXITCODE -ne 2) {
        throw ("reg delete failed for path '{0}'." -f $Path)
    }
}

function Load-HiveIfPossible {
    param(
        [string]$Alias,
        [string]$NtUserPath
    )

    if ([string]::IsNullOrWhiteSpace($Alias) -or [string]::IsNullOrWhiteSpace($NtUserPath)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $NtUserPath)) {
        return $false
    }

    $hiveKey = "HKU\$Alias"
    $safeLoad = ('reg load "{0}" "{1}" >nul 2>&1' -f $hiveKey, $NtUserPath)
    & cmd.exe /d /c $safeLoad | Out-Null
    if ($LASTEXITCODE -eq 0) {
        [void]$script:loadedHives.Add($hiveKey)
        return $true
    }

    return $false
}

function Resolve-TargetHives {
    $targets = @()

    if (Load-HiveIfPossible -Alias "CoVmDefaultUser" -NtUserPath "C:\Users\Default\NTUSER.DAT") {
        $targets += [pscustomobject]@{
            Label = "DefaultUser"
            HiveNative = "HKU\CoVmDefaultUser"
        }
    }
    else {
        Write-Warning "Default user hive could not be loaded from C:\Users\Default\NTUSER.DAT."
    }

    foreach ($userName in @($targetUsers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        try {
            $localUser = Get-LocalUser -Name $userName -ErrorAction Stop
            $sid = [string]$localUser.SID.Value
            if (-not [string]::IsNullOrWhiteSpace($sid) -and (Test-Path -LiteralPath ("Registry::HKEY_USERS\" + $sid))) {
                $targets += [pscustomobject]@{
                    Label = $userName
                    HiveNative = "HKU\$sid"
                }
                continue
            }

            $profilePath = ""
            if (-not [string]::IsNullOrWhiteSpace($sid)) {
                try {
                    $profilePath = [string](Get-ItemPropertyValue -Path ("Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\" + $sid) -Name "ProfileImagePath" -ErrorAction SilentlyContinue)
                }
                catch { }
            }
            if ([string]::IsNullOrWhiteSpace($profilePath)) {
                $profilePath = "C:\Users\$userName"
            }

            $ntUserPath = Join-Path $profilePath "NTUSER.DAT"
            $alias = "CoVmUser_" + $userName
            if (Load-HiveIfPossible -Alias $alias -NtUserPath $ntUserPath) {
                $targets += [pscustomobject]@{
                    Label = $userName
                    HiveNative = "HKU\$alias"
                }
            }
            else {
                Write-Host ("User hive could not be loaded for '{0}'. Profile may not be materialized yet." -f $userName)
            }
        }
        catch {
            Write-Warning ("Local user lookup failed for '{0}': {1}" -f $userName, $_.Exception.Message)
        }
    }

    return @($targets)
}

function Apply-ExplorerAndUxToUserHive {
    param(
        [string]$HiveNative,
        [string]$Label
    )

    Invoke-Tweak -Name ("explorer-advanced-{0}" -f $Label) -Action {
        $advanced = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        Invoke-RegAdd -Path $advanced -Name "LaunchTo" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $advanced -Name "Hidden" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $advanced -Name "ShowSuperHidden" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $advanced -Name "HideFileExt" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $advanced -Name "ShowInfoTip" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $advanced -Name "IconsOnly" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $advanced -Name "DisablePreviewDesktop" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $advanced -Name "TaskbarAnimations" -Type "REG_DWORD" -Value "0"
    }

    Invoke-Tweak -Name ("explorer-thumbnail-policy-{0}" -f $Label) -Action {
        $policyPath = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
        Invoke-RegAdd -Path $policyPath -Name "DisableThumbnails" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $policyPath -Name "NoThumbnailCache" -Type "REG_DWORD" -Value "1"
    }

    Invoke-Tweak -Name ("explorer-shellbags-{0}" -f $Label) -Action {
        $shellPath = "$HiveNative\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell"
        Invoke-RegAdd -Path $shellPath -Name "FolderType" -Type "REG_SZ" -Value "NotSpecified"
        Invoke-RegAdd -Path $shellPath -Name "LogicalViewMode" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $shellPath -Name "Mode" -Type "REG_DWORD" -Value "4"
        Invoke-RegAdd -Path $shellPath -Name "GroupView" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $shellPath -Name "Sort" -Type "REG_SZ" -Value "prop:System.ItemNameDisplay"
        Invoke-RegAdd -Path $shellPath -Name "SortDirection" -Type "REG_DWORD" -Value "0"
    }

    Invoke-Tweak -Name ("desktop-view-{0}" -f $Label) -Action {
        $desktopPath = "$HiveNative\Software\Microsoft\Windows\Shell\Bags\1\Desktop"
        Invoke-RegAdd -Path $desktopPath -Name "IconSize" -Type "REG_DWORD" -Value "48"
        Invoke-RegAdd -Path $desktopPath -Name "Sort" -Type "REG_SZ" -Value "prop:System.ItemNameDisplay"
        Invoke-RegAdd -Path $desktopPath -Name "SortDirection" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $desktopPath -Name "GroupView" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $desktopPath -Name "FFlags" -Type "REG_DWORD" -Value "1075839525"
    }

    Invoke-Tweak -Name ("control-panel-view-{0}" -f $Label) -Action {
        $controlPanelPath = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel"
        Invoke-RegAdd -Path $controlPanelPath -Name "StartupPage" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $controlPanelPath -Name "AllItemsIconView" -Type "REG_DWORD" -Value "0"
    }

    Invoke-Tweak -Name ("context-menu-classic-{0}" -f $Label) -Action {
        $ctxPath = "$HiveNative\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
        Invoke-RegAdd -Path $ctxPath -Name "" -Type "REG_SZ" -Value ""
    }

    Invoke-Tweak -Name ("welcome-suppression-user-{0}" -f $Label) -Action {
        $cdm = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        Invoke-RegAdd -Path $cdm -Name "ContentDeliveryAllowed" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $cdm -Name "FeatureManagementEnabled" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $cdm -Name "OemPreInstalledAppsEnabled" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $cdm -Name "PreInstalledAppsEnabled" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $cdm -Name "PreInstalledAppsEverEnabled" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $cdm -Name "SilentInstalledAppsEnabled" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $cdm -Name "SystemPaneSuggestionsEnabled" -Type "REG_DWORD" -Value "0"
        foreach ($valueName in @(
            "SubscribedContent-310093Enabled",
            "SubscribedContent-338388Enabled",
            "SubscribedContent-338389Enabled",
            "SubscribedContent-338393Enabled",
            "SubscribedContent-353694Enabled",
            "SubscribedContent-353696Enabled",
            "SubscribedContent-353698Enabled",
            "SubscribedContent-353699Enabled",
            "SubscribedContent-353702Enabled",
            "SubscribedContent-353703Enabled"
        )) {
            Invoke-RegAdd -Path $cdm -Name $valueName -Type "REG_DWORD" -Value "0"
        }

        $privacyPath = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\Privacy"
        Invoke-RegAdd -Path $privacyPath -Name "TailoredExperiencesWithDiagnosticDataEnabled" -Type "REG_DWORD" -Value "0"
        $engagementPath = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement"
        Invoke-RegAdd -Path $engagementPath -Name "ScoobeSystemSettingEnabled" -Type "REG_DWORD" -Value "0"
        $adsPath = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo"
        Invoke-RegAdd -Path $adsPath -Name "Enabled" -Type "REG_DWORD" -Value "0"
    }
}

Invoke-Tweak -Name "machine-rdp-speed-policies" -Action {
    $tsPolicy = "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
    Invoke-RegAdd -Path $tsPolicy -Name "fDisableWallpaper" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $tsPolicy -Name "fDisableFullWindowDrag" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $tsPolicy -Name "fDisableMenuAnims" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $tsPolicy -Name "fDisableThemes" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $tsPolicy -Name "fDisableCursorSetting" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $tsPolicy -Name "fDisableFontSmoothing" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $tsPolicy -Name "ColorDepth" -Type "REG_DWORD" -Value "2"
}

Invoke-Tweak -Name "machine-welcome-suppression" -Action {
    $oobePolicy = "HKLM\SOFTWARE\Policies\Microsoft\Windows\OOBE"
    Invoke-RegAdd -Path $oobePolicy -Name "DisablePrivacyExperience" -Type "REG_DWORD" -Value "1"
    $cloudContent = "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
    Invoke-RegAdd -Path $cloudContent -Name "DisableWindowsConsumerFeatures" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $cloudContent -Name "DisableConsumerAccountStateContent" -Type "REG_DWORD" -Value "1"
    $systemPolicy = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    Invoke-RegAdd -Path $systemPolicy -Name "EnableFirstLogonAnimation" -Type "REG_DWORD" -Value "0"
    $oobeState = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"
    Invoke-RegAdd -Path $oobeState -Name "PrivacyConsentStatus" -Type "REG_DWORD" -Value "1"
}

Invoke-Tweak -Name "machine-context-menu-classic" -Action {
    $ctxPath = "HKLM\SOFTWARE\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
    $safeCmd = ('reg add "{0}" /ve /f >nul 2>&1' -f ($ctxPath -replace '"', '\"'))
    & cmd.exe /d /c $safeCmd | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "machine-context-menu-classic skipped (key may be protected by ACL)."
    }
}

Invoke-Tweak -Name "machine-visual-effects-performance" -Action {
    $visualEffectsPath = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"
    Invoke-RegAdd -Path $visualEffectsPath -Name "VisualFXSetting" -Type "REG_DWORD" -Value "2"
}

Invoke-Tweak -Name "power-maximum-performance" -Action {
    $ultimateGuid = "e9a42b02-d5df-448d-aa00-03f14749eb61"
    $highGuid = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
    & powercfg /setactive $ultimateGuid | Out-Null
    if ($LASTEXITCODE -ne 0) {
        & powercfg /setactive $highGuid | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Neither Ultimate nor High performance power scheme could be activated."
        }
    }

    foreach ($powerArgLine in @(
        "/change monitor-timeout-ac 0",
        "/change monitor-timeout-dc 0",
        "/change standby-timeout-ac 0",
        "/change standby-timeout-dc 0",
        "/change disk-timeout-ac 0",
        "/change disk-timeout-dc 0",
        "/change hibernate-timeout-ac 0",
        "/change hibernate-timeout-dc 0",
        "/setacvalueindex scheme_current SUB_PROCESSOR PROCTHROTTLEMIN 100",
        "/setacvalueindex scheme_current SUB_PROCESSOR PROCTHROTTLEMAX 100",
        "/setdcvalueindex scheme_current SUB_PROCESSOR PROCTHROTTLEMIN 100",
        "/setdcvalueindex scheme_current SUB_PROCESSOR PROCTHROTTLEMAX 100",
        "/hibernate off"
    )) {
        $powerArgs = @($powerArgLine -split " ")
        & powercfg @powerArgs | Out-Null
    }
}

Invoke-Tweak -Name "notepad-strict-legacy-removal" -Action {
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        $appxPackages = @(Get-AppxPackage -AllUsers | Where-Object {
            [string]$_.Name -like "Microsoft.WindowsNotepad*"
        })
        foreach ($pkg in @($appxPackages)) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            }
            catch {
                try {
                    Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                }
                catch {
                    Write-Warning ("Remove-AppxPackage failed for {0}: {1}" -f $pkg.PackageFullName, $_.Exception.Message)
                }
            }
        }
    }

    if (Get-Command Get-AppxProvisionedPackage -ErrorAction SilentlyContinue) {
        $provisioned = @(Get-AppxProvisionedPackage -Online | Where-Object {
            [string]$_.DisplayName -like "Microsoft.WindowsNotepad*"
        })
        foreach ($prov in @($provisioned)) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Warning ("Remove-AppxProvisionedPackage failed for {0}: {1}" -f $prov.PackageName, $_.Exception.Message)
            }
        }
    }

    & dism.exe /online /Remove-Capability /CapabilityName:Microsoft.Windows.Notepad~~~~0.0.1.0 /NoRestart | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "DISM capability removal for Microsoft.Windows.Notepad was not completed."
    }

    if (-not (Test-Path -LiteralPath $notepadPath)) {
        throw ("Legacy notepad executable was not found at '{0}'." -f $notepadPath)
    }
}

Invoke-Tweak -Name "notepad-common-text-associations" -Action {
    $className = "CoVmTextFile"
    Invoke-RegAdd -Path ("HKLM\SOFTWARE\Classes\" + $className) -Name "" -Type "REG_SZ" -Value "Co VM Text File"
    Invoke-RegAdd -Path ("HKLM\SOFTWARE\Classes\" + $className + "\shell\open\command") -Name "" -Type "REG_SZ" -Value ("`"" + $notepadPath + "`" `"%1`"")
    & cmd.exe /d /c ("ftype {0}=`"{1}`" `"%1`"" -f $className, $notepadPath) | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "ftype command for CoVmTextFile failed."
    }

    foreach ($ext in @($textExtensions)) {
        Invoke-RegAdd -Path ("HKLM\SOFTWARE\Classes\" + $ext) -Name "" -Type "REG_SZ" -Value $className
        & cmd.exe /d /c ("assoc {0}={1}" -f $ext, $className) | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning ("assoc command failed for extension '{0}'." -f $ext)
        }
    }
}

$targetHives = @()
try {
    $targetHives = Resolve-TargetHives
    foreach ($targetHive in @($targetHives)) {
        $hiveNative = [string]$targetHive.HiveNative
        $label = [string]$targetHive.Label
        Apply-ExplorerAndUxToUserHive -HiveNative $hiveNative -Label $label

        Invoke-Tweak -Name ("text-association-userchoice-reset-{0}" -f $label) -Action {
            foreach ($ext in @($textExtensions)) {
                $userChoicePath = "{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\{1}\UserChoice" -f $hiveNative, $ext
                Invoke-RegDelete -Path $userChoicePath
                Invoke-RegAdd -Path ("{0}\Software\Classes\{1}" -f $hiveNative, $ext) -Name "" -Type "REG_SZ" -Value "CoVmTextFile"
            }
        }
    }
}
finally {
    foreach ($loadedHive in @($loadedHives)) {
        $safeUnload = ('reg unload "{0}" >nul 2>&1' -f $loadedHive)
        & cmd.exe /d /c $safeUnload | Out-Null
    }
}

if ($tweakWarnings.Count -gt 0) {
    Write-Warning ("windows-ux-performance-tuning completed with {0} warning(s)." -f $tweakWarnings.Count)
    foreach ($warnEntry in @($tweakWarnings)) {
        Write-Warning ("- " + $warnEntry)
    }
}
else {
    Write-Host "windows-ux-performance-tuning completed with no warnings."
}

Write-Host "windows-ux-tuning-ready"
'@
        },
        [pscustomobject]@{
            Name = "15-windows-advanced-system-settings"
            Script = @'
$ErrorActionPreference = "Stop"

function Invoke-AdvancedWarn {
    param(
        [string]$Label,
        [scriptblock]$Action
    )

    try {
        & $Action
        Write-Host ("advanced-step-ok: {0}" -f $Label)
    }
    catch {
        Write-Warning ("advanced-step-failed: {0} => {1}" -f $Label, $_.Exception.Message)
    }
}

function Invoke-RegCmdWithAllowedExitCodes {
    param(
        [string]$CommandText,
        [int[]]$AllowedExitCodes = @(0)
    )

    if ([string]::IsNullOrWhiteSpace([string]$CommandText)) {
        throw "Registry command text is empty."
    }

    & cmd.exe /d /c $CommandText | Out-Null
    if ($AllowedExitCodes -notcontains [int]$LASTEXITCODE) {
        throw ("Registry command failed with exit code {0}: {1}" -f [int]$LASTEXITCODE, [string]$CommandText)
    }
}

function Set-DesktopIconSelection {
    param(
        [string]$HiveRoot
    )

    foreach ($viewKey in @("NewStartPanel", "ClassicStartMenu")) {
        $path = "{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\{1}" -f $HiveRoot, $viewKey
        $pathEscaped = ($path -replace '"', '\"')
        Invoke-RegCmdWithAllowedExitCodes -CommandText ("reg add `"" + $pathEscaped + "`" /v `"{59031a47-3f72-44a7-89c5-5595fe6b30ee}`" /t REG_DWORD /d 0 /f >nul 2>&1") # User Files
        Invoke-RegCmdWithAllowedExitCodes -CommandText ("reg add `"" + $pathEscaped + "`" /v `"{20D04FE0-3AEA-1069-A2D8-08002B30309D}`" /t REG_DWORD /d 0 /f >nul 2>&1") # This PC
        Invoke-RegCmdWithAllowedExitCodes -CommandText ("reg add `"" + $pathEscaped + "`" /v `"{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}`" /t REG_DWORD /d 0 /f >nul 2>&1") # Control Panel
        Invoke-RegCmdWithAllowedExitCodes -CommandText ("reg add `"" + $pathEscaped + "`" /v `"{645FF040-5081-101B-9F08-00AA002F954E}`" /t REG_DWORD /d 1 /f >nul 2>&1") # Recycle Bin hidden
    }
}

function Set-ClassicProfileVisualSettings {
    param(
        [string]$HiveRoot
    )

    Invoke-RegCmdWithAllowedExitCodes -CommandText ('reg delete "{0}\Control Panel\Desktop" /v Wallpaper /f >nul 2>&1' -f ($HiveRoot -replace '"', '\"')) -AllowedExitCodes @(0,1,2)
    Invoke-RegCmdWithAllowedExitCodes -CommandText ('reg add "{0}\Control Panel\Colors" /v Background /t REG_SZ /d "0 0 0" /f >nul 2>&1' -f ($HiveRoot -replace '"', '\"'))
    Invoke-RegCmdWithAllowedExitCodes -CommandText ('reg add "{0}\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v EnableTransparency /t REG_DWORD /d 0 /f >nul 2>&1' -f ($HiveRoot -replace '"', '\"'))
    Invoke-RegCmdWithAllowedExitCodes -CommandText ('reg add "{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ListviewAlphaSelect /t REG_DWORD /d 0 /f >nul 2>&1' -f ($HiveRoot -replace '"', '\"'))
    Invoke-RegCmdWithAllowedExitCodes -CommandText ('reg add "{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarAnimations /t REG_DWORD /d 0 /f >nul 2>&1' -f ($HiveRoot -replace '"', '\"'))
}

function Resolve-AdvancedTargetHives {
    # In non-interactive SSH sessions, loading other users' NTUSER.DAT can block on file locks.
    # Keep this task deterministic by applying only to the current user hive.
    return [pscustomobject]@{
        Targets = @("HKCU")
        Loaded = @()
    }
}

Invoke-AdvancedWarn -Label "desktop-icons-and-classic-ui-for-target-hives" -Action {
    $hiveState = Resolve-AdvancedTargetHives
    try {
        foreach ($hiveRoot in @($hiveState.Targets)) {
            Set-DesktopIconSelection -HiveRoot $hiveRoot
            Set-ClassicProfileVisualSettings -HiveRoot $hiveRoot
        }
    }
    finally {
        foreach ($loadedNative in @($hiveState.Loaded)) {
            & reg.exe unload $loadedNative | Out-Null
        }
    }
}

Invoke-AdvancedWarn -Label "visual-effects-best-performance" -Action {
    & reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v VisualFXSetting /t REG_DWORD /d 2 /f | Out-Null
}

Invoke-AdvancedWarn -Label "processor-background-services" -Action {
    & reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation /t REG_DWORD /d 24 /f | Out-Null
}

Invoke-AdvancedWarn -Label "custom-pagefile-800-8192" -Action {
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($computerSystem.AutomaticManagedPagefile) {
        Set-CimInstance -InputObject $computerSystem -Property @{ AutomaticManagedPagefile = $false } | Out-Null
    }

    $existingPageFiles = @(Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue)
    foreach ($existingPageFile in @($existingPageFiles)) {
        Remove-CimInstance -InputObject $existingPageFile -ErrorAction SilentlyContinue
    }

    try {
        New-CimInstance -ClassName Win32_PageFileSetting -Property @{
            Name = "C:\\pagefile.sys"
            InitialSize = [uint32]800
            MaximumSize = [uint32]8192
        } | Out-Null
    }
    catch {
        Invoke-RegCmdWithAllowedExitCodes -CommandText 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v PagingFiles /t REG_MULTI_SZ /d "C:\pagefile.sys 800 8192" /f >nul 2>&1'
        Invoke-RegCmdWithAllowedExitCodes -CommandText 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v ExistingPageFiles /t REG_MULTI_SZ /d "\??\C:\pagefile.sys" /f >nul 2>&1'
        Invoke-RegCmdWithAllowedExitCodes -CommandText 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v TempPageFile /t REG_DWORD /d 0 /f >nul 2>&1'
    }
}

Invoke-AdvancedWarn -Label "boot-timeout-and-dump-off" -Action {
    & bcdedit /timeout 0 | Out-Null
    & reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v CrashDumpEnabled /t REG_DWORD /d 0 /f | Out-Null
    & reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v AlwaysKeepMemoryDump /t REG_DWORD /d 0 /f | Out-Null
    & reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v LogEvent /t REG_DWORD /d 0 /f | Out-Null
    & reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v SendAlert /t REG_DWORD /d 0 /f | Out-Null
}

Invoke-AdvancedWarn -Label "dep-always-off" -Action {
    & bcdedit /set "{current}" nx AlwaysOff | Out-Null
}

Invoke-AdvancedWarn -Label "refresh-user-visual-parameters" -Action {
    $rundllPath = Join-Path $env:WINDIR "System32\rundll32.exe"
    if (-not (Test-Path -LiteralPath $rundllPath)) {
        throw ("rundll32.exe was not found at '{0}'." -f $rundllPath)
    }

    $proc = Start-Process `
        -FilePath $rundllPath `
        -ArgumentList "user32.dll,UpdatePerUserSystemParameters" `
        -WindowStyle Hidden `
        -PassThru
    if (-not $proc.WaitForExit(15000)) {
        try { $proc.Kill() } catch { }
        Write-Warning "UpdatePerUserSystemParameters timed out and was terminated."
    }
}

Write-Host "windows-advanced-system-settings-completed"
'@
        },
        [pscustomobject]@{
            Name = "16-local-service-disable-conservative"
            Script = @'
$ErrorActionPreference = "Stop"

$protectedServices = @(
    "TermService","sshd","ssh-agent","EventLog","RpcSs","Winmgmt","W32Time","Dnscache","LanmanWorkstation",
    "LanmanServer","NlaSvc","Dhcp","BFE","MpsSvc","wuauserv","BITS","TrustedInstaller","vmcompute","LxssManager","com.docker.service"
)
$disableCandidates = @(
    "DiagTrack","dmwappushservice","MapsBroker","RetailDemo","Fax","XblAuthManager","XblGameSave","XboxGipSvc","WSearch","WerSvc"
)

function Disable-ServiceIfSafe {
    param(
        [string]$ServiceName
    )

    if ($protectedServices -contains $ServiceName) {
        Write-Host ("service-skip-protected: {0}" -f $ServiceName)
        return
    }

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Host ("service-not-found: {0}" -f $ServiceName)
        return
    }

    try {
        $dependentServices = @($service.DependentServices | Where-Object { $_.Status -eq "Running" })
        if ($dependentServices.Count -gt 0) {
            Write-Warning ("service-skip-dependent-running: {0}" -f $ServiceName)
            return
        }

        if ($service.Status -eq "Running") {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        }
        Set-Service -Name $ServiceName -StartupType Disabled -ErrorAction Stop
        Write-Host ("service-disabled: {0}" -f $ServiceName)
    }
    catch {
        Write-Warning ("service-disable-failed: {0} => {1}" -f $ServiceName, $_.Exception.Message)
    }
}

foreach ($candidate in @($disableCandidates)) {
    Disable-ServiceIfSafe -ServiceName $candidate
}

Write-Host "local-service-disable-conservative-completed"
'@
        },
        [pscustomobject]@{
            Name = "17-health-snapshot"
            Script = @'
$ErrorActionPreference = "Stop"
$sshdConfig = "C:\ProgramData\ssh\sshd_config"
Write-Host "Version Info:"
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    [pscustomobject]@{
        WindowsProductName = [string]$os.Caption
        WindowsVersion = [string]$os.Version
        OsBuildNumber = [string]$os.BuildNumber
    } | Format-List
}
catch {
    Write-Warning ("Version info collection failed: {0}" -f $_.Exception.Message)
}
Write-Host "APP PATH CHECKS:"
foreach ($commandName in @("choco", "git", "node", "python", "py", "pwsh", "gh", "ffmpeg", "7z", "az", "docker", "wsl", "ollama")) {
    $cmd = Get-Command $commandName -ErrorAction SilentlyContinue
    if ($cmd) { Write-Host "$commandName => $($cmd.Source)" } else { Write-Host "$commandName => not-found" }
}
Write-Host "OPEN Ports:"
Get-NetTCPConnection -LocalPort 3389,__SSH_PORT__ -State Listen | Select-Object LocalAddress,LocalPort,OwningProcess | Format-Table -AutoSize
Write-Host "Firewall STATUS:"
Get-NetFirewallProfile | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction | Format-Table -AutoSize
Write-Host "RDP STATUS:"
Get-Service TermService | Select-Object Name,Status,StartType | Format-List
Write-Host "SSHD STATUS:"
Get-Service sshd | Select-Object Name,Status,StartType | Format-List
Write-Host "SSHD CONFIG:"
Get-Content $sshdConfig | Select-String -Pattern "^(Port|PasswordAuthentication|PubkeyAuthentication|PermitEmptyPasswords|AllowTcpForwarding|GatewayPorts)" | ForEach-Object { $_.Line }
Write-Host "POWER STATUS:"
powercfg /getactivescheme
Write-Host "DOCKER STATUS:"
if (Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue) {
    Get-Service -Name "com.docker.service" | Select-Object Name,Status,StartType | Format-List
}
else {
    Write-Host "com.docker.service => not-found"
}
if (Get-Command docker -ErrorAction SilentlyContinue) {
    docker --version
    docker version
}
else {
    Write-Host "docker command not found"
}
Write-Host "WSL STATUS:"
if (Get-Command wsl -ErrorAction SilentlyContinue) {
    wsl --version
}
else {
    Write-Host "wsl command not found"
}
Write-Host "OLLAMA STATUS:"
if (Get-Command ollama -ErrorAction SilentlyContinue) {
    ollama --version
}
else {
    Write-Host "ollama command not found"
}
Write-Host "CHROME SHORTCUT STATUS:"
$chromeShortcutCandidates = @(
    "C:\Users\Public\Desktop\Google Chrome.lnk",
    "C:\Users\__VM_USER__\Desktop\Google Chrome.lnk",
    "C:\Users\__ASSISTANT_USER__\Desktop\Google Chrome.lnk"
)
$wsh = New-Object -ComObject WScript.Shell
foreach ($shortcutPath in @($chromeShortcutCandidates)) {
    if (-not (Test-Path -LiteralPath $shortcutPath)) {
        Write-Host ("missing-shortcut => {0}" -f $shortcutPath)
        continue
    }
    $shortcut = $wsh.CreateShortcut($shortcutPath)
    Write-Host ("shortcut => {0}" -f $shortcutPath)
    Write-Host (" target => {0}" -f [string]$shortcut.TargetPath)
    Write-Host (" args => {0}" -f [string]$shortcut.Arguments)
}
Write-Host "NOTEPAD STATUS:"
if (Test-Path "$env:WINDIR\System32\notepad.exe") { Write-Host "legacy-notepad-exe-found" } else { Write-Host "legacy-notepad-exe-not-found" }
if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
    $notepadPkgs = @(Get-AppxPackage -AllUsers | Where-Object { [string]$_.Name -like "Microsoft.WindowsNotepad*" })
    Write-Host ("modern-notepad-package-count=" + @($notepadPkgs).Count)
}
'@
        }
    )
}

function Get-CoVmGuestTaskReplacementMap {
    param(
        [ValidateSet("linux", "windows")]
        [string]$Platform,
        [hashtable]$Context
    )

    $map = @{
        VM_USER = [string]$Context.VmUser
        VM_PASS = [string]$Context.VmPass
        ASSISTANT_USER = [string]$Context.VmAssistantUser
        ASSISTANT_PASS = [string]$Context.VmAssistantPass
        SSH_PORT = [string]$Context.SshPort
        SERVER_NAME = [string]$Context.ServerName
    }

    if ($Platform -eq "linux") {
        $tcpPorts = @($Context.TcpPorts)
        $map["TCP_PORTS_BASH"] = ($tcpPorts -join " ")
        $map["TCP_PORTS_REGEX"] = (($tcpPorts | ForEach-Object { [regex]::Escape([string]$_) }) -join "|")
        return $map
    }

    $map["TCP_PORTS_PS_ARRAY"] = ((@($Context.TcpPorts)) -join ",")
    return $map
}

function Resolve-CoVmGuestTaskBlocks {
    param(
        [ValidateSet("linux", "windows")]
        [string]$Platform,
        [hashtable]$Context,
        [string]$VmInitScriptFile = ""
    )

    $templates = Get-CoVmGuestTaskTemplates -Platform $Platform -VmInitScriptFile $VmInitScriptFile
    if ($Platform -eq "windows") {
        $excludedInitTasks = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @("00-init-script", "01-ensure-local-admin-user", "02-openssh-install-service", "03-sshd-config-port", "04-rdp-firewall")) {
            [void]$excludedInitTasks.Add([string]$name)
        }
        $templates = @($templates | Where-Object { -not $excludedInitTasks.Contains([string]$_.Name) })
    }
    $replacements = Get-CoVmGuestTaskReplacementMap -Platform $Platform -Context $Context
    return (Apply-CoVmTaskBlockReplacements -TaskBlocks $templates -Replacements $replacements)
}

function Get-CoVmWindowsUpdateScriptFromTasks {
    param(
        [object[]]$TaskBlocks
    )

    if (-not $TaskBlocks -or $TaskBlocks.Count -eq 0) {
        throw "Windows VM update script build failed: no task blocks were provided."
    }

    $taskRows = New-Object System.Text.StringBuilder
    $hashInput = New-Object System.Text.StringBuilder
    foreach ($taskBlock in $TaskBlocks) {
        $taskName = [string]$taskBlock.Name
        $taskScript = [string]$taskBlock.Script
        $taskNameSafe = $taskName.Replace("'", "''")
        $taskBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($taskScript))
        [void]$taskRows.AppendLine(('$taskCatalog += [pscustomobject]@{{ Name = ''{0}''; ScriptBase64 = ''{1}'' }}' -f $taskNameSafe, $taskBase64))
        [void]$hashInput.AppendLine(($taskName + "|" + $taskScript))
    }

    $hashBytes = [System.Text.Encoding]::UTF8.GetBytes($hashInput.ToString())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($hashBytes)
    }
    finally {
        $sha.Dispose()
    }
    $catalogHash = [BitConverter]::ToString($hash).Replace("-", "").ToLowerInvariant()

    $template = @'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "Update phase started."

$stateDir = "C:\ProgramData\az-vm"
$statePath = Join-Path $stateDir "step8-state.json"
$catalogHash = "__TASK_CATALOG_HASH__"
$taskCatalog = @()
__TASK_ROWS__

function Convert-ToTaskSafeDetail {
    param(
        [string]$Detail
    )

    if ([string]::IsNullOrWhiteSpace($Detail)) {
        return ""
    }

    $text = $Detail -replace "[\r\n]+", " "
    $text = $text -replace ";", ","
    return $text.Trim()
}

function New-Step8State {
    param(
        [string]$CatalogHash,
        [int]$TaskCount
    )

    return @{
        CatalogHash = $CatalogHash
        TotalTaskCount = $TaskCount
        LastCompletedTaskIndex = -1
        LastTaskName = ""
        RebootCount = 0
        Completed = $false
        RebootRequired = $false
        SuccessCount = 0
        WarningCount = 0
        ErrorCount = 0
        TaskStatus = @{}
    }
}

function Load-Step8State {
    param(
        [string]$StatePath,
        [string]$CatalogHash,
        [int]$TaskCount
    )

    $state = New-Step8State -CatalogHash $CatalogHash -TaskCount $TaskCount
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return $state
    }

    try {
        $raw = Get-Content -Path $StatePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $state
        }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $state
    }

    if ($parsed.PSObject.Properties["CatalogHash"]) { $state.CatalogHash = [string]$parsed.CatalogHash }
    if ($parsed.PSObject.Properties["TotalTaskCount"]) { $state.TotalTaskCount = [int]$parsed.TotalTaskCount }
    if ($parsed.PSObject.Properties["LastCompletedTaskIndex"]) { $state.LastCompletedTaskIndex = [int]$parsed.LastCompletedTaskIndex }
    if ($parsed.PSObject.Properties["LastTaskName"]) { $state.LastTaskName = [string]$parsed.LastTaskName }
    if ($parsed.PSObject.Properties["RebootCount"]) { $state.RebootCount = [int]$parsed.RebootCount }
    if ($parsed.PSObject.Properties["Completed"]) { $state.Completed = [bool]$parsed.Completed }
    if ($parsed.PSObject.Properties["RebootRequired"]) { $state.RebootRequired = [bool]$parsed.RebootRequired }
    if ($parsed.PSObject.Properties["SuccessCount"]) { $state.SuccessCount = [int]$parsed.SuccessCount }
    if ($parsed.PSObject.Properties["WarningCount"]) { $state.WarningCount = [int]$parsed.WarningCount }
    if ($parsed.PSObject.Properties["ErrorCount"]) { $state.ErrorCount = [int]$parsed.ErrorCount }

    if ($parsed.PSObject.Properties["TaskStatus"] -and $parsed.TaskStatus) {
        foreach ($entry in $parsed.TaskStatus.PSObject.Properties) {
            $statusValue = ""
            $detailValue = ""
            if ($entry.Value -and $entry.Value.PSObject.Properties["Status"]) { $statusValue = [string]$entry.Value.Status }
            if ($entry.Value -and $entry.Value.PSObject.Properties["Detail"]) { $detailValue = [string]$entry.Value.Detail }
            $state.TaskStatus[[string]$entry.Name] = @{
                Status = $statusValue
                Detail = $detailValue
            }
        }
    }

    return $state
}

function Save-Step8State {
    param(
        [string]$StatePath,
        [hashtable]$State
    )

    $statusOut = [ordered]@{}
    foreach ($taskName in @($State.TaskStatus.Keys)) {
        $entry = $State.TaskStatus[$taskName]
        $statusOut[$taskName] = [ordered]@{
            Status = [string]$entry.Status
            Detail = [string]$entry.Detail
        }
    }

    $payload = [ordered]@{
        CatalogHash = [string]$State.CatalogHash
        TotalTaskCount = [int]$State.TotalTaskCount
        LastCompletedTaskIndex = [int]$State.LastCompletedTaskIndex
        LastTaskName = [string]$State.LastTaskName
        RebootCount = [int]$State.RebootCount
        Completed = [bool]$State.Completed
        RebootRequired = [bool]$State.RebootRequired
        SuccessCount = [int]$State.SuccessCount
        WarningCount = [int]$State.WarningCount
        ErrorCount = [int]$State.ErrorCount
        TaskStatus = $statusOut
    }

    ($payload | ConvertTo-Json -Depth 20) | Set-Content -Path $StatePath -Encoding UTF8
}

function Set-Step8TaskStatus {
    param(
        [hashtable]$State,
        [string]$TaskName,
        [string]$NewStatus,
        [string]$Detail = ""
    )

    if (-not $State.TaskStatus.ContainsKey($TaskName)) {
        $State.TaskStatus[$TaskName] = @{ Status = ""; Detail = "" }
    }

    $oldStatus = [string]$State.TaskStatus[$TaskName].Status
    switch ($oldStatus) {
        "success" { $State.SuccessCount = [Math]::Max(0, [int]$State.SuccessCount - 1) }
        "warning" { $State.WarningCount = [Math]::Max(0, [int]$State.WarningCount - 1) }
        "error" { $State.ErrorCount = [Math]::Max(0, [int]$State.ErrorCount - 1) }
    }

    switch ($NewStatus) {
        "success" { $State.SuccessCount = [int]$State.SuccessCount + 1 }
        "warning" { $State.WarningCount = [int]$State.WarningCount + 1 }
        "error" { $State.ErrorCount = [int]$State.ErrorCount + 1 }
        default { }
    }

    $safeDetail = Convert-ToTaskSafeDetail -Detail $Detail
    $State.TaskStatus[$TaskName] = @{
        Status = [string]$NewStatus
        Detail = [string]$safeDetail
    }

    Write-Host ("TASK_STATUS:{0}:{1}" -f $TaskName, $NewStatus)
    if (-not [string]::IsNullOrWhiteSpace($safeDetail)) {
        Write-Host ("TASK_DETAIL:{0}:{1}" -f $TaskName, $safeDetail)
    }
}

function Test-Step8RebootPending {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            return $true
        }
    }

    try {
        $pending = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue
        if ($pending -and $pending.PendingFileRenameOperations) {
            return $true
        }
    }
    catch { }

    return $false
}

if (-not (Test-Path -LiteralPath $stateDir)) {
    New-Item -Path $stateDir -ItemType Directory -Force | Out-Null
}

$state = Load-Step8State -StatePath $statePath -CatalogHash $catalogHash -TaskCount $taskCatalog.Count
if ($state.CatalogHash -ne $catalogHash -or [int]$state.TotalTaskCount -ne $taskCatalog.Count) {
    $state = New-Step8State -CatalogHash $catalogHash -TaskCount $taskCatalog.Count
}
if ($state.Completed -and -not $state.RebootRequired) {
    $state = New-Step8State -CatalogHash $catalogHash -TaskCount $taskCatalog.Count
}

$state.CatalogHash = $catalogHash
$state.TotalTaskCount = $taskCatalog.Count
if ($state.LastCompletedTaskIndex -gt ($taskCatalog.Count - 1)) {
    $state.LastCompletedTaskIndex = $taskCatalog.Count - 1
}
if ($state.LastCompletedTaskIndex -lt -1) {
    $state.LastCompletedTaskIndex = -1
}

if ($taskCatalog.Count -eq 0) {
    Write-Host "STEP8_SUMMARY:success=0;warning=0;error=0;reboot=0"
    Write-Host "Update phase completed."
    return
}

$startIndex = [int]$state.LastCompletedTaskIndex + 1

for ($taskIndex = $startIndex; $taskIndex -lt $taskCatalog.Count; $taskIndex++) {
    $task = $taskCatalog[$taskIndex]
    $taskName = [string]$task.Name
    Write-Host ("TASK started: {0}" -f $taskName)
    $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $decodedScript = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String([string]$task.ScriptBase64))
        Invoke-Expression $decodedScript
        if ($taskWatch.IsRunning) { $taskWatch.Stop() }
        Set-Step8TaskStatus -State $state -TaskName $taskName -NewStatus "success"
        Write-Host ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
        Write-Host "TASK result: success"
    }
    catch {
        if ($taskWatch.IsRunning) { $taskWatch.Stop() }
        $detail = if ($_.Exception) { $_.Exception.Message } else { [string]$_ }
        Set-Step8TaskStatus -State $state -TaskName $taskName -NewStatus "warning" -Detail $detail
        Write-Warning ("TASK warning: {0} => {1}" -f $taskName, $detail)
        Write-Host ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
        Write-Host "TASK result: warning"
    }

    $state.LastCompletedTaskIndex = $taskIndex
    $state.LastTaskName = $taskName
    $state.Completed = $false
    $state.RebootRequired = $false
    Save-Step8State -StatePath $statePath -State $state

    if (Test-Step8RebootPending) {
        $state.RebootRequired = $true
        $state.RebootCount = [int]$state.RebootCount + 1
        Save-Step8State -StatePath $statePath -State $state
        Write-Host ("TASK_REBOOT_REQUIRED:{0}:true" -f $taskName)
        Write-Host ("CO_VM_REBOOT_REQUIRED:task={0};index={1};rebootCount={2}" -f $taskName, $taskIndex, $state.RebootCount)
        Write-Host ("STEP8_SUMMARY:success={0};warning={1};error={2};reboot={3}" -f $state.SuccessCount, $state.WarningCount, $state.ErrorCount, $state.RebootCount)
        return
    }
}

$state.Completed = $true
$state.RebootRequired = $false
Save-Step8State -StatePath $statePath -State $state

Write-Host ("STEP8_SUMMARY:success={0};warning={1};error={2};reboot={3}" -f $state.SuccessCount, $state.WarningCount, $state.ErrorCount, $state.RebootCount)
Write-Host "Update phase completed."
'@

    return $template.Replace("__TASK_CATALOG_HASH__", $catalogHash).Replace("__TASK_ROWS__", $taskRows.ToString().TrimEnd())
}

function Get-CoVmUpdateScriptContentFromTasks {
    param(
        [ValidateSet("linux", "windows")]
        [string]$Platform,
        [object[]]$TaskBlocks
    )

    if (-not $TaskBlocks -or $TaskBlocks.Count -eq 0) {
        throw "VM update script build failed: no task blocks were provided."
    }

    if ($Platform -eq "windows") {
        return (Get-CoVmWindowsUpdateScriptFromTasks -TaskBlocks $TaskBlocks)
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("#!/usr/bin/env bash")
    [void]$sb.AppendLine("set -euo pipefail")
    [void]$sb.AppendLine("exec 2>&1")
    [void]$sb.AppendLine('echo "Update phase started."')
    [void]$sb.AppendLine("")

    foreach ($taskBlock in $TaskBlocks) {
        $taskName = [string]$taskBlock.Name
        $taskScript = [string]$taskBlock.Script
        [void]$sb.AppendLine(("# Task: {0}" -f $taskName))
        [void]$sb.AppendLine($taskScript.Trim())
        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine('echo "Update phase completed."')
    return $sb.ToString()
}

function Get-CoVmWriteSettingsForPlatform {
    param(
        [ValidateSet("linux", "windows")]
        [string]$Platform
    )

    if ($Platform -eq "linux") {
        return @{
            Encoding = "utf8NoBom"
            LineEnding = "lf"
        }
    }

    return @{
        Encoding = "utf8NoBom"
        LineEnding = "crlf"
    }
}

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

function Get-CoVmWindowsPostRebootProbeScript {
    param(
        [string]$ServerName = "",
        [string]$VmUser = "",
        [string]$AssistantUser = ""
    )

    @'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Write-Host "post-reboot-probe-started"
Write-Host ("server-name=__SERVER_NAME__")
Write-Host ("manager-user=__VM_USER__")
Write-Host ("assistant-user=__ASSISTANT_USER__")

if (Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue) {
    Set-Service -Name "com.docker.service" -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
}
if (Get-Service -Name "LxssManager" -ErrorAction SilentlyContinue) {
    Set-Service -Name "LxssManager" -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name "LxssManager" -ErrorAction SilentlyContinue
}

$dockerDesktopExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
if (Test-Path -LiteralPath $dockerDesktopExe) {
    if (-not (Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $dockerDesktopExe -ArgumentList "--minimized" -WindowStyle Minimized -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 10
    }
}

Write-Host "service-status:"
foreach ($serviceName in @("TermService","sshd","com.docker.service","LxssManager")) {
    $serviceObj = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($serviceObj) {
        Write-Host ("{0} => {1}/{2}" -f $serviceName, $serviceObj.Status, $serviceObj.StartType)
    }
    else {
        Write-Host ("{0} => not-found" -f $serviceName)
    }
}

if (Get-Command docker -ErrorAction SilentlyContinue) {
    Write-Host "docker-client:"
    docker --version
    Write-Host "docker-daemon:"
    docker version
}
else {
    $dockerCliPath = "C:\Program Files\Docker\Docker\resources\bin"
    if (Test-Path -LiteralPath $dockerCliPath) {
        $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($machinePath -notmatch [regex]::Escape($dockerCliPath)) {
            [Environment]::SetEnvironmentVariable("Path", ($machinePath.TrimEnd(';') + ";" + $dockerCliPath), "Machine")
            $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
        }
    }

    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Write-Host "docker-client:"
        docker --version
        Write-Host "docker-daemon:"
        docker version
    }
    else {
        Write-Warning "docker command not found in post-reboot probe."
    }
}

if (Get-Command wsl -ErrorAction SilentlyContinue) {
    Write-Host "wsl-status:"
    $wslStatusOutput = @(& cmd.exe /d /c "wsl --status 2>&1")
    $wslStatusCode = $LASTEXITCODE
    $wslStatusText = (@($wslStatusOutput) | ForEach-Object { [string]$_ }) -join "`n"
    if (-not [string]::IsNullOrWhiteSpace($wslStatusText)) {
        Write-Host $wslStatusText.Trim()
    }

    if ($wslStatusCode -ne 0 -or $wslStatusText -match '(?i)(not installed|wsl\.exe --install|windows subsystem for linux is not installed)') {
        Write-Warning "WSL is not installed yet."
    }
    else {
        Write-Host "wsl-version:"
        & cmd.exe /d /c "wsl --version 2>&1"
    }
}
else {
    Write-Warning "wsl command not found in post-reboot probe."
}

if (Get-Command ollama -ErrorAction SilentlyContinue) {
    Write-Host "ollama-version:"
    ollama --version
}
else {
    Write-Warning "ollama command not found in post-reboot probe."
}

Write-Host "post-reboot-probe-completed"
'@.Replace("__SERVER_NAME__", [string]$ServerName).Replace("__VM_USER__", [string]$VmUser).Replace("__ASSISTANT_USER__", [string]$AssistantUser)
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
            az network nsg rule create `
                -g $Context.ResourceGroup `
                --nsg-name $Context.NSG `
                --name "$($Context.NsgRule)" `
                --priority $priority `
                --direction Inbound `
                --protocol Tcp `
                --access Allow `
                --destination-port-ranges $ports `
                --source-address-prefixes "*" `
                --source-port-ranges "*" `
                -o table
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
        return
    }

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
        $summary = "A task failed in substep mode."
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
        [switch]$SubstepMode,
        [switch]$SshMode,
        [bool]$IncludeStep8LegacyFlags = $true,
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
    if ($IncludeStep8LegacyFlags) {
        $runtimeFields["SubstepMode"] = [bool]$SubstepMode
        $runtimeFields["SshMode"] = [bool]$SshMode
    }
    $runtimeLabels = @{
        AutoMode = "Auto mode"
        UpdateMode = "Update mode"
        RenewMode = "destructive rebuild mode"
        SubstepMode = "Substep mode"
        SshMode = "SSH mode"
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
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            $messages += $message.Trim()
        }

        if ($code -match '(?i)/failed$') {
            $hasError = $true
        }
        elseif ($code -match '(?i)StdErr' -and -not [string]::IsNullOrWhiteSpace($message)) {
            if (Test-CoVmBenignRunCommandStdErr -Message $message) {
                Write-Warning ("Ignoring benign run-command stderr line for task '{0}': {1}" -f $TaskName, $message.Trim())
            }
            elseif ($message -match '(?i)(terminatingerror|exception|failed|not recognized|cannot find|categoryinfo)') {
                $hasError = $true
            }
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

function Invoke-VmRunCommandScriptFile {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$CommandId,
        [string]$ScriptFilePath,
        [string]$ModeLabel
    )

    if ([string]::IsNullOrWhiteSpace($ScriptFilePath)) {
        throw "VM run-command script file path is empty."
    }
    if (-not (Test-Path -LiteralPath $ScriptFilePath)) {
        throw "VM run-command script file was not found: $ScriptFilePath"
    }

    try {
        $invokeLabel = "az vm run-command invoke (script-file)"
        $json = Invoke-TrackedAction -Label $invokeLabel -Action {
            $result = az vm run-command invoke `
                --resource-group $ResourceGroup `
                --name $VmName `
                --command-id $CommandId `
                --scripts "@$ScriptFilePath" `
                -o json
            Assert-LastExitCode "az vm run-command invoke (script-file)"
            $result
        }

        $message = Get-CoRunCommandResultMessage -TaskName "script-file" -RawJson $json -ModeLabel $ModeLabel
        Write-Host "TASK batch run-command completed."
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            Write-Host $message
        }

        $marker = Parse-CoVmStep8Markers -MessageText $message
        if ($marker.HasSummaryLine) {
            Write-Host $marker.SummaryLine -ForegroundColor DarkGray
        }

        return [pscustomobject]@{
            Message = $message
            RebootRequired = ([bool]$marker.RebootRequired -or (Test-CoVmOutputIndicatesRebootRequired -MessageText $message))
            SuccessCount = [int]$marker.SuccessCount
            WarningCount = [int]$marker.WarningCount
            ErrorCount = [int]$marker.ErrorCount
            RebootCount = [int]$marker.RebootCount
        }
    }
    catch {
        throw "VM task batch execution failed in $ModeLabel flow: $($_.Exception.Message)"
    }
}

function Invoke-VmRunCommandBlocks {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$CommandId,
        [object[]]$TaskBlocks,
        [switch]$SubstepMode,
        [int]$StartTaskIndex = 0,
        [switch]$SoftFail,
        [ValidateSet("bash","powershell")]
        [string]$CombinedShell = "powershell"
    )

    if (-not $TaskBlocks -or $TaskBlocks.Count -eq 0) {
        throw "VM run-command task list is empty."
    }
    if ($StartTaskIndex -lt 0) {
        $StartTaskIndex = 0
    }
    if ($StartTaskIndex -ge $TaskBlocks.Count) {
        return [pscustomobject]@{
            SuccessCount = 0
            WarningCount = 0
            ErrorCount = 0
            RebootRequired = $false
            NextTaskIndex = [int]$TaskBlocks.Count
        }
    }

    if ($SubstepMode) {
        Write-Host "Substep mode is enabled: Step 8 tasks are executed one-by-one."
        $successCount = 0
        $warningCount = 0
        $errorCount = 0
        $nextTaskIndex = [int]$StartTaskIndex
        for ($taskIndex = $StartTaskIndex; $taskIndex -lt $TaskBlocks.Count; $taskIndex++) {
            $taskBlock = $TaskBlocks[$taskIndex]
            $taskName = [string]$taskBlock.Name
            $taskScript = Resolve-CoRunCommandScriptText -ScriptText ([string]$taskBlock.Script)
            $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                Write-Host "TASK started: $taskName"
                $taskArgs = Get-CoRunCommandScriptArgs -ScriptText $taskScript -CommandId $CommandId
                $taskAzArgs = @(
                    "vm", "run-command", "invoke",
                    "--resource-group", $ResourceGroup,
                    "--name", $VmName,
                    "--command-id", $CommandId,
                    "--scripts"
                )
                $taskAzArgs += $taskArgs
                $taskAzArgs += @("-o", "json")
                $taskInvokeLabel = "az vm run-command invoke (task: $taskName)"
                $taskJson = Invoke-TrackedAction -Label $taskInvokeLabel -Action {
                    $invokeResult = az @taskAzArgs
                    Assert-LastExitCode "az vm run-command invoke ($taskName)"
                    $invokeResult
                }
                $taskMessage = Get-CoRunCommandResultMessage -TaskName $taskName -RawJson $taskJson -ModeLabel "substep-mode"
                $taskWatch.Stop()
                Write-Host ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
                Write-Host "TASK result: success"
                if (-not [string]::IsNullOrWhiteSpace($taskMessage)) {
                    Write-Host $taskMessage
                }
                $successCount++
                $nextTaskIndex = $taskIndex + 1
                if (Test-CoVmOutputIndicatesRebootRequired -MessageText $taskMessage) {
                    return [pscustomobject]@{
                        SuccessCount = $successCount
                        WarningCount = $warningCount
                        ErrorCount = $errorCount
                        RebootRequired = $true
                        NextTaskIndex = $nextTaskIndex
                    }
                }
            }
            catch {
                if ($taskWatch.IsRunning) { $taskWatch.Stop() }
                if ($SoftFail) {
                    $warningCount++
                    $nextTaskIndex = $taskIndex + 1
                    Write-Warning ("TASK warning: {0} => {1}" -f $taskName, $_.Exception.Message)
                    continue
                }

                Write-Host "TASK result: failure ($taskName)" -ForegroundColor Red
                throw "VM task '$taskName' failed: $($_.Exception.Message)"
            }
        }

        return [pscustomobject]@{
            SuccessCount = $successCount
            WarningCount = $warningCount
            ErrorCount = $errorCount
            RebootRequired = $false
            NextTaskIndex = $nextTaskIndex
        }
    }

    Write-Host "Substep mode is not enabled: Step 8 tasks will run in a single run-command call."

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

function Invoke-CoVmPostStep8RebootAndProbe {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$PostRebootProbeScript = "",
        [string]$PostRebootProbeCommandId = "RunPowerShellScript",
        [int]$PostRebootProbeMaxAttempts = 3,
        [int]$PostRebootProbeRetryDelaySeconds = 20
    )

    Invoke-TrackedAction -Label ("az vm restart -g {0} -n {1}" -f $ResourceGroup, $VmName) -Action {
        az vm restart -g $ResourceGroup -n $VmName --no-wait
        Assert-LastExitCode "az vm restart --no-wait"
    } | Out-Null

    Write-Host "Waiting for VM restart completion..."
    Invoke-TrackedAction -Label ("az vm wait -g {0} -n {1} --updated" -f $ResourceGroup, $VmName) -Action {
        az vm wait -g $ResourceGroup -n $VmName --updated
        Assert-LastExitCode "az vm wait --updated"
    } | Out-Null

    Write-Host "Checking VM power state after reboot..."
    $isRunning = Wait-CoVmVmRunningState -ResourceGroup $ResourceGroup -VmName $VmName -MaxAttempts 90 -DelaySeconds 10
    if (-not $isRunning) {
        throw "VM did not reach 'VM running' state after reboot in Step 8."
    }

    if ([string]::IsNullOrWhiteSpace($PostRebootProbeScript)) {
        return
    }

    if ($PostRebootProbeMaxAttempts -lt 1) { $PostRebootProbeMaxAttempts = 1 }
    if ($PostRebootProbeMaxAttempts -gt 3) { $PostRebootProbeMaxAttempts = 3 }
    if ($PostRebootProbeRetryDelaySeconds -lt 1) { $PostRebootProbeRetryDelaySeconds = 1 }

    for ($attempt = 1; $attempt -le $PostRebootProbeMaxAttempts; $attempt++) {
        try {
            $probeArgs = Get-CoRunCommandScriptArgs -ScriptText $PostRebootProbeScript -CommandId $PostRebootProbeCommandId
            $probeAzArgs = @(
                "vm", "run-command", "invoke",
                "--resource-group", $ResourceGroup,
                "--name", $VmName,
                "--command-id", $PostRebootProbeCommandId,
                "--scripts"
            )
            $probeAzArgs += $probeArgs
            $probeAzArgs += @("-o", "json")

            $label = "az vm run-command invoke (post-reboot probe attempt $attempt)"
            $probeJson = Invoke-TrackedAction -Label $label -Action {
                $probeResult = az @probeAzArgs
                Assert-LastExitCode "az vm run-command invoke (post-reboot probe)"
                $probeResult
            }

            $probeMessage = Get-CoRunCommandResultMessage -TaskName "post-reboot-probe" -RawJson $probeJson -ModeLabel "post-reboot-probe"
            Write-Host "Post-reboot probe completed."
            if (-not [string]::IsNullOrWhiteSpace($probeMessage)) {
                Write-Host $probeMessage
            }
            return
        }
        catch {
            if ($attempt -ge $PostRebootProbeMaxAttempts) {
                Write-Warning ("Post-reboot probe failed after {0} attempt(s): {1}" -f $attempt, $_.Exception.Message)
                return
            }

            Write-Host ("Post-reboot probe attempt {0} failed: {1}" -f $attempt, $_.Exception.Message) -ForegroundColor Yellow
            Start-Sleep -Seconds $PostRebootProbeRetryDelaySeconds
        }
    }
}

function Invoke-CoVmStep8RunCommand {
    param(
        [switch]$SubstepMode,
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$CommandId,
        [string]$ScriptFilePath,
        [object[]]$TaskBlocks,
        [ValidateSet("bash","powershell")]
        [string]$CombinedShell,
        [switch]$RebootAfterExecution,
        [string]$PostRebootProbeScript = "",
        [string]$PostRebootProbeCommandId = "RunPowerShellScript",
        [int]$PostRebootProbeMaxAttempts = 3,
        [int]$PostRebootProbeRetryDelaySeconds = 20,
        [int]$MaxReboots = 3,
        [ValidateSet("soft-warning","strict")]
        [string]$TaskFailurePolicy = "soft-warning"
    )

    if ($MaxReboots -lt 0) {
        $MaxReboots = 0
    }
    if ($MaxReboots -gt 3) {
        $MaxReboots = 3
    }

    $totalSuccess = 0
    $totalWarnings = 0
    $totalErrors = 0
    $rebootCount = 0
    $hadMidStepReboot = $false

    if (-not $SubstepMode) {
        Write-Host ("Substep mode is not enabled: Step 8 tasks will run from the VM update script file. Failure policy: {0}" -f $TaskFailurePolicy)
        while ($true) {
            $scriptFileResult = Invoke-VmRunCommandScriptFile `
                -ResourceGroup $ResourceGroup `
                -VmName $VmName `
                -CommandId $CommandId `
                -ScriptFilePath $ScriptFilePath `
                -ModeLabel "auto-mode update-script-file"

            $totalSuccess = [int]$scriptFileResult.SuccessCount
            $totalWarnings = [int]$scriptFileResult.WarningCount
            $totalErrors = [int]$scriptFileResult.ErrorCount

            if (-not $scriptFileResult.RebootRequired) {
                break
            }

            if ($rebootCount -ge $MaxReboots) {
                throw ("Step 8 reboot-resume cannot continue because reboot limit ({0}) was reached." -f $MaxReboots)
            }

            $rebootCount++
            $hadMidStepReboot = $true
            Write-Host ("Step 8 requested a VM reboot ({0}/{1}). Resuming after reboot..." -f $rebootCount, $MaxReboots) -ForegroundColor Yellow
            Invoke-CoVmPostStep8RebootAndProbe `
                -ResourceGroup $ResourceGroup `
                -VmName $VmName `
                -PostRebootProbeScript $PostRebootProbeScript `
                -PostRebootProbeCommandId $PostRebootProbeCommandId `
                -PostRebootProbeMaxAttempts $PostRebootProbeMaxAttempts `
                -PostRebootProbeRetryDelaySeconds $PostRebootProbeRetryDelaySeconds
        }
    }
    else {
        Write-Host ("Substep mode is enabled: Step 8 will execute tasks one-by-one. Failure policy: {0}" -f $TaskFailurePolicy)
        $nextTaskIndex = 0
        while ($nextTaskIndex -lt $TaskBlocks.Count) {
            $blockResult = Invoke-VmRunCommandBlocks `
                -ResourceGroup $ResourceGroup `
                -VmName $VmName `
                -CommandId $CommandId `
                -TaskBlocks $TaskBlocks `
                -SubstepMode:$true `
                -StartTaskIndex $nextTaskIndex `
                -SoftFail:($TaskFailurePolicy -eq "soft-warning") `
                -CombinedShell $CombinedShell

            $totalSuccess += [int]$blockResult.SuccessCount
            $totalWarnings += [int]$blockResult.WarningCount
            $totalErrors += [int]$blockResult.ErrorCount
            $nextTaskIndex = [int]$blockResult.NextTaskIndex

            if (-not $blockResult.RebootRequired) {
                break
            }

            if ($rebootCount -ge $MaxReboots) {
                throw ("Step 8 reboot-resume cannot continue because reboot limit ({0}) was reached." -f $MaxReboots)
            }

            $rebootCount++
            $hadMidStepReboot = $true
            Write-Host ("Step 8 task flow requested a VM reboot ({0}/{1}). Resuming from task index {2}..." -f $rebootCount, $MaxReboots, $nextTaskIndex) -ForegroundColor Yellow
            Invoke-CoVmPostStep8RebootAndProbe `
                -ResourceGroup $ResourceGroup `
                -VmName $VmName `
                -PostRebootProbeScript $PostRebootProbeScript `
                -PostRebootProbeCommandId $PostRebootProbeCommandId `
                -PostRebootProbeMaxAttempts $PostRebootProbeMaxAttempts `
                -PostRebootProbeRetryDelaySeconds $PostRebootProbeRetryDelaySeconds
        }
    }

    Write-Host ("STEP8_SUMMARY:success={0};warning={1};error={2};reboot={3}" -f $totalSuccess, $totalWarnings, $totalErrors, $rebootCount)

    if ($TaskFailurePolicy -eq "strict" -and ($totalWarnings -gt 0 -or $totalErrors -gt 0)) {
        throw ("Step 8 strict failure policy blocked continuation: warning={0}, error={1}" -f $totalWarnings, $totalErrors)
    }

    if ($RebootAfterExecution) {
        if ($hadMidStepReboot) {
            Write-Host "Step 8 already rebooted during task execution; final reboot is skipped." -ForegroundColor DarkGray
        }
        else {
            Invoke-CoVmPostStep8RebootAndProbe `
                -ResourceGroup $ResourceGroup `
                -VmName $VmName `
                -PostRebootProbeScript $PostRebootProbeScript `
                -PostRebootProbeCommandId $PostRebootProbeCommandId `
                -PostRebootProbeMaxAttempts $PostRebootProbeMaxAttempts `
                -PostRebootProbeRetryDelaySeconds $PostRebootProbeRetryDelaySeconds
        }
    }
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

function Resolve-CoVmPuttyToolPath {
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

function Ensure-CoVmPuttyTools {
    param(
        [string]$RepoRoot,
        [string]$ConfiguredPlinkPath = "",
        [string]$ConfiguredPscpPath = ""
    )

    $configuredClientPath = if (-not [string]::IsNullOrWhiteSpace($ConfiguredPlinkPath)) { $ConfiguredPlinkPath } else { $ConfiguredPscpPath }
    $pySshClientPath = Resolve-CoVmPuttyToolPath -ConfiguredPath $configuredClientPath -RepoRoot $RepoRoot -ToolName "ssh_client.py"
    if (Test-Path -LiteralPath $pySshClientPath) {
        return [ordered]@{
            PlinkPath = $pySshClientPath
            PscpPath = $pySshClientPath
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
        PlinkPath = $pySshClientPath
        PscpPath = $pySshClientPath
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
        [string]$PlinkPath,
        [string]$HostName,
        [string]$UserName,
        [string]$Password,
        [string]$Port
    )

    $result = Invoke-CoVmProcessWithRetry `
        -FilePath "python" `
        -Arguments @(
            $PlinkPath,
            "exec",
            "--host", [string]$HostName,
            "--port", [string]$Port,
            "--user", [string]$UserName,
            "--password", [string]$Password,
            "--timeout", "30",
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

function Invoke-CoVmSshRemoteCommand {
    param(
        [string]$PlinkPath,
        [string]$HostName,
        [string]$UserName,
        [string]$Password,
        [string]$Port,
        [string]$HostKey = "",
        [string]$Command,
        [string]$Label,
        [int]$MaxAttempts = 3,
        [int]$TimeoutSeconds = 1800,
        [switch]$AllowFailure
    )

    if ($TimeoutSeconds -lt 5) {
        $TimeoutSeconds = 5
    }

    $args = @(
        $PlinkPath,
        "exec",
        "--host", [string]$HostName,
        "--port", [string]$Port,
        "--user", [string]$UserName,
        "--password", [string]$Password,
        "--timeout", [string]$TimeoutSeconds,
        "--command", [string]$Command
    )

    return (Invoke-CoVmProcessWithRetry `
            -FilePath "python" `
            -Arguments $args `
            -Label $Label `
            -MaxAttempts $MaxAttempts `
            -AllowFailure:$AllowFailure)
}

function Copy-CoVmFileToVmOverSsh {
    param(
        [string]$PscpPath,
        [string]$HostName,
        [string]$UserName,
        [string]$Password,
        [string]$Port,
        [string]$HostKey = "",
        [string]$LocalPath,
        [string]$RemotePath,
        [int]$TimeoutSeconds = 180,
        [int]$MaxAttempts = 3
    )

    if ($TimeoutSeconds -lt 5) {
        $TimeoutSeconds = 5
    }

    $args = @(
        $PscpPath,
        "copy",
        "--host", [string]$HostName,
        "--port", [string]$Port,
        "--user", [string]$UserName,
        "--password", [string]$Password,
        "--timeout", [string]$TimeoutSeconds,
        "--local", [string]$LocalPath,
        "--remote", [string]$RemotePath
    )

    return (Invoke-CoVmProcessWithRetry `
            -FilePath "python" `
            -Arguments $args `
            -Label ("pyssh copy -> {0}" -f $RemotePath) `
            -MaxAttempts $MaxAttempts)
}

function Test-CoVmWindowsRebootPendingOverSsh {
    param(
        [string]$PlinkPath,
        [string]$HostName,
        [string]$UserName,
        [string]$Password,
        [string]$Port,
        [string]$HostKey = "",
        [int]$MaxAttempts = 3
    )

    $checkCmd = 'cmd /d /c "(reg query \"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending\" >nul 2>&1 || reg query \"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired\" >nul 2>&1 || reg query \"HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\" /v PendingFileRenameOperations >nul 2>&1) && echo CO_VM_REBOOT_REQUIRED:pending-registry"'
    $probe = Invoke-CoVmSshRemoteCommand `
        -PlinkPath $PlinkPath `
        -HostName $HostName `
        -UserName $UserName `
        -Password $Password `
        -Port $Port `
        -HostKey $HostKey `
        -Command $checkCmd `
        -Label "ssh reboot-pending check" `
        -TimeoutSeconds 30 `
        -MaxAttempts $MaxAttempts `
        -AllowFailure

    return ([string]$probe.Output -match '^CO_VM_REBOOT_REQUIRED:')
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
                [void]$outputLines.Add([string]$line)
                Write-Host ([string]$line)
                if (($line -as [string]) -like "CO_VM_SESSION_ERROR:*") {
                    throw ("Persistent SSH session reported protocol error for task '{0}': {1}" -f $TaskName, [string]$line)
                }
                if ($line -match $beginMarkerRegex) {
                    continue
                }
                if ($line -match $endMarkerRegex) {
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
                [void]$outputLines.Add([string]$line)
                Write-Warning ([string]$line)
            }
        }

        if ($proc.HasExited -and $null -eq $exitCode) {
            $stdoutTail = ""
            $stderrTail = ""
            try { $stdoutTail = [string]$stdoutReader.ReadToEnd() } catch { }
            try { $stderrTail = [string]$stderrReader.ReadToEnd() } catch { }
            if (-not [string]::IsNullOrWhiteSpace($stdoutTail)) {
                foreach ($line in ($stdoutTail -split "`r?`n")) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    [void]$outputLines.Add([string]$line)
                    Write-Host ([string]$line)
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($stderrTail)) {
                foreach ($line in ($stderrTail -split "`r?`n")) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    [void]$outputLines.Add([string]$line)
                    Write-Warning ([string]$line)
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

function Invoke-CoVmStep8OverSsh {
    param(
        [ValidateSet("windows","linux")]
        [string]$Platform,
        [switch]$SubstepMode,
        [string]$RepoRoot,
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$SshHost,
        [string]$SshUser,
        [string]$SshPassword,
        [string]$SshPort,
        [string]$ScriptFilePath,
        [object[]]$TaskBlocks,
        [switch]$RebootAfterExecution,
        [string]$PostRebootProbeScript = "",
        [string]$PostRebootProbeCommandId = "RunPowerShellScript",
        [int]$PostRebootProbeMaxAttempts = 3,
        [int]$PostRebootProbeRetryDelaySeconds = 20,
        [int]$MaxReboots = 3,
        [ValidateSet("soft-warning","strict")]
        [string]$TaskFailurePolicy = "soft-warning",
        [int]$SshMaxRetries = 3,
        [string]$ConfiguredPlinkPath = "",
        [string]$ConfiguredPscpPath = "",
        [switch]$DisableRebootHandling
    )

    if ([string]::IsNullOrWhiteSpace($SshHost)) {
        throw "Step 8 SSH mode requires a VM host/FQDN."
    }
    if ([string]::IsNullOrWhiteSpace($SshUser)) {
        throw "Step 8 SSH mode requires a VM SSH user."
    }
    if ([string]::IsNullOrWhiteSpace($SshPassword)) {
        throw "Step 8 SSH mode requires a VM SSH password."
    }
    if ([string]::IsNullOrWhiteSpace($SshPort)) {
        throw "Step 8 SSH mode requires an SSH port."
    }
    if (-not $TaskBlocks -or $TaskBlocks.Count -eq 0) {
        throw "Step 8 SSH mode requires task blocks."
    }
    if (-not $SubstepMode) {
        if ([string]::IsNullOrWhiteSpace($ScriptFilePath)) {
            throw "Step 8 SSH combined mode requires ScriptFilePath."
        }
        if (-not (Test-Path -LiteralPath $ScriptFilePath)) {
            throw "Step 8 SSH combined mode script file was not found: $ScriptFilePath"
        }
    }

    $SshMaxRetries = Resolve-CoVmSshRetryCount -RetryText ([string]$SshMaxRetries) -DefaultValue 3
    if ($MaxReboots -lt 0) { $MaxReboots = 0 }
    if ($MaxReboots -gt 3) { $MaxReboots = 3 }
    if ($PostRebootProbeMaxAttempts -lt 1) { $PostRebootProbeMaxAttempts = 1 }
    if ($PostRebootProbeMaxAttempts -gt 3) { $PostRebootProbeMaxAttempts = 3 }

    $putty = Ensure-CoVmPuttyTools `
        -RepoRoot $RepoRoot `
        -ConfiguredPlinkPath $ConfiguredPlinkPath `
        -ConfiguredPscpPath $ConfiguredPscpPath

    $hostKeyBootstrapResult = Initialize-CoVmSshHostKey `
        -PlinkPath ([string]$putty.PlinkPath) `
        -HostName $SshHost `
        -UserName $SshUser `
        -Password $SshPassword `
        -Port $SshPort
    $resolvedHostKey = ""
    if ($hostKeyBootstrapResult) {
        $resolvedHostKey = [string]$hostKeyBootstrapResult.HostKey
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedHostKey)) {
        Write-Host ("Resolved SSH host key for batch transport: {0}" -f $resolvedHostKey) -ForegroundColor DarkGray
    }

    $totalSuccess = 0
    $totalWarnings = 0
    $totalErrors = 0
    $rebootCount = 0
    $hadMidStepReboot = $false
    $tempRoot = $null
    $persistentSession = $null

    try {
        Write-Host "SSH mode is enabled for Step 8 execution." -ForegroundColor Yellow
        Write-Host ("Step 8 failure policy: {0}" -f $TaskFailurePolicy)

        if ($SubstepMode) {
            Write-Host "Task-by-task mode is enabled: Step 8 tasks are executed one-by-one over SSH."
            if ($Platform -eq "windows") {
                Write-Host "Persistent SSH task session is enabled: one SSH connection will be reused for Step 8 substeps." -ForegroundColor DarkCyan
                $persistentSession = Start-CoVmPersistentSshSession `
                    -PySshClientPath ([string]$putty.PlinkPath) `
                    -HostName $SshHost `
                    -UserName $SshUser `
                    -Password $SshPassword `
                    -Port $SshPort `
                    -Shell "powershell" `
                    -ConnectTimeoutSeconds 30 `
                    -DefaultTaskTimeoutSeconds 1800

                for ($taskIndex = 0; $taskIndex -lt $TaskBlocks.Count; $taskIndex++) {
                    $taskBlock = $TaskBlocks[$taskIndex]
                    $taskName = [string]$taskBlock.Name
                    $taskScript = Resolve-CoRunCommandScriptText -ScriptText ([string]$taskBlock.Script)

                    Write-Host ("TASK started: {0}" -f $taskName)
                    $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()
                    $taskResult = $null
                    $taskInvocationError = $null

                    for ($taskAttempt = 1; $taskAttempt -le $SshMaxRetries; $taskAttempt++) {
                        try {
                            $taskResult = Invoke-CoVmPersistentSshTask `
                                -Session $persistentSession `
                                -TaskName $taskName `
                                -TaskScript $taskScript `
                                -TimeoutSeconds 1800
                            $taskInvocationError = $null
                            break
                        }
                        catch {
                            $taskInvocationError = $_
                            if ($taskAttempt -lt $SshMaxRetries) {
                                Write-Warning ("Persistent SSH task execution failed for '{0}' (attempt {1}/{2}): {3}" -f $taskName, $taskAttempt, $SshMaxRetries, $_.Exception.Message)
                                Stop-CoVmPersistentSshSession -Session $persistentSession
                                $persistentSession = Start-CoVmPersistentSshSession `
                                    -PySshClientPath ([string]$putty.PlinkPath) `
                                    -HostName $SshHost `
                                    -UserName $SshUser `
                                    -Password $SshPassword `
                                    -Port $SshPort `
                                    -Shell "powershell" `
                                    -ConnectTimeoutSeconds 30 `
                                    -DefaultTaskTimeoutSeconds 1800
                            }
                        }
                    }

                    if ($taskWatch.IsRunning) { $taskWatch.Stop() }

                    if ($null -ne $taskInvocationError) {
                        if ($TaskFailurePolicy -eq "soft-warning") {
                            $totalWarnings++
                            Write-Warning ("TASK warning: {0} failed in persistent session => {1}" -f $taskName, $taskInvocationError.Exception.Message)
                            Write-Host ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
                            Write-Host "TASK result: warning"
                            Write-Host ("TASK_STATUS:{0}:warning" -f $taskName)
                            try {
                                Stop-CoVmPersistentSshSession -Session $persistentSession
                            }
                            catch { }
                            $persistentSession = Start-CoVmPersistentSshSession `
                                -PySshClientPath ([string]$putty.PlinkPath) `
                                -HostName $SshHost `
                                -UserName $SshUser `
                                -Password $SshPassword `
                                -Port $SshPort `
                                -Shell "powershell" `
                                -ConnectTimeoutSeconds 30 `
                                -DefaultTaskTimeoutSeconds 1800
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
                        Write-Host "TASK result: success"
                        Write-Host ("TASK_STATUS:{0}:success" -f $taskName)
                    }
                    else {
                        if ($TaskFailurePolicy -eq "soft-warning") {
                            $totalWarnings++
                            Write-Warning ("TASK warning: {0} exited with code {1}" -f $taskName, $taskResult.ExitCode)
                            Write-Host ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
                            Write-Host "TASK result: warning"
                            Write-Host ("TASK_STATUS:{0}:warning" -f $taskName)
                        }
                        else {
                            $totalErrors++
                            Write-Host ("TASK result: failure ({0})" -f $taskName) -ForegroundColor Red
                            Write-Host ("TASK_STATUS:{0}:error" -f $taskName)
                            throw ("Step 8 SSH task failed: {0} (exit {1})" -f $taskName, $taskResult.ExitCode)
                        }
                    }

                    if (-not $DisableRebootHandling) {
                        $rebootRequired = Test-CoVmOutputIndicatesRebootRequired -MessageText ([string]$taskResult.Output)
                        if (-not $rebootRequired) {
                            $rebootRequired = Test-CoVmWindowsRebootPendingOverSsh `
                                -PlinkPath ([string]$putty.PlinkPath) `
                                -HostName $SshHost `
                                -UserName $SshUser `
                                -Password $SshPassword `
                                -Port $SshPort `
                                -HostKey $resolvedHostKey `
                                -MaxAttempts $SshMaxRetries
                        }

                        if ($rebootRequired) {
                            if ($rebootCount -ge $MaxReboots) {
                                throw ("Step 8 SSH reboot-resume cannot continue because reboot limit ({0}) was reached." -f $MaxReboots)
                            }

                            $rebootCount++
                            $hadMidStepReboot = $true
                            Write-Host ("CO_VM_REBOOT_REQUIRED:task={0};index={1};rebootCount={2}" -f $taskName, $taskIndex, $rebootCount)
                            Write-Host ("Step 8 SSH flow requested a VM reboot ({0}/{1}). Resuming..." -f $rebootCount, $MaxReboots) -ForegroundColor Yellow

                            Stop-CoVmPersistentSshSession -Session $persistentSession
                            $persistentSession = $null

                            Invoke-CoVmPostStep8RebootAndProbe `
                                -ResourceGroup $ResourceGroup `
                                -VmName $VmName `
                                -PostRebootProbeScript $PostRebootProbeScript `
                                -PostRebootProbeCommandId $PostRebootProbeCommandId `
                                -PostRebootProbeMaxAttempts $PostRebootProbeMaxAttempts `
                                -PostRebootProbeRetryDelaySeconds $PostRebootProbeRetryDelaySeconds

                            $persistentSession = Start-CoVmPersistentSshSession `
                                -PySshClientPath ([string]$putty.PlinkPath) `
                                -HostName $SshHost `
                                -UserName $SshUser `
                                -Password $SshPassword `
                                -Port $SshPort `
                                -Shell "powershell" `
                                -ConnectTimeoutSeconds 30 `
                                -DefaultTaskTimeoutSeconds 1800
                        }
                    }
                }
            }
            else {
                $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("az-vm-step8-ssh-" + [guid]::NewGuid().ToString("N"))
                New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

                for ($taskIndex = 0; $taskIndex -lt $TaskBlocks.Count; $taskIndex++) {
                    $taskBlock = $TaskBlocks[$taskIndex]
                    $taskName = [string]$taskBlock.Name
                    $taskScript = Resolve-CoRunCommandScriptText -ScriptText ([string]$taskBlock.Script)
                    $localTaskName = ("task-{0:D2}.sh" -f ($taskIndex + 1))
                    $localTaskPath = Join-Path $tempRoot $localTaskName
                    $writeSettings = Get-CoVmWriteSettingsForPlatform -Platform $Platform
                    Write-TextFileNormalized `
                        -Path $localTaskPath `
                        -Content $taskScript `
                        -Encoding $writeSettings.Encoding `
                        -LineEnding $writeSettings.LineEnding `
                        -EnsureTrailingNewline

                    $remoteTaskPath = ("./{0}" -f $localTaskName)
                    Copy-CoVmFileToVmOverSsh `
                        -PscpPath ([string]$putty.PscpPath) `
                        -HostName $SshHost `
                        -UserName $SshUser `
                        -Password $SshPassword `
                        -Port $SshPort `
                        -HostKey $resolvedHostKey `
                        -LocalPath $localTaskPath `
                        -RemotePath $remoteTaskPath `
                        -MaxAttempts $SshMaxRetries | Out-Null

                    $remoteCommand = ('bash "{0}"' -f $remoteTaskPath)
                    Write-Host ("TASK started: {0}" -f $taskName)
                    $taskWatch = [System.Diagnostics.Stopwatch]::StartNew()
                    $taskResult = Invoke-CoVmSshRemoteCommand `
                        -PlinkPath ([string]$putty.PlinkPath) `
                        -HostName $SshHost `
                        -UserName $SshUser `
                        -Password $SshPassword `
                        -Port $SshPort `
                        -HostKey $resolvedHostKey `
                        -Command $remoteCommand `
                        -Label ("ssh task: {0}" -f $taskName) `
                        -MaxAttempts $SshMaxRetries `
                        -AllowFailure
                    if ($taskWatch.IsRunning) { $taskWatch.Stop() }

                    if (-not [string]::IsNullOrWhiteSpace([string]$taskResult.Output)) {
                        Write-Host ([string]$taskResult.Output)
                    }

                    if ([int]$taskResult.ExitCode -eq 0) {
                        $totalSuccess++
                        Write-Host ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
                        Write-Host "TASK result: success"
                        Write-Host ("TASK_STATUS:{0}:success" -f $taskName)
                    }
                    else {
                        if ($TaskFailurePolicy -eq "soft-warning") {
                            $totalWarnings++
                            Write-Warning ("TASK warning: {0} exited with code {1}" -f $taskName, $taskResult.ExitCode)
                            Write-Host ("TASK completed: {0} ({1:N1}s)" -f $taskName, $taskWatch.Elapsed.TotalSeconds)
                            Write-Host "TASK result: warning"
                            Write-Host ("TASK_STATUS:{0}:warning" -f $taskName)
                        }
                        else {
                            $totalErrors++
                            Write-Host ("TASK result: failure ({0})" -f $taskName) -ForegroundColor Red
                            Write-Host ("TASK_STATUS:{0}:error" -f $taskName)
                            throw ("Step 8 SSH task failed: {0} (exit {1})" -f $taskName, $taskResult.ExitCode)
                        }
                    }

                    if (-not $DisableRebootHandling) {
                        $rebootRequired = Test-CoVmOutputIndicatesRebootRequired -MessageText ([string]$taskResult.Output)
                        if ($rebootRequired) {
                            if ($rebootCount -ge $MaxReboots) {
                                throw ("Step 8 SSH reboot-resume cannot continue because reboot limit ({0}) was reached." -f $MaxReboots)
                            }

                            $rebootCount++
                            $hadMidStepReboot = $true
                            Write-Host ("CO_VM_REBOOT_REQUIRED:task={0};index={1};rebootCount={2}" -f $taskName, $taskIndex, $rebootCount)
                            Write-Host ("Step 8 SSH flow requested a VM reboot ({0}/{1}). Resuming..." -f $rebootCount, $MaxReboots) -ForegroundColor Yellow
                            Invoke-CoVmPostStep8RebootAndProbe `
                                -ResourceGroup $ResourceGroup `
                                -VmName $VmName `
                                -PostRebootProbeScript $PostRebootProbeScript `
                                -PostRebootProbeCommandId $PostRebootProbeCommandId `
                                -PostRebootProbeMaxAttempts $PostRebootProbeMaxAttempts `
                                -PostRebootProbeRetryDelaySeconds $PostRebootProbeRetryDelaySeconds
                        }
                    }
                }
            }
        }
        else {
            Write-Host ("Task-by-task mode is not enabled: Step 8 tasks will run from the VM update script file over SSH. Failure policy: {0}" -f $TaskFailurePolicy)
            $scriptLeaf = [System.IO.Path]::GetFileName([string]$ScriptFilePath)
            if ([string]::IsNullOrWhiteSpace($scriptLeaf)) {
                $scriptLeaf = if ($Platform -eq "windows") { "az-vm-step8-update.ps1" } else { "az-vm-step8-update.sh" }
            }
            $remoteScriptPath = ("./{0}" -f $scriptLeaf)

            while ($true) {
                Copy-CoVmFileToVmOverSsh `
                    -PscpPath ([string]$putty.PscpPath) `
                    -HostName $SshHost `
                    -UserName $SshUser `
                    -Password $SshPassword `
                    -Port $SshPort `
                    -HostKey $resolvedHostKey `
                    -LocalPath $ScriptFilePath `
                    -RemotePath $remoteScriptPath `
                    -MaxAttempts $SshMaxRetries | Out-Null

                if ($Platform -eq "linux") {
                    Invoke-CoVmSshRemoteCommand `
                        -PlinkPath ([string]$putty.PlinkPath) `
                        -HostName $SshHost `
                        -UserName $SshUser `
                        -Password $SshPassword `
                        -Port $SshPort `
                        -HostKey $resolvedHostKey `
                        -Command ('chmod +x "{0}"' -f $remoteScriptPath) `
                        -Label "ssh chmod update script" `
                        -MaxAttempts $SshMaxRetries | Out-Null
                }

                $combinedRemoteCommand = if ($Platform -eq "windows") {
                    ('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $remoteScriptPath)
                }
                else {
                    ('bash "{0}"' -f $remoteScriptPath)
                }

                $combinedResult = Invoke-CoVmSshRemoteCommand `
                    -PlinkPath ([string]$putty.PlinkPath) `
                    -HostName $SshHost `
                    -UserName $SshUser `
                    -Password $SshPassword `
                    -Port $SshPort `
                    -HostKey $resolvedHostKey `
                    -Command $combinedRemoteCommand `
                    -Label "ssh step8 update-script-file" `
                    -MaxAttempts $SshMaxRetries `
                    -AllowFailure

                if (-not [string]::IsNullOrWhiteSpace([string]$combinedResult.Output)) {
                    Write-Host ([string]$combinedResult.Output)
                }

                $marker = Parse-CoVmStep8Markers -MessageText ([string]$combinedResult.Output)
                if ($marker.HasSummaryLine) {
                    $totalSuccess = [int]$marker.SuccessCount
                    $totalWarnings = [int]$marker.WarningCount
                    $totalErrors = [int]$marker.ErrorCount
                    Write-Host $marker.SummaryLine -ForegroundColor DarkGray
                }
                elseif ([int]$combinedResult.ExitCode -eq 0) {
                    $totalSuccess = [int]@($TaskBlocks).Count
                }
                elseif ($TaskFailurePolicy -eq "soft-warning") {
                    $totalWarnings = [Math]::Max($totalWarnings, 1)
                }
                else {
                    $totalErrors = [Math]::Max($totalErrors, 1)
                }

                if ([int]$combinedResult.ExitCode -ne 0) {
                    if ($TaskFailurePolicy -eq "soft-warning") {
                        Write-Warning ("Step 8 SSH combined flow exited with code {0}; continuing due soft-warning policy." -f $combinedResult.ExitCode)
                    }
                    else {
                        throw ("Step 8 SSH combined flow failed with exit code {0}." -f $combinedResult.ExitCode)
                    }
                }

                if ($DisableRebootHandling) {
                    break
                }
                else {
                    $rebootRequired = ([bool]$marker.RebootRequired -or (Test-CoVmOutputIndicatesRebootRequired -MessageText ([string]$combinedResult.Output)))
                    if (-not $rebootRequired -and $Platform -eq "windows") {
                        $rebootRequired = Test-CoVmWindowsRebootPendingOverSsh `
                            -PlinkPath ([string]$putty.PlinkPath) `
                            -HostName $SshHost `
                            -UserName $SshUser `
                            -Password $SshPassword `
                            -Port $SshPort `
                            -HostKey $resolvedHostKey `
                            -MaxAttempts $SshMaxRetries
                    }

                    if (-not $rebootRequired) {
                        break
                    }

                    if ($rebootCount -ge $MaxReboots) {
                        throw ("Step 8 SSH reboot-resume cannot continue because reboot limit ({0}) was reached." -f $MaxReboots)
                    }

                    $rebootCount++
                    $hadMidStepReboot = $true
                    Write-Host ("Step 8 SSH combined flow requested a VM reboot ({0}/{1}). Resuming..." -f $rebootCount, $MaxReboots) -ForegroundColor Yellow
                    Invoke-CoVmPostStep8RebootAndProbe `
                        -ResourceGroup $ResourceGroup `
                        -VmName $VmName `
                        -PostRebootProbeScript $PostRebootProbeScript `
                        -PostRebootProbeCommandId $PostRebootProbeCommandId `
                        -PostRebootProbeMaxAttempts $PostRebootProbeMaxAttempts `
                        -PostRebootProbeRetryDelaySeconds $PostRebootProbeRetryDelaySeconds
                }
            }
        }

        Write-Host ("STEP8_SUMMARY:success={0};warning={1};error={2};reboot={3}" -f $totalSuccess, $totalWarnings, $totalErrors, $rebootCount)
        if ($TaskFailurePolicy -eq "strict" -and ($totalWarnings -gt 0 -or $totalErrors -gt 0)) {
            throw ("Step 8 strict failure policy blocked continuation: warning={0}, error={1}" -f $totalWarnings, $totalErrors)
        }

        if ($RebootAfterExecution -and -not $DisableRebootHandling) {
            if ($hadMidStepReboot) {
                Write-Host "Step 8 already rebooted during SSH task execution; final reboot is skipped." -ForegroundColor DarkGray
            }
            else {
                Invoke-CoVmPostStep8RebootAndProbe `
                    -ResourceGroup $ResourceGroup `
                    -VmName $VmName `
                    -PostRebootProbeScript $PostRebootProbeScript `
                    -PostRebootProbeCommandId $PostRebootProbeCommandId `
                    -PostRebootProbeMaxAttempts $PostRebootProbeMaxAttempts `
                    -PostRebootProbeRetryDelaySeconds $PostRebootProbeRetryDelaySeconds
            }
        }
    }
    finally {
        if ($null -ne $persistentSession) {
            Stop-CoVmPersistentSshSession -Session $persistentSession
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$tempRoot) -and (Test-Path -LiteralPath $tempRoot)) {
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
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


