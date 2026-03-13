# Shared command runtime-context builders.

# Handles Initialize-AzVmCommandRuntimeContext.
function Initialize-AzVmCommandRuntimeContext {
    param(
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag,
        [hashtable]$ConfigMapOverrides = @{},
        [string]$OperationName = 'generic',
        [switch]$UseInteractiveStep1,
        [switch]$PersistGeneratedResourceGroup,
        [switch]$DeferDotEnvWrites
    )

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $platformSelectionOverrides = @{}
    foreach ($key in @($script:ConfigOverrides.Keys)) {
        $platformSelectionOverrides[[string]$key] = [string]$script:ConfigOverrides[$key]
    }
    foreach ($key in @($ConfigMapOverrides.Keys)) {
        $platformSelectionOverrides[[string]$key] = [string]$ConfigMapOverrides[$key]
    }

    $promptForPlatformSelection = (-not $AutoMode) -and [string]::Equals([string]$OperationName, 'create', [System.StringComparison]::OrdinalIgnoreCase)
    $platform = Resolve-AzVmPlatformSelection -ConfigMap $configMap -EnvFilePath $envFilePath -AutoMode:$AutoMode -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -ConfigOverrides $platformSelectionOverrides -DeferEnvWrite:$DeferDotEnvWrites -PromptWhenFlagsMissing:$promptForPlatformSelection
    $platformDefaults = Get-AzVmPlatformDefaults -Platform $platform
    $effectiveConfigMap = Resolve-AzVmPlatformConfigMap -ConfigMap $configMap -Platform $platform
    foreach ($key in @($ConfigMapOverrides.Keys)) {
        $overrideKey = [string]$key
        if ([string]::IsNullOrWhiteSpace($overrideKey)) {
            continue
        }
        $effectiveConfigMap[$overrideKey] = [string]$ConfigMapOverrides[$key]
        $script:ConfigOverrides[$overrideKey] = [string]$ConfigMapOverrides[$key]
    }

    $step1AutoMode = $true
    if ($UseInteractiveStep1) {
        $step1AutoMode = [bool]$AutoMode
    }

    $step1Context = Invoke-AzVmStep1Common `
        -ConfigMap $effectiveConfigMap `
        -EnvFilePath $envFilePath `
        -Platform $platform `
        -AutoMode:$step1AutoMode `
        -PersistGeneratedResourceGroup:$PersistGeneratedResourceGroup `
        -ScriptRoot $repoRoot `
        -VmNameDefault ([string]$platformDefaults.VmNameDefault) `
        -VmImageDefault ([string]$platformDefaults.VmImageDefault) `
        -VmSizeDefault ([string]$platformDefaults.VmSizeDefault) `
        -VmDiskSizeDefault ([string]$platformDefaults.VmDiskSizeDefault) `
        -ConfigOverrides $script:ConfigOverrides `
        -OperationName $OperationName `
        -DeferEnvWrites:$DeferDotEnvWrites

    $step1Context['VmOsType'] = $platform

    $taskOutcomeModeRaw = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'VM_TASK_OUTCOME_MODE' -DefaultValue 'continue')
    if ([string]::IsNullOrWhiteSpace($taskOutcomeModeRaw)) { $taskOutcomeModeRaw = 'continue' }
    $taskOutcomeMode = $taskOutcomeModeRaw.Trim().ToLowerInvariant()
    if ($taskOutcomeMode -ne 'continue' -and $taskOutcomeMode -ne 'strict') {
        Throw-FriendlyError `
            -Detail ("Invalid VM_TASK_OUTCOME_MODE '{0}'." -f $taskOutcomeModeRaw) `
            -Code 14 `
            -Summary "Task outcome mode is invalid." `
            -Hint "Set VM_TASK_OUTCOME_MODE=continue or VM_TASK_OUTCOME_MODE=strict."
    }

    $configuredPySshClientPath = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'PYSSH_CLIENT_PATH' -DefaultValue (Get-AzVmDefaultPySshClientPathText))
    $sshTaskTimeoutText = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'SSH_TASK_TIMEOUT_SECONDS' -DefaultValue ([string]$script:SshTaskTimeoutSeconds))
    $sshTaskTimeoutSeconds = $script:SshTaskTimeoutSeconds
    if ($sshTaskTimeoutText -match '^\d+$') { $sshTaskTimeoutSeconds = [int]$sshTaskTimeoutText }
    if ($sshTaskTimeoutSeconds -lt 30) { $sshTaskTimeoutSeconds = 30 }
    if ($sshTaskTimeoutSeconds -gt 7200) { $sshTaskTimeoutSeconds = 7200 }

    $sshConnectTimeoutText = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'SSH_CONNECT_TIMEOUT_SECONDS' -DefaultValue ([string]$script:SshConnectTimeoutSeconds))
    $sshConnectTimeoutSeconds = $script:SshConnectTimeoutSeconds
    if ($sshConnectTimeoutText -match '^\d+$') { $sshConnectTimeoutSeconds = [int]$sshConnectTimeoutText }
    if ($sshConnectTimeoutSeconds -lt 5) { $sshConnectTimeoutSeconds = 5 }
    if ($sshConnectTimeoutSeconds -gt 300) { $sshConnectTimeoutSeconds = 300 }

    $azCommandTimeoutText = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'AZ_COMMAND_TIMEOUT_SECONDS' -DefaultValue ([string]$script:AzCommandTimeoutSeconds))
    $azCommandTimeoutSeconds = $script:AzCommandTimeoutSeconds
    if ($azCommandTimeoutText -match '^\d+$') { $azCommandTimeoutSeconds = [int]$azCommandTimeoutText }
    if ($azCommandTimeoutSeconds -lt 30) { $azCommandTimeoutSeconds = 30 }
    if ($azCommandTimeoutSeconds -gt 7200) { $azCommandTimeoutSeconds = 7200 }

    $script:AzCommandTimeoutSeconds = $azCommandTimeoutSeconds
    $script:SshTaskTimeoutSeconds = $sshTaskTimeoutSeconds
    $script:SshConnectTimeoutSeconds = $sshConnectTimeoutSeconds
    $step1Context['AzCommandTimeoutSeconds'] = $azCommandTimeoutSeconds
    $step1Context['SshTaskTimeoutSeconds'] = $sshTaskTimeoutSeconds
    $step1Context['SshConnectTimeoutSeconds'] = $sshConnectTimeoutSeconds

    return [pscustomobject]@{
        EnvFilePath = $envFilePath
        ConfigMap = $configMap
        EffectiveConfigMap = $effectiveConfigMap
        Platform = $platform
        PlatformDefaults = $platformDefaults
        Context = $step1Context
        TaskOutcomeMode = $taskOutcomeMode
        ConfiguredPySshClientPath = $configuredPySshClientPath
        SshTaskTimeoutSeconds = $sshTaskTimeoutSeconds
        SshConnectTimeoutSeconds = $sshConnectTimeoutSeconds
    }
}

# Handles Initialize-AzVmExecCommandRuntimeContext.
function Initialize-AzVmExecCommandRuntimeContext {
    param(
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $platform = Resolve-AzVmPlatformSelection -ConfigMap $configMap -EnvFilePath $envFilePath -AutoMode:$AutoMode -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -ConfigOverrides $script:ConfigOverrides
    $platformDefaults = Get-AzVmPlatformDefaults -Platform $platform
    $effectiveConfigMap = Resolve-AzVmPlatformConfigMap -ConfigMap $configMap -Platform $platform

    $vmName = [string](Get-AzVmRequiredResolvedConfigValue -ConfigMap $effectiveConfigMap -Key 'VM_NAME' -Summary 'VM name is required.' -Hint 'Set VM_NAME in .env, or pass --vm-name where the command supports it.')

    $azLocation = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'AZ_LOCATION' -DefaultValue '')
    $regionCode = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$azLocation)) {
        $regionCode = Get-AzVmRegionCode -Location ([string]$azLocation)
    }

    $nameTokens = @{
        VM_NAME = [string]$vmName
        REGION_CODE = [string]$regionCode
        N = '1'
    }

    $resourceGroup = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'RESOURCE_GROUP' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace([string]$resourceGroup)) {
        $resourceGroup = Resolve-AzVmTemplate -Template $resourceGroup -Tokens $nameTokens
    }

    $vmStorageSku = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key 'VM_STORAGE_SKU' -DefaultValue 'StandardSSD_LRS')) -Tokens $nameTokens
    $vmSizeConfigKey = Get-AzVmPlatformVmConfigKey -Platform $platform -BaseKey 'VM_SIZE'
    $vmImageConfigKey = Get-AzVmPlatformVmConfigKey -Platform $platform -BaseKey 'VM_IMAGE'
    $vmDiskSizeConfigKey = Get-AzVmPlatformVmConfigKey -Platform $platform -BaseKey 'VM_DISK_SIZE_GB'
    $vmSize = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key $vmSizeConfigKey -DefaultValue ([string]$platformDefaults.VmSizeDefault))) -Tokens $nameTokens
    $vmImage = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key $vmImageConfigKey -DefaultValue ([string]$platformDefaults.VmImageDefault))) -Tokens $nameTokens
    $vmDiskSize = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key $vmDiskSizeConfigKey -DefaultValue ([string]$platformDefaults.VmDiskSizeDefault))) -Tokens $nameTokens
    $vmDiskName = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key 'VM_DISK_NAME' -DefaultValue '')) -Tokens $nameTokens
    $companyName = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key 'company_name' -DefaultValue '')) -Tokens $nameTokens
    $employeeEmailAddress = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key 'employee_email_address' -DefaultValue '')) -Tokens $nameTokens
    $employeeFullName = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key 'employee_full_name' -DefaultValue '')) -Tokens $nameTokens
    $vmUser = Get-AzVmRequiredResolvedConfigValue -ConfigMap $effectiveConfigMap -Key 'VM_ADMIN_USER' -Tokens $nameTokens -Summary 'VM admin user is required.' -Hint 'Set VM_ADMIN_USER in .env to the primary VM username.'
    $vmPass = Get-AzVmRequiredResolvedConfigValue -ConfigMap $effectiveConfigMap -Key 'VM_ADMIN_PASS' -Tokens $nameTokens -Summary 'VM admin password is required.' -Hint 'Set VM_ADMIN_PASS in .env to a non-placeholder password.'
    $vmAssistantUser = Get-AzVmRequiredResolvedConfigValue -ConfigMap $effectiveConfigMap -Key 'VM_ASSISTANT_USER' -Tokens $nameTokens -Summary 'VM assistant user is required.' -Hint 'Set VM_ASSISTANT_USER in .env to the secondary VM username.'
    $vmAssistantPass = Get-AzVmRequiredResolvedConfigValue -ConfigMap $effectiveConfigMap -Key 'VM_ASSISTANT_PASS' -Tokens $nameTokens -Summary 'VM assistant password is required.' -Hint 'Set VM_ASSISTANT_PASS in .env to a non-placeholder password.'
    $sshPort = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key 'VM_SSH_PORT' -DefaultValue (Get-AzVmDefaultSshPortText))) -Tokens $nameTokens
    $rdpPort = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key 'VM_RDP_PORT' -DefaultValue (Get-AzVmDefaultRdpPortText))) -Tokens $nameTokens

    $vmInitTaskDirName = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key (Get-AzVmPlatformTaskCatalogConfigKey -Platform $platform -Stage 'init') -DefaultValue ([string]$platformDefaults.VmInitTaskDirDefault))) -Tokens $nameTokens
    $vmUpdateTaskDirName = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key (Get-AzVmPlatformTaskCatalogConfigKey -Platform $platform -Stage 'update') -DefaultValue ([string]$platformDefaults.VmUpdateTaskDirDefault))) -Tokens $nameTokens
    $vmInitTaskDir = Resolve-ConfigPath -PathValue $vmInitTaskDirName -RootPath $repoRoot
    $vmUpdateTaskDir = Resolve-ConfigPath -PathValue $vmUpdateTaskDirName -RootPath $repoRoot

    $defaultPortsCsv = Get-AzVmDefaultTcpPortsCsv
    $tcpPortsConfiguredCsv = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'TCP_PORTS' -DefaultValue $defaultPortsCsv)
    $tcpPorts = @($tcpPortsConfiguredCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })
    if (-not [string]::IsNullOrWhiteSpace([string]$sshPort) -and ($sshPort -match '^\d+$') -and $tcpPorts -notcontains $sshPort) {
        $tcpPorts += $sshPort
    }
    if ([bool]$platformDefaults.IncludeRdp -and -not [string]::IsNullOrWhiteSpace([string]$rdpPort) -and ($rdpPort -match '^\d+$') -and $tcpPorts -notcontains $rdpPort) {
        $tcpPorts += $rdpPort
    }

    $taskOutcomeModeRaw = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'VM_TASK_OUTCOME_MODE' -DefaultValue 'continue')
    if ([string]::IsNullOrWhiteSpace($taskOutcomeModeRaw)) { $taskOutcomeModeRaw = 'continue' }
    $taskOutcomeMode = $taskOutcomeModeRaw.Trim().ToLowerInvariant()
    if ($taskOutcomeMode -ne 'continue' -and $taskOutcomeMode -ne 'strict') {
        Throw-FriendlyError `
            -Detail ("Invalid VM_TASK_OUTCOME_MODE '{0}'." -f $taskOutcomeModeRaw) `
            -Code 14 `
            -Summary "Task outcome mode is invalid." `
            -Hint "Set VM_TASK_OUTCOME_MODE=continue or VM_TASK_OUTCOME_MODE=strict."
    }

    $configuredPySshClientPath = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'PYSSH_CLIENT_PATH' -DefaultValue (Get-AzVmDefaultPySshClientPathText))
    $sshTaskTimeoutText = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'SSH_TASK_TIMEOUT_SECONDS' -DefaultValue ([string]$script:SshTaskTimeoutSeconds))
    $sshTaskTimeoutSeconds = $script:SshTaskTimeoutSeconds
    if ($sshTaskTimeoutText -match '^\d+$') { $sshTaskTimeoutSeconds = [int]$sshTaskTimeoutText }
    if ($sshTaskTimeoutSeconds -lt 30) { $sshTaskTimeoutSeconds = 30 }
    if ($sshTaskTimeoutSeconds -gt 7200) { $sshTaskTimeoutSeconds = 7200 }

    $sshConnectTimeoutText = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'SSH_CONNECT_TIMEOUT_SECONDS' -DefaultValue ([string]$script:SshConnectTimeoutSeconds))
    $sshConnectTimeoutSeconds = $script:SshConnectTimeoutSeconds
    if ($sshConnectTimeoutText -match '^\d+$') { $sshConnectTimeoutSeconds = [int]$sshConnectTimeoutText }
    if ($sshConnectTimeoutSeconds -lt 5) { $sshConnectTimeoutSeconds = 5 }
    if ($sshConnectTimeoutSeconds -gt 300) { $sshConnectTimeoutSeconds = 300 }

    $azCommandTimeoutText = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'AZ_COMMAND_TIMEOUT_SECONDS' -DefaultValue ([string]$script:AzCommandTimeoutSeconds))
    $azCommandTimeoutSeconds = $script:AzCommandTimeoutSeconds
    if ($azCommandTimeoutText -match '^\d+$') { $azCommandTimeoutSeconds = [int]$azCommandTimeoutText }
    if ($azCommandTimeoutSeconds -lt 30) { $azCommandTimeoutSeconds = 30 }
    if ($azCommandTimeoutSeconds -gt 7200) { $azCommandTimeoutSeconds = 7200 }

    $script:AzCommandTimeoutSeconds = $azCommandTimeoutSeconds
    $script:SshTaskTimeoutSeconds = $sshTaskTimeoutSeconds
    $script:SshConnectTimeoutSeconds = $sshConnectTimeoutSeconds

    $context = [ordered]@{
        ResourceGroup = [string]$resourceGroup
        AzLocation = [string]$azLocation
        VmName = [string]$vmName
        VmImage = [string]$vmImage
        VmStorageSku = [string]$vmStorageSku
        VmSize = [string]$vmSize
        VmDiskName = [string]$vmDiskName
        VmDiskSize = [string]$vmDiskSize
        CompanyName = [string]$companyName
        EmployeeEmailAddress = [string]$employeeEmailAddress
        EmployeeFullName = [string]$employeeFullName
        VmUser = [string]$vmUser
        VmPass = [string]$vmPass
        VmAssistantUser = [string]$vmAssistantUser
        VmAssistantPass = [string]$vmAssistantPass
        SshPort = [string]$sshPort
        RdpPort = [string]$rdpPort
        TcpPorts = @($tcpPorts)
        TcpPortsConfiguredCsv = [string]$tcpPortsConfiguredCsv
        VmInitTaskDir = [string]$vmInitTaskDir
        VmUpdateTaskDir = [string]$vmUpdateTaskDir
        VmOsType = [string]$platform
        AzCommandTimeoutSeconds = [int]$azCommandTimeoutSeconds
        SshTaskTimeoutSeconds = [int]$sshTaskTimeoutSeconds
        SshConnectTimeoutSeconds = [int]$sshConnectTimeoutSeconds
    }

    return [pscustomobject]@{
        EnvFilePath = $envFilePath
        ConfigMap = $configMap
        EffectiveConfigMap = $effectiveConfigMap
        Platform = $platform
        PlatformDefaults = $platformDefaults
        Context = $context
        TaskOutcomeMode = $taskOutcomeMode
        ConfiguredPySshClientPath = $configuredPySshClientPath
        SshTaskTimeoutSeconds = $sshTaskTimeoutSeconds
        SshConnectTimeoutSeconds = $sshConnectTimeoutSeconds
    }
}

# Handles Initialize-AzVmTaskCommandRuntimeContext.
function Initialize-AzVmTaskCommandRuntimeContext {
    param(
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $platform = Resolve-AzVmPlatformSelection -ConfigMap $configMap -EnvFilePath $envFilePath -AutoMode:$AutoMode -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -ConfigOverrides $script:ConfigOverrides
    $platformDefaults = Get-AzVmPlatformDefaults -Platform $platform
    $effectiveConfigMap = Resolve-AzVmPlatformConfigMap -ConfigMap $configMap -Platform $platform

    $vmName = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'VM_NAME' -DefaultValue '')
    $azLocation = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'AZ_LOCATION' -DefaultValue '')
    $regionCode = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$azLocation)) {
        $regionCode = Get-AzVmRegionCode -Location ([string]$azLocation)
    }

    $nameTokens = @{
        VM_NAME = [string]$vmName
        REGION_CODE = [string]$regionCode
        N = '1'
    }

    $vmInitTaskDirName = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key (Get-AzVmPlatformTaskCatalogConfigKey -Platform $platform -Stage 'init') -DefaultValue ([string]$platformDefaults.VmInitTaskDirDefault))) -Tokens $nameTokens
    $vmUpdateTaskDirName = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key (Get-AzVmPlatformTaskCatalogConfigKey -Platform $platform -Stage 'update') -DefaultValue ([string]$platformDefaults.VmUpdateTaskDirDefault))) -Tokens $nameTokens

    return [pscustomobject]@{
        RepoRoot = $repoRoot
        EnvFilePath = $envFilePath
        ConfigMap = $configMap
        EffectiveConfigMap = $effectiveConfigMap
        Platform = $platform
        PlatformDefaults = $platformDefaults
        VmInitTaskDir = Resolve-ConfigPath -PathValue $vmInitTaskDirName -RootPath $repoRoot
        VmUpdateTaskDir = Resolve-ConfigPath -PathValue $vmUpdateTaskDirName -RootPath $repoRoot
    }
}
